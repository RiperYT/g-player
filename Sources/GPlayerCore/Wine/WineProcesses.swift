import Foundation

/// Which Windows programs run in a space, read from the Mac's process list. Installers and settings changes wait for
/// every program in a space to quit, so G-Player doesn't start them while a game or Steam is open.
public enum WineProcesses {
    /// The command line of every process on the Mac, one per line (`ps -axo command=`). It takes a moment, so the
    /// caller runs it off the main thread.
    public static func commandLines() -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// True when a program of the space runs: some command line holds the path of its `drive_c`, or sets
    /// `WINEPREFIX=<space path> ` (with the space after it, so `Main` doesn't match `Main 2`).
    public static func isRunning(in space: Space, commandLines: String) -> Bool {
        !lines(of: space, in: commandLines).isEmpty
    }

    /// True when Steam runs in the space: one of its programs (`steam.exe`, `steamwebhelper.exe`, `steamservice.exe`)
    /// is among the space's processes.
    public static func isSteamRunning(in space: Space, commandLines: String) -> Bool {
        lines(of: space, in: commandLines).contains { line in
            let lower = line.lowercased()
            return lower.contains("steam.exe") || lower.contains("steamwebhelper") || lower.contains("steamservice.exe")
        }
    }

    /// The command lines that belong to the space.
    private static func lines(of space: Space, in commandLines: String) -> [Substring] {
        let driveC = space.driveC.path
        let prefix = "WINEPREFIX=\(space.path) "
        return commandLines.split(separator: "\n").filter { $0.contains(driveC) || $0.contains(prefix) }
    }
}

/// A Windows program running on the Mac, as the process list shows it.
public struct WineProcess: Sendable, Hashable {
    public let pid: Int32
    /// Its command line: a Windows path (`C:\…\steam.exe -silent`) or, for programs G-Player started, a Mac path.
    public let command: String
    /// The Mac folder it works in. Wine keeps a program's working folder in step with its Windows current folder,
    /// which lies in the space's `drive_c` for programs installed there, so this tells which space it belongs to
    /// even when the command line doesn't.
    public var directory: String?

    public init(pid: Int32, command: String, directory: String? = nil) {
        self.pid = pid; self.command = command; self.directory = directory
    }

    /// "steam.exe": the file name of the program, lowercased, if the command line names a .exe.
    public var programName: String? {
        guard let end = command.range(of: ".exe", options: .caseInsensitive) else { return nil }
        let path = command[..<end.upperBound]
        let start = path.lastIndex { $0 == "\\" || $0 == "/" }.map { path.index(after: $0) } ?? path.startIndex
        return String(path[start...]).lowercased()
    }

    /// Wine's own background programs (services.exe, explorer.exe /desktop…), which run as long as anything does.
    public var isWineService: Bool { command.lowercased().hasPrefix(#"c:\windows\"#) }
}

extension WineProcesses {
    /// Every Windows program running on the Mac, with its working folder. Reads `ps` and `lsof`, so it takes a
    /// moment: call it off the main thread.
    public static func snapshot() -> [WineProcess] {
        let found = windowsPrograms(inProcessList: run("/bin/ps", ["-axww", "-o", "pid=,command="]))
        guard !found.isEmpty else { return [] }
        let folders = workingFolders(inLsof: run("/usr/sbin/lsof", ["-nP", "-a", "-d", "cwd", "-Fpn", "-p",
                                                                    found.map { String($0.pid) }.joined(separator: ",")]))
        return found.map { var p = $0; p.directory = folders[p.pid]; return p }
    }

    /// The programs among `processes` that belong to the space: they work in a folder inside it, or their command
    /// line is a program from its `drive_c`.
    public static func programs(in space: Space, from processes: [WineProcess]) -> [WineProcess] {
        let roots = Set([space.url.standardizedFileURL.path, space.url.resolvingSymlinksInPath().path])
        let driveCs = roots.map { $0 + "/drive_c/" }
        return processes.filter { p in
            if let dir = p.directory, roots.contains(where: { dir == $0 || dir.hasPrefix($0 + "/") }) { return true }
            return driveCs.contains { p.command.contains($0) }
        }
    }

    /// True when a program other than Wine's own services runs in the space.
    public static func isRunning(in space: Space, processes: [WineProcess]) -> Bool {
        programs(in: space, from: processes).contains { !$0.isWineService }
    }

    /// True when Steam or one of its helpers runs in the space.
    public static func isSteamRunning(in space: Space, processes: [WineProcess]) -> Bool {
        programs(in: space, from: processes).contains { p in
            guard let name = p.programName else { return false }
            return name == "steam.exe" || name.hasPrefix("steamwebhelper") || name == "steamservice.exe"
        }
    }

    // MARK: Reading the lists

    /// `pid command` lines from `ps`, keeping the ones that are Windows programs: a command line that starts with a
    /// drive letter, names a program in a `drive_c`, or names a .exe.
    static func windowsPrograms(inProcessList text: String) -> [WineProcess] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { return nil }
            let command = String(trimmed[trimmed.index(after: space)...])
            let isWindows = command.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil
                || command.contains("/drive_c/") || command.range(of: ".exe", options: .caseInsensitive) != nil
            return isWindows ? WineProcess(pid: pid, command: command) : nil
        }
    }

    /// pid → working folder from `lsof -Fpn` output (`p<pid>` and `n<path>` lines).
    static func workingFolders(inLsof text: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            else if line.hasPrefix("n"), let p = pid { result[p] = String(line.dropFirst()) }
        }
        return result
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
