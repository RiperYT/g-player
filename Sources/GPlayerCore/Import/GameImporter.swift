import Foundation

/// What the user dropped or picked.
public enum ImportSource: Sendable, Hashable {
    case folder(URL)
    case archive(URL)
    /// A single .exe or .msi: usually an installer.
    case program(URL)

    public init?(_ url: URL) {
        if Files.isDirectory(url) { self = .folder(url) }
        else if ArchiveExtractor.isArchive(url) { self = .archive(url) }
        else if ["exe", "msi"].contains(url.pathExtension.lowercased()) { self = .program(url) }
        else { return nil }
    }

    public var url: URL {
        switch self { case .folder(let u), .archive(let u), .program(let u): u }
    }

    /// "Hollow_Knight_1.5.rar" → "Hollow Knight 1.5".
    public var suggestedTitle: String {
        var name = url.lastPathComponent
        if !Files.isDirectory(url) {
            name = url.deletingPathExtension().lastPathComponent
            if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
        }
        for junk in ["setup_", "setup-", "_setup", "-setup", "installer"] {
            if let r = name.range(of: junk, options: .caseInsensitive) { name.removeSubrange(r) }
        }
        let cleaned = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "New Game" : cleaned
    }
}

public enum ImportMode: String, Sendable, CaseIterable, Identifiable {
    /// Copy the game into the space and start its .exe directly.
    case portable
    /// Run its installer inside the space, then pick what it installed.
    case installer
    public var id: String { rawValue }
}

public enum GameImporter {
    /// The likely mode and installer for a source, checked before the user confirms.
    public static func guess(_ source: ImportSource) async -> (ImportMode, URL?) {
        switch source {
        case .program(let url):
            return (.installer, url)
        case .folder(let url):
            if let setup = ExecutableScanner.looksLikeInstaller(url) { return (.installer, setup) }
            return (.portable, nil)
        case .archive(let url):
            // Look inside without unpacking: an archive with a setup and no other programs is an installer.
            let listing = (try? await Shell.run(Shell.tool("bsdtar"), ["-tf", url.path]))?.stdout ?? ""
            let exes = listing.split(separator: "\n").map(String.init).filter { $0.lowercased().hasSuffix(".exe") }
            let names = exes.map { ($0 as NSString).lastPathComponent }
            let setups = names.filter(ExecutableScanner.isInstallerName)
            let others = names.filter { !ExecutableScanner.isInstallerName($0) && !ExecutableScanner.isHelper($0) }
            return (!setups.isEmpty && others.count <= 1) ? (.installer, nil) : (.portable, nil)
        }
    }

    /// Copies a portable game into `space` (C:\Games\<title>) and returns its folder.
    public static func copyIntoSpace(_ source: ImportSource, space: Space, title: String, move: Bool = false) async throws -> URL {
        let games = space.driveC.appendingPathComponent("Games", isDirectory: true)
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        switch source {
        case .archive(let url):
            return try await ArchiveExtractor.extract(url, into: games, name: title)
        case .folder(let url):
            let target = Files.uniqueURL(in: games, name: Files.safeName(title))
            try await Task.detached(priority: .userInitiated) {
                if move { try FileManager.default.moveItem(at: url, to: target) }
                else { try FileManager.default.copyItem(at: url, to: target) }
            }.value
            return target
        case .program(let url):
            let target = Files.uniqueURL(in: games, name: Files.safeName(title))
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target.appendingPathComponent(url.lastPathComponent))
            return target
        }
    }

    /// Finds the installer to run: unpacks archives into `workFolder` first.
    public static func installer(for source: ImportSource, workFolder: URL, title: String) async throws -> URL {
        switch source {
        case .program(let url):
            return url
        case .folder(let url):
            if let setup = ExecutableScanner.looksLikeInstaller(url) { return setup }
            if let any = ExecutableScanner.scan(url, maxDepth: 2).first(where: { ExecutableScanner.isInstallerName($0.name) }) {
                return any.url
            }
            throw ShellError.failed("No installer (setup.exe, install.exe or .msi) found in \(url.lastPathComponent).")
        case .archive(let url):
            let folder = try await ArchiveExtractor.extract(url, into: workFolder, name: title)
            return try await installer(for: .folder(folder), workFolder: workFolder, title: title)
        }
    }

    /// Runs an installer inside the space and returns the programs it added, best guess first.
    public static func runInstaller(_ installer: URL, space: Space, engine: Engine, logs: URL,
                                    started: @escaping @Sendable (RunningProgram) -> Void = { _ in }) async throws -> [ExecutableCandidate] {
        let before = ProgramSnapshot.take(of: space)
        let status = try await WineLauncher.runAndWait(engine: engine, space: space,
                                                       arguments: WineLauncher.arguments(toOpen: installer),
                                                       workingDirectory: installer.deletingLastPathComponent(),
                                                       logsFolder: logs, logName: "Install \(installer.lastPathComponent)",
                                                       started: started)
        await WineLauncher.waitForAll(engine: engine, space: space)
        let found = ProgramSnapshot.newPrograms(in: space, since: before)
        if found.isEmpty, status != 0 {
            throw ShellError.failed("The installer stopped (code \(status)) without installing a program.")
        }
        return found
    }
}

extension WineLauncher {
    /// Starts a program and waits for its Wine process to exit. With a `timeout` (seconds) the program is stopped
    /// when it runs longer and `Supervised.TimedOut` is thrown. When the calling task is cancelled the program is
    /// stopped too, and `CancellationError` is thrown; the rest of the space is left running.
    public static func runAndWait(engine: Engine, space: Space, arguments: [String], workingDirectory: URL?,
                                  backend: GraphicsBackend = .auto, tweaks: LaunchTweaks = LaunchTweaks(),
                                  logsFolder: URL, logName: String, timeout: TimeInterval? = nil,
                                  started: @escaping @Sendable (RunningProgram) -> Void = { _ in }) async throws -> Int32 {
        let running = ProgramBox()
        return try await Supervised.run(timeout: timeout, stop: { running.stop() }) { finish in
            let program = try start(engine: engine, space: space, arguments: arguments,
                                    workingDirectory: workingDirectory, backend: backend, tweaks: tweaks,
                                    logsFolder: logsFolder, logName: logName, onExit: finish)
            running.program = program
            started(program)
        }
    }
}

/// Holds the program a supervised run started, so that stopping it can find it.
private final class ProgramBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RunningProgram?
    var program: RunningProgram? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func stop() { if let process = program?.process { Supervised.terminate(process) } }
}
