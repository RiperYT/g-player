import Darwin
import Foundation

/// A Windows program running on the Mac, as the kernel's process table shows it.
public struct WineProcess: Sendable, Hashable {
    public let pid: Int32
    /// Its command line: a Windows path (`C:\…\steam.exe -silent`) or, for programs G-Player started, a Mac path.
    public let command: String
    /// The Mac folder it works in. Wine keeps a program's working folder in step with its Windows current folder,
    /// which lies in the space's `drive_c` for programs installed there, or in the game's folder elsewhere.
    public var directory: String?
    /// `WINEPREFIX` from its environment. Only programs started straight from the Mac (by G-Player or a script)
    /// have it; Windows programs those start don't show their environment.
    public var prefix: String?
    /// "steam.exe": the file name of the program, lowercased, if the command line names a .exe.
    public let programName: String?

    public init(pid: Int32, command: String, directory: String? = nil, prefix: String? = nil) {
        self.pid = pid; self.command = command; self.directory = directory; self.prefix = prefix
        programName = Self.programName(in: command)
    }

    static func programName(in command: String) -> String? {
        guard let end = command.range(of: ".exe", options: .caseInsensitive) else { return nil }
        let path = command[..<end.upperBound]
        let start = path.lastIndex { $0 == "\\" || $0 == "/" }.map { path.index(after: $0) } ?? path.startIndex
        return String(path[start...]).lowercased()
    }

    /// Wine's own background programs, which run as long as anything in the space does. Tools the user opens from
    /// C:\windows (winecfg, regedit, msiexec, cmd…) are not among them.
    public var isWineService: Bool {
        let lower = command.lowercased()
        guard lower.hasPrefix(#"c:\windows\"#) else { return false }
        if programName == "explorer.exe" { return lower.contains("/desktop") }
        return Self.services.contains(programName ?? "")
    }

    static let services: Set<String> = ["services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe",
                                        "lsass.exe", "conhost.exe", "tabtip.exe", "wineboot.exe", "mscorsvw.exe"]
}

/// A running process and the program file it runs from, as the kernel says (`proc_pidpath`).
public struct ProcessExecutable: Sendable, Hashable {
    public let pid: Int32
    public let path: String

    public init(pid: Int32, path: String) { self.pid = pid; self.path = path }
}

/// Which Windows programs run where. Installers wait for every program in a space to quit, so G-Player doesn't start
/// them while a game or Steam is open, and the library shows what is running.
public enum WineProcesses {
    /// Every Windows program running on the Mac, with its working folder and, when it shows, its `WINEPREFIX`. Reads
    /// the kernel's process table directly (no `ps`), so names in any language come through; still, call it off the
    /// main thread.
    public static func snapshot() -> [WineProcess] {
        allPIDs().compactMap { pid in
            guard let (arguments, environment) = arguments(of: pid) else { return nil }
            let command = arguments.joined(separator: " ")
            guard isWindowsProgram(command) else { return nil }
            return WineProcess(pid: pid, command: command, directory: workingFolder(of: pid),
                               prefix: environment["WINEPREFIX"])
        }
    }

    /// The programs among `processes` that belong to the space: started with its `WINEPREFIX`, working in a folder
    /// inside it, or running a program from its `drive_c`.
    public static func programs(in space: Space, from processes: [WineProcess]) -> [WineProcess] {
        let roots = paths(of: space.url)
        return processes.filter { p in
            if let prefix = p.prefix, roots.contains(standardized(prefix)) { return true }
            if let dir = p.directory, roots.contains(where: { isInside(dir, $0) }) { return true }
            return roots.contains { p.command.contains($0 + "/drive_c/") }
        }
    }

    /// True when a program other than Wine's own services runs in the space.
    public static func isRunning(in space: Space, processes: [WineProcess]) -> Bool {
        programs(in: space, from: processes).contains { !$0.isWineService }
    }

    /// What runs in the space, counted to catch Wine starting programs without end (`SpaceLoad`). Wine's programs
    /// have lost their parent (the launch daemon is it), so the parent says nothing: a program is the space's by where
    /// it works and what it was started with, as in `programs(in:from:)`. `alsoAttributed` adds programs found another
    /// way, such as those of a game kept outside the space's folder (`RunningGames.programs`).
    public static func load(of space: Space, from processes: [WineProcess], alsoAttributed: [WineProcess] = []) -> SpaceLoad {
        var seen = Set<Int32>()
        let mine = (programs(in: space, from: processes) + alsoAttributed).filter { seen.insert($0.pid).inserted }
        return SpaceLoad(processes: mine)
    }

    /// True when Steam or one of its helpers runs in the space.
    /// Steam's helpers (its web helpers and its service) left in `space` after steam.exe itself has gone. They don't go on
    /// their own every time, and while they stay the space never empties, so a Steam that should restart never can.
    /// Empty while steam.exe runs: then they are Steam's, not leftovers.
    public static func orphanedSteamHelpers(in space: Space, processes: [WineProcess]) -> [WineProcess] {
        let steam = programs(in: space, from: processes).filter { p in
            guard let name = p.programName else { return false }
            return name == "steam.exe" || name.hasPrefix("steamwebhelper") || name == "steamservice.exe"
        }
        return steam.contains { $0.programName == "steam.exe" } ? [] : steam
    }

    public static func isSteamRunning(in space: Space, processes: [WineProcess]) -> Bool {
        programs(in: space, from: processes).contains { p in
            guard let name = p.programName else { return false }
            return name == "steam.exe" || name.hasPrefix("steamwebhelper") || name == "steamservice.exe"
        }
    }

    /// The programs of one game: those working in its folder (any space, so a game kept outside its space's
    /// `drive_c` counts), or naming a program inside it. A launcher has no folder of its own worth matching (Steam's
    /// games live inside Steam's folder), so it is matched by its program name within its space instead.
    public static func programs(ofGameIn folder: URL?, programName: String?, space: Space,
                                from processes: [WineProcess]) -> [WineProcess] {
        if let folder {
            let roots = paths(of: folder)
            return processes.filter { p in
                if p.isWineService { return false }
                if let dir = p.directory, roots.contains(where: { isInside(dir, $0) }) { return true }
                return roots.contains { p.command.contains($0 + "/") }
            }
        }
        guard let name = programName?.lowercased() else { return [] }
        return programs(in: space, from: processes).filter { $0.programName == name }
    }

    /// Every process on the Mac with the file it runs from, whatever it is. Wine's own `wine-preloader` and `wineserver` are
    /// among them, which `snapshot()` (Windows programs only) never lists. Reads the kernel's process table directly; call it
    /// off the main thread.
    public static func executables() -> [ProcessExecutable] {
        allPIDs().compactMap { pid in
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))              // PROC_PIDPATHINFO_MAXSIZE
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return ProcessExecutable(pid: pid, path: String(cString: buffer))
        }
    }

    /// The processes among `executables` that run a file inside `folder`: what makes an engine's folder in use, whichever of
    /// its programs it is. Compared without regard to case, as the Mac's usual volumes do; on one that cares, a similarly named
    /// folder only holds a deletion back.
    public static func executables(inside folder: URL, from executables: [ProcessExecutable]) -> [ProcessExecutable] {
        let roots = paths(of: folder).map { $0.lowercased() }
        return executables.filter { executable in
            let path = executable.path.lowercased()
            return roots.contains { isInside(path, $0) }
        }
    }

    // MARK: Paths

    /// A folder's path as given and with symlinks resolved, without a trailing slash. The kernel reports working
    /// folders through `/private` (`/private/var/folders/…`), which `resolvingSymlinksInPath` strips, so both forms
    /// are kept.
    static func paths(of url: URL) -> Set<String> {
        var all = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
        if let real = realpath(url.path, nil) { all.append(String(cString: real)); free(real) }
        for path in all {
            if path.hasPrefix("/private/") { all.append(String(path.dropFirst("/private".count))) }
            else if ["/var/", "/tmp/", "/etc/"].contains(where: path.hasPrefix) { all.append("/private" + path) }
        }
        return Set(all.map { standardized($0) })
    }

    static func standardized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// `path` is `folder` or inside it (`/a/Main` is not inside `/a/Main 2`).
    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    /// A command line that is a Windows program: it starts with a drive letter, runs something from a `drive_c`, or
    /// names a .exe.
    static func isWindowsProgram(_ command: String) -> Bool {
        command.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil
            || command.contains("/drive_c/") || command.range(of: ".exe", options: .caseInsensitive) != nil
    }

    // MARK: The process table

    private static func allPIDs() -> [pid_t] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return count > 0 ? pids.prefix(Int(count)).filter { $0 > 0 } : []
    }

    /// The arguments and environment of a process (the user's own processes only), from `KERN_PROCARGS2`.
    static func arguments(of pid: pid_t) -> ([String], [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2` layout: argc (Int32), the executable path, NUL padding, then argc arguments and the
    /// environment, each NUL-terminated.
    static func parseProcArgs(_ bytes: [UInt8]) -> ([String], [String: String])? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0 else { return nil }
        var i = 4
        while i < bytes.count, bytes[i] != 0 { i += 1 }          // executable path
        while i < bytes.count, bytes[i] == 0 { i += 1 }          // padding
        func next() -> String? {
            guard i < bytes.count else { return nil }
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }
        var args: [String] = []
        for _ in 0..<argc { guard let a = next() else { break }; args.append(a) }
        var env: [String: String] = [:]
        while let entry = next(), !entry.isEmpty {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return (args, env)
    }

    /// The process's working folder (`proc_pidinfo` with `PROC_PIDVNODEPATHINFO`).
    private static func workingFolder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// The Windows programs of one space, and whether there are far more than a space ever runs. A prefix Wine can't
/// start in (one whose path is too long, say) makes `explorer.exe /desktop` fail, and every Wine program then starts
/// another one until the Mac can't start any process. G-Player stops a space past these limits at once.
public struct SpaceLoad: Sendable {
    /// More copies of Explorer than this: a space has one for its desktop, and one per Explorer window the user opens.
    public static let maxExplorers = 12
    /// More programs than this in one space: Wine's services, Steam and its helpers, and a game with its own helpers
    /// come to a few dozen.
    public static let maxPrograms = 200

    public let processes: [WineProcess]

    public var programs: Int { processes.count }
    public var explorers: Int { processes.filter { $0.programName == "explorer.exe" }.count }

    /// Past a limit: stop the space.
    public var isRunaway: Bool { explorers > Self.maxExplorers || programs > Self.maxPrograms }
    /// Past half a limit: worth looking at again soon.
    public var isGrowing: Bool { explorers > Self.maxExplorers / 2 || programs > Self.maxPrograms / 2 }

    /// What to tell the user after the space was stopped: what happened, and what usually causes it.
    public func message(spaceName: String) -> String {
        let what = explorers > Self.maxExplorers
            ? String(localized: "\(programs) Windows programs were running, \(explorers) of them Windows Explorer")
            : String(localized: "\(programs) Windows programs were running")
        return String(localized: "“\(spaceName)” was starting Windows programs without end: \(what).") + " "
            + String(localized: "G-Player stopped everything in it to keep your Mac usable. A long folder path is the usual cause. Keep a space's path under \(PrefixPath.maxLength) characters.")
    }
}

/// Which library entries are running, from the process table.
public enum RunningGames {
    /// How a game's programs are recognised: by the folder it lives in, or (launchers, and games whose folder is
    /// too broad to tell apart) by its program's name within its space.
    public struct Key: Sendable, Hashable {
        public let folder: URL?
        public let programName: String?
    }

    public static func key(for game: Game, in space: Space) -> Key {
        if game.kind == .app {
            return Key(folder: nil, programName: game.executablePath.map { ($0 as NSString).lastPathComponent.lowercased() })
        }
        switch game.source {
        case .executable, .legendary:
            guard let exe = game.executableURL(in: space) else { return Key(folder: nil, programName: nil) }
            let folder = exe.deletingLastPathComponent()
            let name = exe.lastPathComponent.lowercased()
            return isTooBroad(folder, in: space) ? Key(folder: nil, programName: name) : Key(folder: folder, programName: name)
        case .steam:
            // The game's own folder under steamapps/common, from the program the analysis looked at.
            guard let path = game.analysis?.programPath, let range = path.range(of: "/steamapps/common/") else {
                return Key(folder: nil, programName: nil)
            }
            let rest = path[range.upperBound...]
            guard let name = rest.split(separator: "/").first else { return Key(folder: nil, programName: nil) }
            return Key(folder: URL(fileURLWithPath: String(path[..<range.upperBound]) + name, isDirectory: true),
                       programName: (path as NSString).lastPathComponent.lowercased())
        case .epic:
            return Key(folder: nil, programName: nil)
        }
    }

    /// A folder many programs share (the space itself, drive_c, Program Files, the user's home): matching by it would
    /// count unrelated programs as the game.
    static func isTooBroad(_ folder: URL, in space: Space) -> Bool {
        let path = WineProcesses.standardized(folder.standardizedFileURL.path)
        let driveC = space.driveC.standardizedFileURL.path
        let broad = [space.url.standardizedFileURL.path, driveC, driveC + "/Program Files", driveC + "/Program Files (x86)",
                     driveC + "/windows", "/", FileManager.default.homeDirectoryForCurrentUser.path]
        return broad.map(WineProcesses.standardized).contains(path)
    }

    /// The running programs of each game, for games that have any.
    public static func programs(of games: [(game: Game, space: Space)], in processes: [WineProcess]) -> [UUID: [WineProcess]] {
        var result: [UUID: [WineProcess]] = [:]
        for (game, space) in games {
            let key = key(for: game, in: space)
            guard key.folder != nil || key.programName != nil else { continue }
            let found = WineProcesses.programs(ofGameIn: key.folder, programName: key.programName, space: space, from: processes)
            if !found.isEmpty { result[game.id] = found }
        }
        return result
    }
}
