import Foundation

/// Legendary (https://github.com/legendary-gl/legendary, GPL-3.0-or-later): an open-source client for Epic Games' store, the
/// way Heroic Games Launcher gets Epic games without Epic's own launcher. G-Player runs it as a separate program, on
/// arguments and output, and never links it or ships it: the user's Mac downloads it from its GitHub release the first time
/// the user signs in to Epic, and every use checks the file against a pinned SHA-256.
///
/// Its login, its list of installed games and its settings live in `Tools/legendary-config` of the library (folder 0700;
/// `LEGENDARY_CONFIG_PATH`), never in the user's home folder. The commands are built by `LegendaryCommand` and read by
/// `LegendaryOutput`; this runs them. stdin is closed, so nothing can wait for an answer.
public struct Legendary: Sendable {
    public static let version = "0.21.1"

    /// Release 0.21.1 of legendary-gl/legendary, the Apple Silicon build (a PyInstaller bundle, 15 275 984 bytes).
    static let download = PinnedDownload(
        url: URL(string: "https://github.com/legendary-gl/legendary/releases/download/0.21.1/legendary_macOS_arm64")!,
        fileName: "legendary",
        sha256: "d87978321dba9cb731fab40c72f0a30bed55baca8b5341ab21024c5733cd837e",
        approximateBytes: 15_275_984)

    public let paths: LibraryPaths
    /// A stand-in program, for tests.
    private let override: URL?

    public init(paths: LibraryPaths) { self.paths = paths; self.override = nil }

    init(paths: LibraryPaths, executable: URL) { self.paths = paths; self.override = executable }

    /// `Tools/legendary-0.21.1`: a new version gets a folder of its own, and the old one's goes when nothing needs it.
    public var toolFolder: URL { paths.tools.appendingPathComponent("legendary-\(Self.version)", isDirectory: true) }
    public var executable: URL { override ?? toolFolder.appendingPathComponent(Self.download.fileName) }
    public var configFolder: URL { paths.tools.appendingPathComponent("legendary-config", isDirectory: true) }

    /// Legendary is on this Mac. (Whether it is the pinned file is checked when it is used: `ensureInstalled`.)
    public var isDownloaded: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    // MARK: Settings (pure)

    /// What G-Player needs in `config.ini`: Windows as the platform (Legendary's default on a Mac is `Mac`), no search for
    /// CrossOver (G-Player passes `--wine` itself), and no check for a newer Legendary (a request to legendary.gl at every
    /// login).
    static let requiredSettings: [(key: String, value: String)] = [
        ("default_platform", "Windows"), ("disable_auto_crossover", "true"), ("disable_update_check", "true"),
    ]

    /// `existing` with the required settings in its `[Legendary]` section, and every other line as it was: Legendary keeps
    /// its own notes in the file (which install tags a game has). Nil or empty `existing` gives a new file.
    static func config(updating existing: String?) -> String {
        var lines = (existing ?? "").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let section = "[Legendary]"
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == section }) else {
            if !lines.isEmpty { lines.append("") }
            lines.append(section)
            lines += requiredSettings.map { "\($0.key) = \($0.value)" }
            return lines.joined(separator: "\n") + "\n"
        }
        var end = lines.index(after: header)
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        var insert = lines.index(after: header)
        for (key, value) in requiredSettings {
            let wanted = "\(key) = \(value)"
            let found = (lines.index(after: header)..<end).first { index in
                lines[index].split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == key
            }
            if let found {
                lines[found] = wanted
            } else {
                lines.insert(wanted, at: insert)
                insert += 1
                end += 1
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Legendary's environment: what a program needs to find its way, a proxy if the Mac uses one, and its settings folder.
    /// Nothing else is passed on, least of all `CX_BOTTLE` or `WINEPREFIX` from wherever G-Player was started: Legendary
    /// would send the game to that bottle.
    static func environment(configFolder: URL, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [:]
        let passed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]
            + ["http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]
        for key in passed { if let value = base[key] { env[key] = value } }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["LEGENDARY_CONFIG_PATH"] = configFolder.path
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    // MARK: Setting up

    /// Makes the settings folder (only its owner may enter it: the login is in it) and writes `config.ini`.
    func prepareConfig() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configFolder.path)
        let file = configFolder.appendingPathComponent("config.ini")
        let current = try? String(contentsOf: file, encoding: .utf8)
        let wanted = Self.config(updating: current)
        if wanted != current { try wanted.write(to: file, atomically: true, encoding: .utf8) }
    }

    /// Makes sure the pinned Legendary is on this Mac: downloads it when it isn't there (or isn't the pinned file), makes it
    /// executable and clears the quarantine mark, as for the engine's files. `progress` gets the fraction downloaded.
    public func ensureInstalled(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try prepareConfig()
        guard override == nil else { return }
        let file = try await RuntimeInstaller.fetch(Self.download, into: toolFolder, progress: progress)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        await Files.clearQuarantine(file)
    }

    // MARK: Running

    /// Runs Legendary and waits for it. A task that is cancelled stops it and what it started (`CancellationError`); so does
    /// `timeout` (`Supervised.TimedOut`). The text of stdout is complete, stderr's is its last 64 KB.
    /// - Parameters:
    ///   - log: where every line of stderr is written as it comes. Never for a command that carries a code or a login.
    ///   - onLine: gets every line of stderr (a progress line ends in `\r` or `\n`).
    ///   - stopWhen: asked about every line of stderr; Legendary is stopped at the first line it says yes to, and the result comes
    ///     back as usual (with the status of a program that was stopped).
    public func run(_ arguments: [String], timeout: TimeInterval? = 60, log: URL? = nil,
                    stopWhen: (@Sendable (String) -> Bool)? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        try prepareConfig()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Self.environment(configFolder: configFolder)
        process.currentDirectoryURL = configFolder
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collector = Collector(log: log, onLine: onLine, stopWhen: stopWhen) { Supervised.terminate(process) }
        defer { collector.finish() }

        let status = try await Supervised.run(timeout: timeout, stop: { Supervised.terminate(process) }) { finish in
            for (pipe, isError) in [(out, false), (err, true)] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        collector.pipeEnded()
                    } else {
                        collector.append(data, isError: isError)
                    }
                }
            }
            process.terminationHandler = { finished in
                // What is still in the pipes is read first. A program Legendary left running can hold a pipe open, so this
                // waits two seconds at most.
                collector.waitForPipes(seconds: 2)
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                Running.shared.remove(finished)
                finish(finished.terminationStatus)
            }
            Running.shared.add(process)
            do { try process.run() } catch {
                Running.shared.remove(process)
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                throw error
            }
        }
        return collector.result(status: status)
    }

    /// Stops every Legendary G-Player started that is still running (a download goes on from its resume file next time). For
    /// when G-Player quits: a download left running would go on with no window to show it.
    public static func stopRunning() { Running.shared.terminateAll() }

    // MARK: Operations

    private func fail(_ result: ProcessResult) -> ShellError {
        .failed(LegendaryFailure.reason(stdout: result.stdout, stderr: result.stderr, status: result.status))
    }

    /// Who is signed in, from what is on this Mac.
    public func status() async throws -> LegendaryStatus {
        let result = try await run(LegendaryCommand.status)
        guard result.succeeded, let status = LegendaryOutput.status(result.stdout) else { throw fail(result) }
        return status
    }

    /// Signs in with the code Epic's page gave and returns who is signed in. Legendary exits with 0 when the code is refused,
    /// so what counts is that its status shows an account afterwards.
    public func signIn(code: String) async throws -> LegendaryStatus {
        guard EpicSignIn.plausible(code) != nil else { throw ShellError.failed("That isn't a code from Epic's sign-in page.") }
        let result = try await run(LegendaryCommand.signIn(code: code), timeout: 120)
        let status = try await status()
        guard status.isSignedIn else {
            if LegendaryFailure.kind(stderr: result.stderr) == .network { throw fail(result) }
            throw ShellError.failed("Epic didn't accept the sign-in. Try again.")
        }
        return status
    }

    /// Forgets the login on this Mac. Installed games stay where they are.
    public func signOut() async throws {
        let result = try await run(LegendaryCommand.signOut)
        guard try await status().isSignedIn == false else { throw fail(result) }
    }

    /// The games the account owns. Asks Epic, so it needs the network; a few seconds, and a minute for a big library the
    /// first time.
    public func library() async throws -> [EpicGame] {
        let result = try await run(LegendaryCommand.library, timeout: 10 * 60)
        guard result.succeeded, let games = LegendaryOutput.library(result.stdout) else { throw fail(result) }
        return games
    }

    /// The games Legendary has installed, from what is on this Mac.
    public func installedGames() async throws -> [LegendaryInstalledGame] {
        let result = try await run(LegendaryCommand.installed)
        guard result.succeeded, let games = LegendaryOutput.installed(result.stdout) else { throw fail(result) }
        return games
    }

    /// Installs a game into `basePath` (Legendary makes the game's own folder in it) and waits. `status` hears how far it is.
    /// `hasRoom` is asked once, with the game's size on disk, when Legendary reports it, which is before it starts downloading;
    /// a reason it returns stops the install with that reason as the error (Legendary checks the room itself too, in words of
    /// its own). Cancelling the task stops Legendary; what was downloaded stays, and installing again goes on from there. What
    /// counts as done is the game showing up as installed: Legendary exits with 0 after some failures.
    public func install(_ appName: String, basePath: URL, log: URL? = nil, hasRoom: @escaping @Sendable (Int64) -> String? = { _ in nil },
                        status: @escaping @Sendable (LegendaryInstallStatus) -> Void) async throws {
        guard LegendaryCommand.isAppName(appName) else { throw ShellError.failed("“\(appName)” isn't a name Epic gives a game.") }
        try FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)
        let current = StatusBox()
        let lacking = Reason()
        let result = try await run(LegendaryCommand.install(appName: appName, basePath: basePath), timeout: nil, log: log, stopWhen: { line in
            guard let size = LegendaryInstallStatus.installSize(in: line), let problem = hasRoom(size) else { return false }
            lacking.set(problem)
            return true
        }, onLine: { line in
            if let update = current.take(line) { status(update) }
        })
        if let problem = lacking.value { throw ShellError.failed(problem) }
        guard (try? await installedGames())?.contains(where: { $0.appName == appName }) == true else { throw fail(result) }
        // TODO: a game's prerequisites (Visual C++, DirectX): on a Mac Legendary only records them (`prereq_info`).
    }

    /// Removes a game and its files. Legendary exits with 0 when it can't, so the game must be gone from its list.
    public func uninstall(_ appName: String) async throws {
        guard LegendaryCommand.isAppName(appName) else { throw ShellError.failed("“\(appName)” isn't a name Epic gives a game.") }
        let result = try await run(LegendaryCommand.uninstall(appName: appName), timeout: 10 * 60)
        guard try await !installedGames().contains(where: { $0.appName == appName }) else { throw fail(result) }
    }

    /// How to start an installed game. Online first: Legendary asks Epic for a one-time code that logs the game in, so what
    /// comes back is for right now. When Epic can't be reached it asks again with `--offline`, which most single-player games
    /// accept. A signed-out account is not retried: no login means no launch either way.
    public func launchParameters(for appName: String, wine: URL) async throws -> LegendaryLaunch {
        guard LegendaryCommand.isAppName(appName) else { throw ShellError.failed("“\(appName)” isn't a name Epic gives a game.") }
        let online = try await run(LegendaryCommand.launch(appName: appName, wine: wine, offline: false), timeout: 90)
        if online.succeeded, let launch = LegendaryOutput.launch(online.stdout) { return launch }
        if LegendaryFailure.kind(stderr: online.stderr) == .signedOut { throw fail(online) }
        let offline = try await run(LegendaryCommand.launch(appName: appName, wine: wine, offline: true), timeout: 60)
        guard offline.succeeded, let launch = LegendaryOutput.launch(offline.stdout) else { throw fail(offline) }
        return launch
    }
}

// MARK: - Running processes

/// The Legendary processes that are running, so quitting G-Player can stop them.
private final class Running: @unchecked Sendable {
    static let shared = Running()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func add(_ process: Process) { lock.lock(); processes[ObjectIdentifier(process)] = process; lock.unlock() }
    func remove(_ process: Process) { lock.lock(); processes[ObjectIdentifier(process)] = nil; lock.unlock() }

    func terminateAll() {
        lock.lock(); let running = Array(processes.values); lock.unlock()
        for process in running { Supervised.terminate(process) }
    }
}

/// The status of an install as its lines come in, and nothing for a line that changes nothing.
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status = LegendaryInstallStatus()

    func take(_ line: String) -> LegendaryInstallStatus? {
        lock.lock(); defer { lock.unlock() }
        return status.take(line) ? status : nil
    }
}

/// Why an install was stopped, set from the thread that reads Legendary's output.
private final class Reason: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    func set(_ reason: String) { lock.lock(); if text == nil { text = reason }; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return text }
}

/// Collects a process's output: stdout whole, the end of stderr, and stderr as lines (to a log and to a listener).
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var partial = Data()
    private var finished = false
    private var log: FileHandle?
    private let onLine: (@Sendable (String) -> Void)?
    private let stopWhen: (@Sendable (String) -> Bool)?
    private let stop: @Sendable () -> Void
    private var stopped = false
    private let ended = DispatchSemaphore(value: 0)
    /// How much of stderr's end is kept for the result.
    private static let keep = 64 * 1024

    init(log: URL?, onLine: (@Sendable (String) -> Void)?, stopWhen: (@Sendable (String) -> Bool)?, stop: @escaping @Sendable () -> Void) {
        self.onLine = onLine
        self.stopWhen = stopWhen
        self.stop = stop
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            self.log = try? FileHandle(forWritingTo: log)
        }
    }

    func append(_ data: Data, isError: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        guard isError else { out.append(data); return }
        err.append(data)
        if err.count > Self.keep { err.removeFirst(err.count - Self.keep) }
        partial.append(data)
        while let end = partial.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: partial[partial.startIndex..<end], as: UTF8.self)
            partial.removeSubrange(partial.startIndex...end)
            emit(line)
        }
    }

    private func emit(_ line: String) {
        guard !line.isEmpty else { return }
        log?.write(Data((line + "\n").utf8))
        onLine?(line)
        if !stopped, stopWhen?(line) == true {
            stopped = true
            stop()
        }
    }

    func pipeEnded() { ended.signal() }

    func waitForPipes(seconds: Double) {
        let deadline = DispatchTime.now() + seconds
        for _ in 0..<2 { if ended.wait(timeout: deadline) == .timedOut { return } }
    }

    /// Later output is dropped, never written to a closed log.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if !partial.isEmpty { emit(String(decoding: partial, as: UTF8.self)); partial.removeAll() }
        try? log?.close()
        log = nil
    }

    func result(status: Int32) -> ProcessResult {
        finish()
        lock.lock(); defer { lock.unlock() }
        return ProcessResult(status: status, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
    }
}
