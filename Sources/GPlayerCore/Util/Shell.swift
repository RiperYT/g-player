import Foundation

/// The result of a finished process.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { status == 0 }
}

public enum ShellError: LocalizedError {
    case failed(String)
    public var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}

/// Runs short helper processes (tar, xattr, wineboot, reg) and collects their output.
public enum Shell {
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String],
                           environment: [String: String]? = nil,
                           currentDirectory: URL? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Read both pipes concurrently so a chatty process never blocks on a full pipe.
        let outBox = DataBox(), errBox = DataBox()
        out.fileHandleForReading.readabilityHandler = { h in outBox.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in errBox.append(h.availableData) }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outBox.append(out.fileHandleForReading.readDataToEndOfFile())
                errBox.append(err.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: ProcessResult(
                    status: p.terminationStatus,
                    stdout: String(decoding: outBox.data, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// Like `run`, for work that can be stopped: when the calling task is cancelled the process is stopped and
    /// `CancellationError` is thrown (unpacking a big archive, say, which `run` would let finish).
    public static func runStoppable(_ executable: URL, _ arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let outBox = DataBox(), errBox = DataBox()
        out.fileHandleForReading.readabilityHandler = { h in outBox.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in errBox.append(h.availableData) }
        let status = try await Supervised.run(timeout: nil, stop: { Supervised.terminate(process) }) { finish in
            process.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outBox.append(out.fileHandleForReading.readDataToEndOfFile())
                errBox.append(err.fileHandleForReading.readDataToEndOfFile())
                finish(p.terminationStatus)
            }
            try process.run()
        }
        return ProcessResult(status: status, stdout: String(decoding: outBox.data, as: UTF8.self),
                             stderr: String(decoding: errBox.data, as: UTF8.self))
    }

    /// `/usr/bin/<tool>` or `/bin/<tool>`.
    public static func tool(_ name: String) -> URL {
        for dir in ["/usr/bin", "/bin", "/usr/sbin"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return URL(fileURLWithPath: "/usr/bin/\(name)")
    }

    /// True when Rosetta 2 can run x86_64 code (Wine for macOS is an x86_64 build).
    public static func isRosettaInstalled() async -> Bool {
        (try? await run(tool("arch"), ["-x86_64", "/usr/bin/true"]))?.succeeded == true
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ chunk: Data) { lock.lock(); storage.append(chunk); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}
