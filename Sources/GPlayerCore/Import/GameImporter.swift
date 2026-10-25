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

    /// What copying or unpacking `source` into a folder takes (`plan`).
    public struct ImportPlan: Sendable, Equatable {
        /// What the work moves, for its progress bar: 0 when that can't be told.
        public let totalBytes: Int64
        /// What it needs free on the disk it writes to: nothing for a move within a disk, or a copy on APFS, which clones.
        public let neededBytes: Int64
        public init(totalBytes: Int64, neededBytes: Int64) { self.totalBytes = totalBytes; self.neededBytes = neededBytes }
        /// Kept free besides the work itself: the Mac needs room to work too.
        public static let reserve: Int64 = 1_000_000_000
    }

    /// Looks at `source` before it is copied, moved or unpacked into `destination`. Reads the whole folder, so not on the
    /// main thread.
    public static func plan(_ source: ImportSource, move: Bool, destination: URL) async -> ImportPlan {
        switch source {
        case .program(let url):
            let size = Files.size(of: url)
            return ImportPlan(totalBytes: size, neededBytes: size)
        case .folder(let url):
            let size = Files.logicalSize(of: url)
            let writesNothing = DiskSpace.sameVolume(url, destination) && (move || DiskSpace.clonesCopies(on: destination))
            return ImportPlan(totalBytes: size, neededBytes: writesNothing ? 0 : size)
        case .archive(let url):
            let packed = Files.size(of: url)
            let listed = await ArchiveExtractor.uncompressedBytes(of: url)
            // Without a listing: archives of games hold about twice what they weigh.
            return ImportPlan(totalBytes: listed ?? 0, neededBytes: max(listed ?? packed * 2, packed))
        }
    }

    /// Why `plan` doesn't fit on the disk that holds `destination`, for the user, or nil when it does.
    public static func spaceProblem(for plan: ImportPlan, destination: URL, title: String) -> String? {
        guard plan.neededBytes > 0 else { return nil }
        return DiskSpace.problem(needing: plan.neededBytes + ImportPlan.reserve, available: DiskSpace.available(at: destination),
                                 for: String(localized: "Adding “\(title)”"))
    }

    /// Copies a portable game into `space` (C:\Games\<title>) and returns its folder. `progress` gets the bytes done and
    /// `totalBytes` (from `plan`). Cancelling the calling task stops it and removes what was copied; `CancellationError`
    /// is thrown. A move within a disk is a rename and can't be stopped; a move to another disk copies first, then removes
    /// the original, so stopping it loses nothing.
    public static func copyIntoSpace(_ source: ImportSource, space: Space, title: String, move: Bool = false,
                                     totalBytes: Int64 = 0,
                                     progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> URL {
        let games = space.driveC.appendingPathComponent("Games", isDirectory: true)
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        switch source {
        case .archive(let url):
            return try await ArchiveExtractor.extract(url, into: games, name: title, expectedBytes: totalBytes, progress: progress)
        case .folder(let url):
            let target = Files.uniqueURL(in: games, name: Files.safeName(title))
            if move && DiskSpace.sameVolume(url, games) {
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
            do {
                try copyFolder(from: url, to: target, totalBytes: totalBytes, progress: progress)
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            if move { try FileManager.default.removeItem(at: url) }
            return target
        case .program(let url):
            let target = Files.uniqueURL(in: games, name: Files.safeName(title))
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target.appendingPathComponent(url.lastPathComponent))
            return target
        }
    }

    /// Copies a folder file by file (a clone on APFS), so there is progress and the calling task can stop it between files.
    private static func copyFolder(from source: URL, to target: URL, totalBytes: Int64,
                                   progress: @Sendable (Int64, Int64) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        // Walks by path inside the folder: the URLs of a walk of a folder under /var come out as /private/var, which a
        // link's path then doesn't match (and the link would be skipped).
        guard let walker = fm.enumerator(atPath: source.path) else { throw ShellError.failed(String(localized: "Couldn't read \(source.lastPathComponent).")) }
        var done: Int64 = 0
        var reported = Date.distantPast
        for case let inside as String in walker {
            try Task.checkCancellation()
            let item = source.appendingPathComponent(inside), destination = target.appendingPathComponent(inside)
            let attributes = try fm.attributesOfItem(atPath: item.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try fm.copyItem(at: item, to: destination)                  // a link is copied as a link
            done += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if Date().timeIntervalSince(reported) >= 0.1 { reported = Date(); progress(done, totalBytes) }
        }
        progress(done, totalBytes)
    }

    /// Finds the installer to run: unpacks archives into `workFolder` first (`progress` and `totalBytes` as in `copyIntoSpace`).
    public static func installer(for source: ImportSource, workFolder: URL, title: String, totalBytes: Int64 = 0,
                                 progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> URL {
        switch source {
        case .program(let url):
            return url
        case .folder(let url):
            if let setup = ExecutableScanner.looksLikeInstaller(url) { return setup }
            if let any = ExecutableScanner.scan(url, maxDepth: 2).first(where: { ExecutableScanner.isInstallerName($0.name) }) {
                return any.url
            }
            throw ShellError.failed(String(localized: "No installer (setup.exe, install.exe or .msi) found in \(url.lastPathComponent)."))
        case .archive(let url):
            let folder = try await ArchiveExtractor.extract(url, into: workFolder, name: title, expectedBytes: totalBytes, progress: progress)
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
            throw ShellError.failed(String(localized: "The installer stopped (code \(status)) without installing a program."))
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
