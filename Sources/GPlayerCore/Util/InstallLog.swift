import Foundation

/// What an engine install went through, written to the library's Logs folder when it ends: each step it reached
/// ("Downloading …", "Checking …", "Unpacking …"), and how it ended, with the error's full text when it failed. A
/// background update that fails says so in one line on screen; this keeps the why for later.
public final class InstallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var lastStep = ""
    private let started = Date()
    private let title: String

    public init(title: String) { self.title = title }

    /// Records `message` when it starts a new step: progress within one ("Downloading 41 of 98 MB", then 42 of 98) is
    /// one step, so the log stays short.
    public func record(_ message: String) {
        let step = Self.step(of: message)
        lock.lock(); defer { lock.unlock() }
        guard step != lastStep else { return }
        lastStep = step
        lines.append("\(Self.elapsed(since: started)) \(message)")
    }

    /// The step a progress message belongs to: its words before the first number ("Downloading", "Unpacking x.tar.xz").
    static func step(of message: String) -> String {
        let words = message.split(separator: " ")
        return words.prefix { $0.first?.isNumber != true }.joined(separator: " ")
    }

    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(start).rounded())
        return String(format: "[%02d:%02d]", s / 60, s % 60)
    }

    /// The log's text, ended with `outcome` ("Ready", "Stopped", or the error).
    public func text(outcome: String, at now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        return ([title] + lines + ["\(Self.elapsed(since: started, now: now)) \(outcome)"]).joined(separator: "\n") + "\n"
    }

    /// Writes the log as "<title> <time>.log" in `folder`. A log that can't be written is no reason to fail anything.
    public func write(outcome: String, to folder: URL) {
        let stamp = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("\(Files.safeName(title)) \(stamp).log")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text(outcome: outcome).write(to: file, atomically: true, encoding: .utf8)
    }

    /// How an install that threw ended, in words: the error's description, and its full form when that says more.
    public static func failure(_ error: Error) -> String {
        let shown = error.localizedDescription
        let full = String(describing: error)
        return full == shown ? "Failed: \(shown)" : "Failed: \(shown)\n\(full)"
    }
}
