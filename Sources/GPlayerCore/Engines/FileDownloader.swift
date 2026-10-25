import Foundation

/// Downloads one file with progress. Used for engines and app installers.
///
/// The file is written to `<destination>.part` and moved into place when it is whole. With `resume`, a `.part` file from
/// an earlier try is kept and the rest is asked for (`Range`), so a dropped connection, a Stop or a quit doesn't throw away
/// what came. Only for files whose checksum is checked afterwards (engines): a file that changed on the server would be
/// glued together from two versions.
public final class FileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let partial: URL
    private let skip: Int64
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    /// The outcome when it came before the continuation was stored (a download cancelled right at the start).
    private var early: Result<Void, Error>?

    // Touched only by the session's delegate queue, which runs one callback at a time.
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var total: Int64 = 0
    private var failure: Error?
    private var alreadyComplete = false
    private var lastReport = Date.distantPast

    /// The server wouldn't give the rest of the file (`DownloadResume.Answer.rangeRefused`).
    private struct RangeRefused: LocalizedError {
        var errorDescription: String? { String(localized: "The server wouldn't send the file.") }
    }

    private init(destination: URL, skip: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.partial = Self.partialFile(for: destination)
        self.skip = skip
        self.progress = progress
    }

    /// Where the part that has arrived is kept.
    public static func partialFile(for destination: URL) -> URL { destination.appendingPathExtension("part") }

    /// Downloads `url` to `destination`. `progress` gets the bytes the file has so far (counting what an earlier try left)
    /// and its size, 0 while that isn't known. Throws `CancellationError` when the calling task is cancelled; the download
    /// stops then, and its `.part` file stays for a `resume`.
    public static func download(_ url: URL, to destination: URL, resume: Bool = false,
                                configuration: URLSessionConfiguration = .default,
                                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = partialFile(for: destination)
        if !resume { try? FileManager.default.removeItem(at: partial) }
        var skip = resume ? Files.size(of: partial) : 0
        do {
            while true {
                do {
                    try await attempt(url, to: destination, skip: skip, configuration: configuration, progress: progress)
                    return
                } catch is RangeRefused where skip > 0 {
                    try? FileManager.default.removeItem(at: partial)    // what is there doesn't fit the server's file
                    skip = 0
                }
            }
        } catch {
            // Only a download that can go on keeps its part: one that can't would leave the file for ever.
            if !resume { try? FileManager.default.removeItem(at: partial) }
            throw error
        }
    }

    /// The same without resuming, for a download that has a fraction to show (store installers).
    public static func download(_ url: URL, to destination: URL,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await download(url, to: destination, resume: false) { done, total in
            if total > 0 { progress(Double(done) / Double(total)) }
        }
    }

    private static func attempt(_ url: URL, to destination: URL, skip: Int64, configuration: URLSessionConfiguration,
                                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let delegate = FileDownloader(destination: destination, skip: skip, progress: progress)
        // The file is checked and kept by G-Player; URLSession's own cache would only keep a second copy.
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        if let range = DownloadResume.rangeHeader(partialSize: skip) { request.setValue(range, forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                delegate.attach(c)
                task.resume()                       // a task cancelled before this ends at once with .cancelled
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Delegate

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The file lives on another host after a redirect (GitHub's releases): the new request asks for the same part.
        var next = request
        if let range = DownloadResume.rangeHeader(partialSize: skip) { next.setValue(range, forHTTPHeaderField: "Range") }
        completionHandler(next)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let name = dataTask.originalRequest?.url?.lastPathComponent ?? String(localized: "the file", comment: "Inside “The server answered 404 for …”")
        let length = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let http = response as? HTTPURLResponse
        // A file: URL has no status or ranges: its answer is the whole file.
        switch DownloadResume.answer(partialSize: skip, status: http?.statusCode ?? 200,
                                     contentRange: http?.value(forHTTPHeaderField: "Content-Range"), contentLength: length) {
        case .append(let size):
            total = size
            written = skip
            do {
                handle = try FileHandle(forWritingTo: partial)
                try handle?.seekToEnd()
            } catch { failure = error; return completionHandler(.cancel) }
        case .restart(let size):
            total = size
            written = 0
            do {
                FileManager.default.createFile(atPath: partial.path, contents: nil)       // empties what was there
                handle = try FileHandle(forWritingTo: partial)
            } catch { failure = error; return completionHandler(.cancel) }
        case .complete:
            alreadyComplete = true                                       // all of it is there: nothing to download
            return completionHandler(.cancel)
        case .rangeRefused:
            failure = RangeRefused()
            return completionHandler(.cancel)
        case .failed(let status):
            failure = ShellError.failed(String(localized: "The server answered \(status) for \(name)."))
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, failure == nil else { return }
        do { try handle.write(contentsOf: data) } catch {
            failure = error                                              // a full disk, say
            dataTask.cancel()
            return
        }
        written += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.1 || (total > 0 && written >= total) {
            lastReport = now
            progress(written, total)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let failure { return finish(failure) }
        if alreadyComplete {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
                progress(skip, skip)
                finish(nil)
            } catch { finish(error) }
            return
        }
        if let error { return finish((error as? URLError)?.code == .cancelled ? CancellationError() : error) }
        guard written >= total else {
            return finish(URLError(.networkConnectionLost))              // the server stopped short: the rest is asked for again
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
            progress(written, total)
            finish(nil)
        } catch { finish(error) }
    }

    // MARK: Waiting

    private func attach(_ c: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result = early {
            lock.unlock()
            c.resume(with: result)
        } else {
            continuation = c
            lock.unlock()
        }
    }

    /// Resumes the waiting call once; an outcome that arrives before it waits is kept for it.
    private func finish(_ error: Error?) {
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        lock.lock()
        guard let c = continuation else {
            if early == nil { early = result }
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()
        c.resume(with: result)
    }
}
