import Foundation

/// The decisions behind a download that goes on where it stopped: what to ask the server for, what its answer means,
/// when a dropped connection is worth another try, and how progress is told.
public enum DownloadResume {
    /// What to do with a server's answer to a request that may have asked for the rest of a file.
    public enum Answer: Equatable, Sendable {
        /// The rest of the file: add it to what is there. `total` is the whole file's size, 0 when unknown.
        case append(total: Int64)
        /// The whole file, from its start: what is there is replaced. (The server doesn't do ranges, or nothing was asked.)
        case restart(total: Int64)
        /// The part on disk is the whole file already (the server says so with a 416 and the file's size): nothing is left to
        /// download. The checksum says whether it is the right file.
        case complete
        /// The server won't give that range (the partial file is longer than the file, or the server doesn't say): ask for all of it.
        case rangeRefused
        /// The server said no.
        case failed(status: Int)
    }

    /// The `Range` header that asks for the rest of a file of which `partialSize` bytes are there, or nil to ask for all.
    public static func rangeHeader(partialSize: Int64) -> String? {
        partialSize > 0 ? "bytes=\(partialSize)-" : nil
    }

    /// Reads the answer of a server.
    /// - Parameters:
    ///   - partialSize: bytes already on disk and asked to be skipped (0 when the whole file was asked for).
    ///   - contentRange: the `Content-Range` header, "bytes 100-999/1000".
    ///   - contentLength: the length of this answer's body, nil or 0 or less when unknown.
    public static func answer(partialSize: Int64, status: Int, contentRange: String?, contentLength: Int64?) -> Answer {
        if status == 416 {
            // "bytes */1000": the file is 1000 bytes long.
            return partialSize > 0 && unsatisfiedRangeTotal(contentRange) == partialSize ? .complete : .rangeRefused
        }
        let length = max(contentLength ?? 0, 0)
        switch status {
        case 200:
            return .restart(total: length)
        case 206:
            guard let range = parse(contentRange: contentRange), range.start == partialSize else { return .rangeRefused }
            return .append(total: range.total ?? (length > 0 ? partialSize + length : 0))
        default:
            return .failed(status: status)
        }
    }

    /// "bytes */1000" (what a 416 says) is 1000.
    static func unsatisfiedRangeTotal(_ contentRange: String?) -> Int64? {
        guard let text = contentRange?.trimmingCharacters(in: .whitespaces), text.lowercased().hasPrefix("bytes */") else { return nil }
        return Int64(text.dropFirst(8).trimmingCharacters(in: .whitespaces))
    }

    /// "bytes 100-999/1000" is (100, 999, 1000); the total is nil for "/*".
    static func parse(contentRange: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let text = contentRange?.trimmingCharacters(in: .whitespaces), text.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = text.dropFirst(6).split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let span = parts[0].split(separator: "-").compactMap { Int64($0) }
        guard span.count == 2, span[0] <= span[1] else { return nil }
        return (span[0], span[1], Int64(parts[1]))
    }

    /// Tries after a connection that dropped in the middle of a download: a few, with a wait that grows.
    public static let retryDelays: [TimeInterval] = [2, 5, 10]

    /// How long to wait before trying again after `error`, or nil to give up. Only a connection that dropped is tried
    /// again, and only once it has delivered something (nothing came at all: the Mac is offline, and the user is told at
    /// once). `failures` counts the tries in a row that brought nothing new.
    public static func retryDelay(after error: Error, failures: Int, hasReceivedData: Bool,
                                  delays: [TimeInterval] = retryDelays) -> TimeInterval? {
        guard hasReceivedData, failures < delays.count, EngineManager.isConnectionFailure(error) else { return nil }
        return delays[failures]
    }

    /// "Downloading 41 of 98 MB". Rounded, like every size G-Player shows (`EngineCatalog.megabytes`): "288 of 288 MB" at the
    /// end, not 287. The part never shows more than the whole: the sizes in the catalogue are approximate.
    public static func message(received: Int64, total: Int64) -> String {
        guard total > 0 else { return "Downloading \(EngineCatalog.megabytes(received)) MB" }
        return "Downloading \(EngineCatalog.megabytes(min(received, total))) of \(EngineCatalog.megabytes(total)) MB"
    }
}
