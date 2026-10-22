import Foundation
import Testing
@testable import GPlayerCore

/// Real installs into a throwaway space, with the Wine Staging engine from the default library. Off unless
/// `GPLAYER_LIVE=1`: they download from Microsoft and take minutes.
///
///     GPLAYER_LIVE=1 swift test --filter LiveInstallTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GPLAYER_LIVE"] == "1"), .serialized, .timeLimit(.minutes(20)))
struct LiveInstallTests {
    /// What the app does at start: the installed Wine Staging gets G-Player's fixed files, and keeps Gcenx's.
    @Test func theInstalledEngineGetsItsFixes() throws {
        let paths = LibraryPaths(root: LibraryPaths.defaultRoot)
        let engine = try #require(EngineManager(paths: paths).engine(EngineCatalog.wineStaging))
        let outcomes = EngineFixes.apply(to: engine)
        #expect(outcomes.count == EngineFixes.all.count)
        #expect(outcomes.allSatisfy { $0 == .applied || $0 == .alreadyApplied }, "\(outcomes)")
        for fix in EngineFixes.all {
            let file = engine.wineRoot.appendingPathComponent(fix.path)
            #expect(try Files.sha256(of: file) == fix.fixedSHA256, "\(fix.path)")
            #expect(try Files.sha256(of: file.appendingPathExtension("gcenx")) == fix.originalSHA256, "\(fix.path)")
        }
    }

    /// G-Player Wine installs into the default library (from Downloads when its archive is already there), and the
    /// D3DMetal of the installed Game Porting Toolkit goes into it.
    @Test func crossOverEngineInstallsAndTakesD3DMetal() async throws {
        let paths = LibraryPaths(root: LibraryPaths.defaultRoot)
        let manager = EngineManager(paths: paths)
        var installed = manager.engine(EngineCatalog.crossover)
        if installed == nil {
            installed = try await manager.install(EngineCatalog.crossover) { fraction, message in print("live:", Int(fraction * 100), message) }
        }
        let engine = try #require(installed)
        #expect(engine.dxvk != nil && engine.dxmt != nil)
        let source = try #require(D3DMetalStore.toolkitSource)
        let store = D3DMetalStore(paths: paths)
        if store.installed == nil { try await store.importD3DMetal(from: source) }
        try store.link(into: engine)
        #expect(engine.d3dMetalLibrary != nil)
        #expect(engine.readyBackends == [.dxvk, .d3dmetal, .dxmt, .wined3d])     // catalogue order
    }

    /// Steam installs into a throwaway space on G-Player Wine, updates itself and keeps running with its web helpers.
    /// `GPLAYER_LIVE_STEAM_SECONDS` keeps it open that long after start (to look at its window).
    @Test func steamRunsOnGPlayerWine() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gplayer-live-\(UUID().uuidString)", isDirectory: true)
        let paths = LibraryPaths(root: root)
        try paths.createFolders()
        // GPLAYER_LIVE_KEEP=1 keeps the throwaway library (logs, the space) to look at afterwards.
        defer { if ProcessInfo.processInfo.environment["GPLAYER_LIVE_KEEP"] != "1" { try? fm.removeItem(at: root) } else { print("live: kept", root.path) } }
        try fm.removeItem(at: paths.engines)
        try fm.createSymbolicLink(at: paths.engines, withDestinationURL: LibraryPaths(root: LibraryPaths.defaultRoot).engines)
        let engine = try #require(EngineManager(paths: paths).engine(EngineCatalog.crossover))

        let space = try await SpaceManager(paths: paths).create(name: "Steam", engine: engine, colorIndex: 0, presetID: "steam")
        do {
            try await PresetInstaller(paths: paths).install(AppPresets.steam, in: space, engine: engine) { fraction, message in
                print("live:", fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "…", message)
            }
            let steam = Game(title: "Steam", kind: .app, spaceID: space.id,
                             executablePath: Game.storedPath(for: AppPresets.steam.executableURL(in: space), in: space))
            let plan = try LaunchPlanner.plan(for: steam, in: space, ready: engine.readyBackends)
            _ = try ChromiumHelperWrapper.apply(helpers: plan.chromiumHelpers, in: space)
            let program = try WineLauncher.start(engine: engine, space: space, arguments: plan.arguments,
                                                 workingDirectory: plan.workingDirectory, backend: plan.backend,
                                                 tweaks: plan.tweaks, logsFolder: paths.logs, logName: "Steam")
            let seconds = Double(ProcessInfo.processInfo.environment["GPLAYER_LIVE_STEAM_SECONDS"] ?? "") ?? 60
            // What the app's helper guard does while Steam runs (AppModel.guardHelperWrappers): an update at start
            // replaces the web helper, so the wrapper goes back and helpers that started without it are restarted.
            let end = Date().addingTimeInterval(seconds)
            var unwrappedSince: Date?
            while Date() < end {
                let mine = WineProcesses.programs(in: space, from: WineProcesses.snapshot())
                let stale = ChromiumHelperWrapper.unwrappedProcesses(helpers: plan.chromiumHelpers, in: mine)
                if stale.isEmpty { unwrappedSince = nil } else if unwrappedSince == nil { unwrappedSince = Date() }
                _ = try? ChromiumHelperWrapper.apply(helpers: plan.chromiumHelpers, in: space)
                if let since = unwrappedSince, Date().timeIntervalSince(since) > 15 {
                    print("live: restarting \(stale.count) helpers that started without the wrapper")
                    stale.forEach { kill($0.pid, SIGKILL) }
                    unwrappedSince = nil
                }
                try await Task.sleep(for: .seconds(1.5))
            }
            // Steam restarts itself after an update, so the program G-Player started may be gone while Steam runs on.
            _ = program
            var running = WineProcesses.programs(in: space, from: WineProcesses.snapshot())
            for _ in 0..<10 where !running.contains(where: { $0.programName == "steam.exe" }) {
                try await Task.sleep(for: .seconds(2))
                running = WineProcesses.programs(in: space, from: WineProcesses.snapshot())
            }
            print("live: running", running.compactMap(\.programName).sorted())
            if running.isEmpty {
                for p in WineProcesses.snapshot() where (p.directory ?? "").contains("gplayer-live") || (p.prefix ?? "").contains("gplayer-live") {
                    print("live: seen", p.pid, p.programName ?? p.command, p.directory ?? "-", p.prefix ?? "-")
                }
            }
            #expect(running.contains { $0.programName == "steam.exe" })
            #expect(running.contains { $0.programName?.hasPrefix("steamwebhelper") == true })
        } catch {
            await WineLauncher.killAll(engine: engine, space: space)
            throw error
        }
        await WineLauncher.killAll(engine: engine, space: space)
    }

    @Test func baseComponentsInstallIntoANewSpace() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gplayer-live-\(UUID().uuidString)", isDirectory: true)
        let paths = LibraryPaths(root: root)
        try paths.createFolders()
        defer { try? fm.removeItem(at: root) }
        // Borrow the installed engine instead of downloading it again.
        try fm.removeItem(at: paths.engines)
        try fm.createSymbolicLink(at: paths.engines, withDestinationURL: LibraryPaths(root: LibraryPaths.defaultRoot).engines)
        let engine = try #require(EngineManager(paths: paths).engine(EngineCatalog.wineStaging))

        let space = try await SpaceManager(paths: paths).create(name: "Live", engine: engine, colorIndex: 0)
        let installer = RuntimeInstaller(paths: paths)
        let base = CompatResolver.baseComponents
        #expect(installer.missing(base, in: space) == base)
        do {
            try await installer.install(base, in: space, engine: engine) { fraction, message in
                print("live:", fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "…", message)
            }
        } catch {
            await WineLauncher.killAll(engine: engine, space: space)      // no wineserver left for a deleted prefix
            throw error
        }
        await WineLauncher.killAll(engine: engine, space: space)

        #expect(installer.installed(in: space).isSuperset(of: base))
        #expect(installer.missing(base, in: space).isEmpty)
        #expect(installer.failed(in: space).isEmpty)
        for file in ["windows/system32/vcruntime140.dll", "windows/syswow64/vcruntime140.dll",
                     "windows/system32/msvcp140.dll", "windows/system32/d3dcompiler_47.dll",
                     "windows/syswow64/d3dcompiler_47.dll"] {
            #expect(fm.fileExists(atPath: space.driveC.appendingPathComponent(file).path), "\(file)")
        }
    }
}
