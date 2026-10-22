import Foundation

/// Downloads one file with progress. Used for engines and app installers.
public final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    /// The outcome when it came before the continuation was stored (a download cancelled right at the start).
    private var early: Result<Void, Error>?

    private init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    /// Throws `CancellationError` when the calling task is cancelled; the download stops then.
    public static func download(_ url: URL, to destination: URL,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let delegate = FileDownloader(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try Task.checkCancellation()
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                delegate.attach(c)
                task.resume()                       // a task cancelled before this ends at once with .cancelled
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ShellError.failed("The server answered \(http.statusCode) for \(downloadTask.originalRequest?.url?.lastPathComponent ?? "the file").")
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch { finish(error) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish((error as? URLError)?.code == .cancelled ? CancellationError() : error)
    }

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
