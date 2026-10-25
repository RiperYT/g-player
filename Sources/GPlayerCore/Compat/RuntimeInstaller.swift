import Foundation

/// Installs Windows components (Visual C++, d3dcompiler, DirectX, .NET…) into a space.
///
/// The base set (`vcrun2022`, `d3dcompiler_47`) is installed here, from pinned downloads, the way winetricks 20260125
/// does it. Every other id goes to `Winetricks`. Downloads land in `Downloads/components/` and stay there for the
/// next space; each file is checked against its SHA-256 every time it is used, and nothing unverified is installed.
/// What was installed, and what failed and when, is written to `.gplayer-components.json` in the space.
public struct RuntimeInstaller: Sendable {
    public let paths: LibraryPaths

    /// Stands in for the real install of one component. Only tests set it.
    typealias InstallOne = @Sendable (_ id: String, _ space: Space, _ engine: Engine, _ timeout: TimeInterval,
                                      _ progress: @escaping @Sendable (Double?, String) -> Void) async throws -> Void
    let installOne: InstallOne?

    public init(paths: LibraryPaths) { self.paths = paths; self.installOne = nil }

    init(paths: LibraryPaths, installOne: @escaping InstallOne) { self.paths = paths; self.installOne = installOne }

    /// How long one installer run or one winetricks verb may take before it is stopped.
    public static let defaultTimeout: TimeInterval = 15 * 60
    /// How long to wait for programs an installer left running, after the installer itself has exited.
    static let settleTimeout: TimeInterval = 120
    /// A component that failed isn't tried again by `missing` for this long.
    static let retryAfter: TimeInterval = 3 * 24 * 60 * 60

    /// Shared download cache.
    var cache: URL { paths.downloads.appendingPathComponent("components", isDirectory: true) }

    // MARK: State

    static let stateFileName = ".gplayer-components.json"

    private struct State: Codable {
        /// Component id → ISO 8601 date it was installed.
        var installed: [String: String] = [:]
        /// Component id → ISO 8601 date of its last failed install.
        var failed: [String: String] = [:]

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            installed = c.value(.installed, default: [:])
            failed = c.value(.failed, default: [:])
        }
    }

    private static func stateURL(_ space: Space) -> URL { space.url.appendingPathComponent(stateFileName) }

    private static func readState(_ space: Space) -> State {
        guard let data = try? Data(contentsOf: stateURL(space)) else { return State() }
        return (try? JSONDecoder().decode(State.self, from: data)) ?? State()
    }

    private static func write(_ state: State, to space: Space) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL(space), options: .atomic)
    }

    /// Records an install. A recorded failure of the same component is forgotten.
    func record(_ id: String, in space: Space, at date: Date = Date()) throws {
        var state = Self.readState(space)
        state.installed[id] = ISO8601DateFormatter().string(from: date)
        state.failed[id] = nil
        try Self.write(state, to: space)
    }

    /// Records a failed install, so it isn't tried again on every launch.
    func recordFailure(_ id: String, in space: Space, at date: Date = Date()) throws {
        var state = Self.readState(space)
        state.failed[id] = ISO8601DateFormatter().string(from: date)
        try Self.write(state, to: space)
    }

    /// Ids G-Player recorded as installed in the space (not the files-based detection of `installed(in:)`).
    static func recorded(in space: Space) -> Set<String> { Set(readState(space).installed.keys) }

    /// Components installed in the space: the ones G-Player recorded, plus base components whose files are
    /// there and native, so spaces made elsewhere (a CrossOver bottle) count too.
    public func installed(in space: Space) -> Set<String> {
        var ids = Self.recorded(in: space)
        for (id, spec) in RuntimeCatalog.native where Self.hasNativeFiles(spec, in: space) { ids.insert(id) }
        return ids
    }

    /// Components whose last install failed, with the date it failed.
    public func failed(in space: Space) -> [String: Date] {
        let formatter = ISO8601DateFormatter()
        return Self.readState(space).failed.compactMapValues { formatter.date(from: $0) }
    }

    /// The ids that aren't installed yet, in the order given, each once. Ids that stand in for a newer one (`vcrun2019`)
    /// are given as that one. An id that failed to install within the last three days is left out, so a component that
    /// can't be installed doesn't make every launch wait; `retryFailed` brings it back (for a user who asks again).
    public func missing(_ ids: [String], in space: Space, retryFailed: Bool = false) -> [String] {
        missing(ids, in: space, retryFailed: retryFailed, now: Date())
    }

    func missing(_ ids: [String], in space: Space, retryFailed: Bool, now: Date) -> [String] {
        let have = installed(in: space)
        let recentFailures: Set<String> = retryFailed ? [] : Set(failed(in: space).filter { now.timeIntervalSince($0.value) < Self.retryAfter }.keys)
        var seen = Set<String>()
        return ids.map(RuntimeCatalog.canonicalID).filter {
            !have.contains($0) && !recentFailures.contains($0) && seen.insert($0).inserted
        }
    }

    // MARK: Install

    /// Installs what's missing, base components first, then the rest in catalog order. Records each success. A component
    /// that fails doesn't stop the others: its failure is recorded with the date, the rest are installed, and at the end
    /// one error names every component that failed. Throws before installing anything when an id isn't a component
    /// G-Player can install (`RuntimeCatalog.isInstallable`).
    ///
    /// Every installer run and every winetricks verb is stopped after `timeout` seconds and counts as a failure. When
    /// the calling task is cancelled, the running installer is stopped (the space's Wine server is not), nothing is
    /// recorded for the unfinished component, and `CancellationError` is thrown.
    /// `progress` gets a fraction of the whole job (nil while unknown) and a short message.
    public func install(_ ids: [String], in space: Space, engine: Engine, timeout: TimeInterval = RuntimeInstaller.defaultTimeout,
                        progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        let wanted = ids.map(RuntimeCatalog.canonicalID)
        for id in wanted where !RuntimeCatalog.isInstallable(id) {
            throw ShellError.failed(String(localized: "\(RuntimeCatalog.plainName(id)) isn't a component G-Player can install."))
        }
        let todo = missing(Self.installOrder(wanted), in: space, retryFailed: true)
        guard !todo.isEmpty else { return }
        guard space.exists else { throw ShellError.failed(String(localized: "\(space.name) isn't ready: Wine hasn't created its Windows folder yet.")) }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        var failures: [(name: String, reason: String)] = []
        for (index, id) in todo.enumerated() {
            try Task.checkCancellation()
            let name = RuntimeCatalog.component(id)?.name ?? id
            let base = Double(index) / Double(todo.count), share = 1 / Double(todo.count)
            let report: @Sendable (Double?, String) -> Void = { fraction, text in
                progress(fraction.map { base + $0 * share }, text)
            }
            report(0, String(localized: "Installing \(name)"))
            do {
                if let installOne {
                    try await installOne(id, space, engine, timeout, report)
                } else if let native = RuntimeCatalog.native[id] {
                    try await installNative(native, space: space, engine: engine, timeout: timeout, progress: report)
                } else {
                    try await Winetricks(paths: paths).install(id, in: space, engine: engine, timeout: timeout, progress: report)
                }
                try Task.checkCancellation()
                try record(id, in: space)
                report(1, String(localized: "Installed \(name)"))
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                try? recordFailure(id, in: space)
                failures.append((name, error.localizedDescription))
                report(1, String(localized: "Couldn't install \(name)"))
            }
        }
        if !failures.isEmpty { throw ShellError.failed(Self.failureMessage(failures)) }
    }

    /// "Couldn't install A. reason" for one failure; the names, then each reason, for several.
    static func failureMessage(_ failures: [(name: String, reason: String)]) -> String {
        if failures.count == 1 { return String(localized: "Couldn't install \(failures[0].name). \(failures[0].reason)") }
        let names = failures.map(\.name)
        return String(localized: "Couldn't install \(CompatResolver.list(names)).") + " "
            + failures.map { "\($0.name): \($0.reason)" }.joined(separator: " ")
    }

    /// Base components first, then catalog order, then unknown ids as given. Each id once.
    static func installOrder(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        let rank = { (id: String) in RuntimeCatalog.all.firstIndex { $0.id == id } ?? RuntimeCatalog.all.count }
        return unique.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    // MARK: Native install

    /// Exit codes a Microsoft setup program uses for "done": winetricks accepts 0, 105, 194 and 236;
    /// 1638 (a newer version is already there) and 3010 (restart wanted) are fine in a space too.
    static let acceptedSetupStatus: Set<Int32> = [0, 105, 194, 236, 1638, 3010]

    private func installNative(_ spec: RuntimeCatalog.NativeRuntime, space: Space, engine: Engine, timeout: TimeInterval,
                               progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        let win64 = Self.is64Bit(space)
        let copies = spec.copies.filter { win64 || $0.arch == .x86 }
        let setups = spec.setups.filter { win64 || $0.arch == .x86 }

        // Download and verify everything before touching the space.
        let files = copies.map(\.file) + setups.map(\.file)
        var local: [String: URL] = [:]
        for (index, file) in files.enumerated() {
            let done = Double(index), count = Double(files.count)
            local[file.fileName] = try await Self.fetch(file, into: cache) { fraction in
                progress((done + fraction) / count * 0.5, String(localized: "Downloading \(file.fileName)"))
            }
        }

        for copy in copies {
            try Task.checkCancellation()
            try Self.put(local[copy.file.fileName]!, as: copy.name, in: Self.systemFolder(copy.arch, of: space))
        }
        for setup in setups {
            guard let replacement = setup.replaces else { continue }
            try Task.checkCancellation()
            progress(0.52, String(localized: "Unpacking \(setup.file.fileName)"))
            try await replaceBuiltins(replacement, from: local[setup.file.fileName]!, into: Self.systemFolder(setup.arch, of: space))
        }

        progress(0.55, String(localized: "Setting DLL overrides"))
        try await writeOverrides(spec, space: space, engine: engine)

        for (index, setup) in setups.enumerated() {
            try Task.checkCancellation()
            progress(0.6 + 0.35 * Double(index) / Double(setups.count), String(localized: "Running \(setup.file.fileName)"))
            let log = LogBox()
            let status = try await WineLauncher.runAndWait(
                engine: engine, space: space,
                arguments: [local[setup.file.fileName]!.path] + setup.arguments,
                workingDirectory: cache, backend: .wined3d, logsFolder: paths.logs,
                logName: "Install \(spec.id) \(setup.arch == .x64 ? "64-bit" : "32-bit")", timeout: timeout,
                started: { log.file = $0.logFile })
            // Setup programs hand off to child processes; give them a little time, but never wait for ever.
            await WineLauncher.waitForAll(engine: engine, space: space, timeout: Self.settleTimeout)
            try Task.checkCancellation()
            guard Self.acceptedSetupStatus.contains(status) else {
                throw ShellError.failed(String(localized: "\(setup.file.fileName) stopped with code \(status). Details: \(log.file?.lastPathComponent ?? String(localized: "the Logs folder"))"))
            }
        }

        guard Self.hasNativeFiles(spec, in: space) else {
            throw ShellError.failed(String(localized: "The installer finished, but Wine still uses its own copies of the files."))
        }
    }

    /// Takes `replacement.names` out of the setup program's cabinet and puts them into `folder`, over Wine's own copies.
    private func replaceBuiltins(_ replacement: RuntimeCatalog.NativeRuntime.Replacement, from setup: URL, into folder: URL) async throws {
        guard let shims = CoreResources.url("shims") else {
            throw ShellError.failed(String(localized: "G-Player's helper scripts are missing. Reinstall G-Player."))
        }
        let cabextract = shims.appendingPathComponent("cabextract")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("gplayer-unpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // The setup program carries a cabinet, and that cabinet carries the DLLs.
        let outer = try await Shell.run(cabextract, ["-q", "-d", work.path, setup.path, "-F", replacement.container])
        let container = work.appendingPathComponent(replacement.container)
        guard outer.succeeded, FileManager.default.fileExists(atPath: container.path) else {
            throw ShellError.failed(String(localized: "Couldn't open \(setup.lastPathComponent). \(outer.stderr.suffix(200))"))
        }
        for name in replacement.names {
            let inner = work.appendingPathComponent("dll", isDirectory: true)
            let unpacked = try await Shell.run(cabextract, ["-q", "-d", inner.path, container.path, "-F", name + replacement.suffix])
            let file = inner.appendingPathComponent(name + replacement.suffix)
            guard unpacked.succeeded, FileManager.default.fileExists(atPath: file.path) else {
                throw ShellError.failed(String(localized: "\(name) isn't in \(setup.lastPathComponent). \(unpacked.stderr.suffix(200))"))
            }
            try Self.put(file, as: name, in: folder)
        }
    }

    /// Writes the DLL overrides into the space's registry: one `.reg` file imported with `wine regedit /S`.
    private func writeOverrides(_ spec: RuntimeCatalog.NativeRuntime, space: Space, engine: Engine) async throws {
        let folder = space.driveC.appendingPathComponent("windows/temp", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "gplayer-\(spec.id).reg"
        let file = folder.appendingPathComponent(name)
        try Self.overridesRegFile(spec.overrides).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await WineLauncher.runTool(engine: engine, space: space, ["regedit", "/S", "C:\\windows\\temp\\" + name])
        guard result.succeeded else {
            throw ShellError.failed(String(localized: "Wine couldn't write the DLL overrides. \(result.stderr.suffix(300))"))
        }
    }

    // MARK: Download

    /// The file from `folder`, downloading it first when it isn't there. The file is checked against its SHA-256
    /// every time. A download that doesn't match is deleted, never used.
    static func fetch(_ item: PinnedDownload, into folder: URL,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(item.fileName)
        if fm.fileExists(atPath: file.path) {
            if (try? Files.sha256(of: file)) == item.sha256 { return file }
            try? fm.removeItem(at: file)
        }
        // Its own name while it downloads, so two installs sharing the cache never write the same file. The downloader keeps
        // the bytes in `<name>.part` meanwhile; `Leftovers` knows both names, for what a quit or a crash leaves.
        let part = folder.appendingPathComponent("\(item.fileName).\(UUID().uuidString.prefix(8))")
        try await FileDownloader.download(item.url, to: part, progress: progress)
        guard try Files.sha256(of: part) == item.sha256 else {
            try? fm.removeItem(at: part)
            throw ShellError.failed(String(localized: "\(item.fileName) doesn't match its checksum. The publisher may have replaced the file, so G-Player didn't use it. Nothing was installed from it."))
        }
        try? fm.removeItem(at: file)
        try fm.moveItem(at: part, to: file)
        return file
    }

    // MARK: Files and registry (pure)

    /// The `.reg` text for DLL overrides, in Wine's `HKCU\Software\Wine\DllOverrides`. The star makes the setting
    /// apply to DLLs loaded by full path too.
    static func overridesRegFile(_ overrides: [(dll: String, mode: DLLOverrideMode)]) -> String {
        var text = "REGEDIT4\n\n[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n"
        for item in overrides { text += "\"*\(item.dll)\"=\"\(item.mode.registryValue)\"\n" }
        return text
    }

    /// True when the file is a real Windows DLL: not missing, not a symlink, not Wine's own build
    /// ("Wine builtin DLL") or placeholder ("Wine placeholder DLL"), which both carry their marker in the header.
    static func isNativeDLL(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isSymbolicLink != true, values.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.starts(with: [0x4D, 0x5A]) else { return false }
        return head.range(of: Data("Wine builtin DLL".utf8)) == nil && head.range(of: Data("Wine placeholder DLL".utf8)) == nil
    }

    /// Where a DLL of this bitness goes: `system32` holds the 64-bit DLLs of a 64-bit space, `syswow64` its 32-bit ones.
    static func systemFolder(_ arch: RuntimeCatalog.NativeRuntime.Arch, of space: Space) -> URL {
        space.driveC.appendingPathComponent(is64Bit(space) && arch == .x86 ? "windows/syswow64" : "windows/system32")
    }

    /// Copies `file` to `folder/name`, replacing whatever is there (Wine's own copy, or a link to it).
    static func put(_ file: URL, as name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: file, to: target)
    }

    /// 64-bit spaces have `syswow64` for the 32-bit DLLs.
    static func is64Bit(_ space: Space) -> Bool {
        Files.isDirectory(space.driveC.appendingPathComponent("windows/syswow64"))
    }

    static func hasNativeFiles(_ spec: RuntimeCatalog.NativeRuntime, in space: Space) -> Bool {
        let windows = space.driveC.appendingPathComponent("windows")
        let win64 = is64Bit(space)
        // system32 holds 64-bit DLLs in a 64-bit space and 32-bit ones otherwise; syswow64 the 32-bit ones.
        var wanted = spec.expected.map { "system32/\($0)" } + (win64 ? spec.expected64Only.map { "system32/\($0)" } : [])
        if win64 { wanted += spec.expected.map { "syswow64/\($0)" } }
        return wanted.allSatisfy { isNativeDLL(at: windows.appendingPathComponent($0)) }
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    var file: URL? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
