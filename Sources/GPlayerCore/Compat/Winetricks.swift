import Foundation

/// Installs any Windows component by running winetricks (https://github.com/Winetricks/winetricks, LGPL-2.1+)
/// as a separate program. The script isn't part of G-Player: it is downloaded once, checked against a pinned
/// SHA-256 on every use, and kept in `Engines/tools/`.
public struct Winetricks: Sendable {
    public static let version = "20260125"

    /// Release 20260125 is tag `20260125` = commit b76e1ee79ac57d7aceb384f74518fc423265810c.
    static let script = PinnedDownload(
        url: URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/b76e1ee79ac57d7aceb384f74518fc423265810c/src/winetricks")!,
        fileName: "winetricks",
        sha256: "431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b",
        approximateBytes: 830_687)

    public let paths: LibraryPaths

    public init(paths: LibraryPaths) { self.paths = paths }

    var toolsFolder: URL { paths.engines.appendingPathComponent("tools", isDirectory: true) }
    /// Winetricks' own download cache (the DirectX and .NET installers); kept so the next space doesn't download again.
    var cacheFolder: URL {
        paths.downloads.appendingPathComponent("components/winetricks-cache", isDirectory: true)
    }

    // MARK: Running

    /// Runs `winetricks -q <verb>` in the space and waits, at most `timeout` seconds (a hung installer is stopped and
    /// the call throws `Supervised.TimedOut`). Cancelling the calling task stops winetricks and what it started,
    /// not the space's Wine server, and throws `CancellationError`. `progress` gets a fraction (nil while unknown)
    /// and a message.
    public func install(_ verb: String, in space: Space, engine: Engine, timeout: TimeInterval = 15 * 60,
                        progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        guard Self.isVerb(verb) else { throw ShellError.failed(String(localized: "\(verb) isn't a component winetricks can install.")) }
        guard let shims = CoreResources.url("shims") else {
            throw ShellError.failed(String(localized: "G-Player's helper scripts are missing. Reinstall G-Player."))
        }
        progress(nil, String(localized: "Getting winetricks"))
        let pristine = try await RuntimeInstaller.fetch(Self.script, into: toolsFolder)
        let runnable = try prepareScript(from: pristine)
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        // Winetricks makes its working files under TMPDIR (it sets W_TMP_EARLY itself, from TMPDIR). A folder of
        // its own per run keeps them away from the Mac's shared temporary folder and is deleted afterwards.
        let scratch = paths.downloads.appendingPathComponent("components/tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let log = paths.logs.appendingPathComponent("winetricks \(Files.safeName(verb)) \(stamp).log")
        let env = Self.environment(engine: engine, space: space, shims: shims, cache: cacheFolder, temporary: scratch)
        progress(nil, String(localized: "Installing \(verb)"))
        let result = try await Self.run(URL(fileURLWithPath: "/bin/bash"), Self.arguments(script: runnable, verb: verb),
                                        environment: env, currentDirectory: cacheFolder, log: log,
                                        timeout: timeout) { line in
            if let message = Self.progressMessage(forLine: line, verb: verb) { progress(nil, message) }
        }
        try Task.checkCancellation()
        await WineLauncher.waitForAll(engine: engine, space: space, timeout: RuntimeInstaller.settleTimeout)
        guard result.status == 0 else {
            throw ShellError.failed(Self.failureReason(output: result.tail, status: result.status, logName: log.lastPathComponent))
        }
    }

    /// The pinned script, with the two safety edits below, next to it. Fails when the script isn't the one pinned.
    func prepareScript(from pristine: URL) throws -> URL {
        let original = try String(contentsOf: pristine, encoding: .utf8)
        guard let edited = Self.hardened(original) else {
            throw ShellError.failed(String(localized: "winetricks \(Self.version) doesn't look the way G-Player expects. Update G-Player."))
        }
        let target = toolsFolder.appendingPathComponent("winetricks-gplayer")
        try edited.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    // MARK: Decisions (pure)

    /// `bash <script> --country=unknown --optout -q <verb>`. `-q` runs installers without questions;
    /// `--country=unknown` stops winetricks from asking ipinfo.io where this Mac is when a download has to be
    /// retried; `--optout` makes sure it never reports which verbs were used (winetricks only reports after an opt-in).
    static func arguments(script: URL, verb: String) -> [String] {
        [script.path, "--country=unknown", "--optout", "-q", verb]
    }

    /// Winetricks' environment for a space. `wine` and `wineserver` are shims that run the engine's x86_64
    /// binaries through Rosetta (`WINE_BIN`/`WINESERVER_BIN` tell winetricks what they really are, so it doesn't
    /// run `lipo` on a script). Tools come from the shims, the engine and the system, never from Homebrew.
    static func environment(engine: Engine, space: Space, shims: URL, cache: URL, temporary: URL? = nil,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = WineEnvironment.make(engine: engine, space: space, backend: .wined3d, base: base)
        if let temporary { env["TMPDIR"] = temporary.path }
        env["PATH"] = [shims.path, engine.wineRoot.appendingPathComponent("bin").path, "/usr/bin:/bin:/usr/sbin:/sbin"]
            .joined(separator: ":")
        env["WINE"] = "wine"
        env["WINESERVER"] = "wineserver"
        env["GPLAYER_WINE"] = engine.wine.path
        env["GPLAYER_WINESERVER"] = engine.wineserver.path
        env["WINE_BIN"] = engine.wine.path
        env["WINESERVER_BIN"] = engine.wineserver.path
        env["W_CACHE"] = cache.path
        env["XDG_CACHE_HOME"] = cache.path
        env["WINETRICKS_DOWNLOADER"] = "curl"
        env["WINETRICKS_LATEST_VERSION_CHECK"] = "disabled"
        // Winetricks' verbs add their own overrides in front of this one. Wine's defaults for Mono and Gecko stay,
        // because the .NET verbs need them; no menu entries get written into the user's home folder.
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"
        env["WINEARCH"] = nil
        return env
    }

    /// Winetricks is made for people who read its warnings. With `-q` it answers its own "SHA256 mismatch,
    /// continue anyway?" with yes, and it installs downloads it has no checksum for. These two edits make both
    /// stop the run. Returns nil if the script doesn't contain the lines (so it isn't the pinned script).
    static func hardened(_ script: String) -> String? {
        let edits: [(find: String, replace: String)] = [
            (#"w_askpermission "SHA256 mismatch!"#, #"w_die "SHA256 mismatch!"#),
            (#"0) _W_shatype="none" ;;"#,
             #"0) w_die "No SHA-256 checksum for ${_W_url:-a download}. G-Player only installs files it can verify." ;;"#),
        ]
        var text = script
        for edit in edits {
            guard text.components(separatedBy: edit.find).count == 2 else { return nil }
            text = text.replacingOccurrences(of: edit.find, with: edit.replace)
        }
        return text
    }

    /// Winetricks commands and menus that aren't components. Given as a verb, some of them open programs, and with `-q`
    /// `annihilate` deletes the whole space. (From the command list of winetricks 20260125.)
    private static let notVerbs: Set<String> = [
        "main", "help", "list", "list-all", "list-cached", "list-download", "list-manual-download", "list-installed",
        "unattended", "attended", "annihilate", "reinstall", "folder", "winecfg", "regedit", "taskmgr", "explorer",
        "uninstaller", "shell", "winecmd", "wine_misc_exe", "die", "arch", "prefix", "mkprefix",
        "apps", "benchmarks", "dlls", "fonts", "games", "settings",
    ]

    /// True for a winetricks verb name (`d3dx9`, `vcrun2008`, `corefonts`): letters, digits, `_`, `.` and `-` after a
    /// letter or digit. Rejects options and anything that could be read as a path, a pattern or a `name=value`
    /// setting (`=`, `*`, `/`, `..`, a leading `-`, whitespace, quotes), `.verb` files, and winetricks' own commands
    /// and category names (`notVerbs`, anything starting with `list`).
    static func isVerb(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 64,
              let first = id.unicodeScalars.first, first.isASCII, CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard id.unicodeScalars.allSatisfy(allowed.contains), !id.contains(".."), !id.lowercased().hasSuffix(".verb") else { return false }
        let name = id.lowercased()
        return !notVerbs.contains(name) && !name.hasPrefix("list")
    }

    /// One line of winetricks output as a short status, or nil when it isn't worth showing.
    static func progressMessage(forLine line: String, verb: String) -> String? {
        if line.hasPrefix("Downloading "), let url = line.dropFirst("Downloading ".count).split(separator: " ").first {
            return String(localized: "Downloading \(url.split(separator: "/").last.map(String.init) ?? String(localized: "files"))")
        }
        if line.hasPrefix(String(localized: "Executing wine ")) || line.hasPrefix(String(localized: "Executing arch ")) { return String(localized: "Installing \(verb)") }
        if line.hasPrefix(String(localized: "Executing cabextract ")) { return String(localized: "Unpacking \(verb)") }
        return nil
    }

    /// What to tell the user when winetricks stopped. `output` is the end of its output.
    static func failureReason(output: String, status: Int32, logName: String) -> String {
        if output.contains("SHA256 mismatch!") {
            return String(localized: "A download doesn't match its checksum. The publisher may have replaced it, so nothing from it was installed. Details: \(logName)")
        }
        if output.contains("No SHA-256 checksum for") {
            return String(localized: "winetricks has no checksum for one of the downloads, so G-Player didn't install it. Details: \(logName)")
        }
        let warning = output.split(separator: "\n").last { $0.hasPrefix("Note: ") || $0.hasPrefix("warning: ") }
        let detail = warning.map { " " + String($0.prefix(200)) } ?? ""
        return String(localized: "winetricks stopped with code \(status).\(detail) Details: \(logName)")
    }

    // MARK: Process

    struct Finished { let status: Int32; let tail: String }

    /// Runs a process, writes its output to `log` and hands every line to `onLine`. Stops the process (and what it
    /// started) when `timeout` seconds pass or the task is cancelled.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                    currentDirectory: URL, log: URL, timeout: TimeInterval? = nil,
                    onLine: @escaping @Sendable (String) -> Void) async throws -> Finished {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lines = LineBuffer { line in
            logHandle.write(Data((line + "\n").utf8))
            onLine(line)
        }

        let status = try await Supervised.run(timeout: timeout, stop: { Supervised.terminate(process) }) { finish in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { lines.endOfOutput() } else { lines.append(data) }
            }
            process.terminationHandler = { finished in
                // Let the handler read what is still in the pipe. A program the process left running (a wineserver)
                // can hold the pipe open, so this waits two seconds at most instead of reading to its end.
                lines.waitForEnd(seconds: 2)
                pipe.fileHandleForReading.readabilityHandler = nil
                lines.finish()                                   // later output is dropped, never written to a closed log
                try? logHandle.close()
                finish(finished.terminationStatus)
            }
            do { try process.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? logHandle.close()
                throw error
            }
        }
        return Finished(status: status, tail: lines.tail)
    }
}

/// Splits process output into lines and keeps the last ones. Lines are handed on in order, and none after `finish`.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = Data()
    private var last: [String] = []
    private var finished = false
    private var sawEnd = false
    private let ended = DispatchSemaphore(value: 0)
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        partial.append(data)
        var complete: [String] = []
        while let newline = partial.firstIndex(of: 0x0A) {
            complete.append(String(decoding: partial[partial.startIndex..<newline], as: UTF8.self))
            partial.removeSubrange(partial.startIndex...newline)
        }
        remember(complete)
        complete.forEach(onLine)                 // under the lock, so lines can't overtake each other or `finish`
    }

    /// The pipe reached its end: everything written to it has been appended.
    func endOfOutput() {
        lock.lock()
        let first = !sawEnd
        sawEnd = true
        lock.unlock()
        if first { ended.signal() }
    }

    func waitForEnd(seconds: Double) { _ = ended.wait(timeout: .now() + seconds) }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        guard !partial.isEmpty else { return }
        let rest = String(decoding: partial, as: UTF8.self)
        partial.removeAll()
        remember([rest])
        onLine(rest)
    }

    var tail: String { lock.lock(); defer { lock.unlock() }; return last.joined(separator: "\n") }

    private func remember(_ lines: [String]) {
        last.append(contentsOf: lines)
        if last.count > 60 { last.removeFirst(last.count - 60) }
    }
}
