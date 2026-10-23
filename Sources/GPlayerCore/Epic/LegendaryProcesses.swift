import Darwin
import Foundation

/// The processes Legendary runs as, kept in a file so that a G-Player that crashed (or was killed) doesn't leave an install
/// running for ever, holding Legendary's lock: the next start ends the ones that are still there. The file is
/// `running.pids` in Legendary's settings folder, one process id a line.
enum PidFile {
    private static let lock = NSLock()

    static func parse(_ text: String) -> [Int32] {
        var seen = Set<Int32>()
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 1 && seen.insert($0).inserted }
    }

    static func text(_ pids: [Int32]) -> String { pids.map(String.init).joined(separator: "\n") + (pids.isEmpty ? "" : "\n") }

    static func read(_ file: URL) -> [Int32] { parse((try? String(contentsOf: file, encoding: .utf8)) ?? "") }

    static func record(_ pid: Int32, in file: URL) { change(file) { pids in if !pids.contains(pid) { pids.append(pid) } } }

    static func forget(_ pid: Int32, in file: URL) { change(file) { $0.removeAll { $0 == pid } } }

    /// Replaces what the file holds.
    static func write(_ pids: [Int32], to file: URL) { change(file) { $0 = pids } }

    private static func change(_ file: URL, _ edit: (inout [Int32]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var pids = read(file)
        edit(&pids)
        if pids.isEmpty { try? FileManager.default.removeItem(at: file) }
        else { try? text(pids).write(to: file, atomically: true, encoding: .utf8) }
    }
}

extension Legendary {
    var pidFile: URL { configFolder.appendingPathComponent("running.pids") }

    /// Ends the Legendary programs an earlier G-Player left running, which the file of process ids says: only a process that is
    /// still there and runs this very Legendary file (a process id can be given to another program since), and not one this
    /// run of G-Player started. Call it before Legendary is used. Returns how many it ended.
    @discardableResult
    public func endLeftovers() -> Int { endLeftovers(pathOf: Self.executablePath(of:), terminate: Self.terminateTree) }

    func endLeftovers(pathOf: (Int32) -> String?, terminate: (Int32) -> Void) -> Int {
        let ours = Running.shared.pids(in: pidFile)
        var ended = 0
        for pid in PidFile.read(pidFile) where !ours.contains(pid) {
            guard let path = pathOf(pid), Self.samePath(path, executable.path) else { continue }
            terminate(pid)
            ended += 1
        }
        PidFile.write(Array(ours), to: pidFile)
        return ended
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    /// The file a process runs, or nil when there is no such process.
    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Stops a process and what it started (Legendary's downloaders): SIGTERM, and SIGKILL after three seconds for what is still there.
    static func terminateTree(_ pid: Int32) {
        let tree = Supervised.descendants(of: pid, in: Supervised.processTable()).reversed() + [pid]
        for process in tree { kill(process, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for process in tree where kill(process, 0) == 0 { kill(process, SIGKILL) }
        }
    }
}
