import Foundation

/// Waits for a process with a time limit, and stops it when the task that waits is cancelled.
///
/// Used for installers: a setup program that hangs must not hang G-Player, and cancelling an install must stop
/// the program it started. Only that program and what it started are stopped; the Wine server of the space is
/// left alone, because other programs may be running in it.
enum Supervised {
    /// The process ran past its time limit and was stopped.
    struct TimedOut: LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? {
            let minutes = Int((seconds / 60).rounded())
            return minutes >= 1
                ? "It took longer than \(minutes) minute\(minutes == 1 ? "" : "s"), so G-Player stopped it."
                : "It took longer than \(Int(seconds.rounded())) seconds, so G-Player stopped it."
        }
    }

    /// Starts something with `begin` and waits for its exit status. `begin` must start the process and call
    /// `finish` once, from any thread, when the process exits. `stop` ends the process; it runs when the task is
    /// cancelled or `timeout` seconds pass first, and the call then throws `CancellationError` or `TimedOut`.
    static func run(timeout: TimeInterval?, stop: @escaping @Sendable () -> Void,
                    begin: (@escaping @Sendable (Int32) -> Void) throws -> Void) async throws -> Int32 {
        let gate = Gate()
        let limit = timeout.map { seconds in
            DispatchWorkItem { if gate.finish(.failure(TimedOut(seconds: seconds))) { stop() } }
        }
        defer { limit?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                gate.attach(continuation)
                guard !gate.isFinished else { return }                  // cancelled before anything started
                do { try begin { status in gate.finish(.success(status)) } } catch { gate.finish(.failure(error)) }
                if let limit, let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: limit)
                }
                if gate.isFinished { stop() }                            // cancelled while starting
            }
        } onCancel: {
            if gate.finish(.failure(CancellationError())) { stop() }
        }
    }

    /// Runs a program and waits for it. True when it exited by itself, false when `timeout` passed or the task
    /// was cancelled (the program is stopped then). Never throws.
    static func exits(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                      timeout: TimeInterval?) async -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status = try? await run(timeout: timeout, stop: { terminate(process) }) { finish in
            process.terminationHandler = { finish($0.terminationStatus) }
            try process.run()
        }
        return status != nil
    }

    // MARK: Stopping

    /// Stops a process and the programs it started (an installer's own children), leaves everything else running.
    /// SIGTERM first; the process itself gets SIGKILL after five seconds if it is still there.
    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        for child in descendants(of: pid, in: processTable()).reversed() { kill(child, SIGTERM) }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// `ps -axo pid=,ppid=` output: one "pid ppid" pair per line.
    static func processTable() -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Every process below `pid`, parents before their children.
    static func descendants(of pid: Int32, in table: String) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for line in table.split(separator: "\n") {
            let fields = line.split(separator: " ").compactMap { Int32($0) }
            if fields.count == 2 { children[fields[1], default: []].append(fields[0]) }
        }
        var found: [Int32] = []
        var queue = children[pid] ?? []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard !found.contains(next), next != pid else { continue }
            found.append(next)
            queue += children[next] ?? []
        }
        return found
    }
}

/// Decides how a supervised wait ends: the first of exit, time limit and cancellation wins.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Error>?
    private var outcome: Result<Int32, Error>?

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return outcome != nil }

    func attach(_ continuation: CheckedContinuation<Int32, Error>) {
        lock.lock()
        if let outcome { lock.unlock(); continuation.resume(with: outcome); return }
        self.continuation = continuation
        lock.unlock()
    }

    /// True when this call decided the outcome.
    @discardableResult
    func finish(_ result: Result<Int32, Error>) -> Bool {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return false }
        outcome = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
        return true
    }
}
