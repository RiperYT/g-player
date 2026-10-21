import AppKit
import Foundation
import GPlayerCore
import Observation

enum SidebarItem: Hashable {
    case allGames, recent, space(UUID), files, apps
}

/// Long work shown at the bottom of the sidebar (engine downloads, store setup, imports).
struct Activity: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var progress: Double?
}

@MainActor @Observable
final class AppModel {
    // MARK: Settings (stored in UserDefaults)
    var libraryRoot: URL? {
        didSet { UserDefaults.standard.set(libraryRoot?.path, forKey: "libraryRoot") }
    }
    var onboardingDone: Bool {
        didSet { UserDefaults.standard.set(onboardingDone, forKey: "onboardingDone") }
    }
    var verboseLogs: Bool {
        didSet { UserDefaults.standard.set(verboseLogs, forKey: "verboseLogs") }
    }

    // MARK: State
    private(set) var state = LibraryState()
    var selection: SidebarItem? = .allGames
    var selectedGameID: UUID?
    var searchText = ""
    var activities: [Activity] = []
    var errorMessage: String?
    var addGameSource: ImportSource?
    var showAddGame = false
    var showNewSpace = false
    /// The space the Files browser shows.
    var filesSpaceID: UUID?
    private(set) var running: [UUID: RunningProgram] = [:]
    private(set) var engineVersion = 0           // bumps when engines change, so views re-read them

    init() {
        let d = UserDefaults.standard
        libraryRoot = d.string(forKey: "libraryRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
        onboardingDone = d.bool(forKey: "onboardingDone")
        verboseLogs = d.bool(forKey: "verboseLogs")
        if libraryRoot != nil { load() }
        NotificationCenter.default.addObserver(forName: .gplayerOpenFile, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.onboardingDone, let url = note.object as? URL, let source = ImportSource(url) else { return }
                self.addGameSource = source
                self.showAddGame = true
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStores() }
        }
    }

    var paths: LibraryPaths? { libraryRoot.map(LibraryPaths.init) }
    var spaces: [Space] { state.spaces }
    var games: [Game] { state.games }
    func space(_ id: UUID?) -> Space? { id.flatMap { state.space($0) } }
    func game(_ id: UUID?) -> Game? { id.flatMap { gid in state.games.first { $0.id == gid } } }

    // MARK: Persistence

    func load() {
        guard let paths else { return }
        do {
            try paths.createFolders()
            state = try LibraryStore(paths: paths).load()
        } catch {
            errorMessage = "Couldn't read the library: \(error.localizedDescription)"
        }
        refreshStores()
    }

    private func save() {
        guard let paths else { return }
        do { try LibraryStore(paths: paths).save(state) }
        catch { errorMessage = "Couldn't save the library: \(error.localizedDescription)" }
    }

    func mutate(_ change: (inout LibraryState) -> Void) {
        change(&state)
        save()
    }

    func update(_ game: Game) { mutate { s in if let i = s.games.firstIndex(where: { $0.id == game.id }) { s.games[i] = game } } }
    func update(_ space: Space) { mutate { s in if let i = s.spaces.firstIndex(where: { $0.id == space.id }) { s.spaces[i] = space } } }

    // MARK: Engines

    var engineManager: EngineManager? { paths.map(EngineManager.init) }

    func engine(for space: Space) -> Engine? {
        _ = engineVersion
        return engineManager?.engine(id: space.engineID)
    }

    func isInstalled(_ info: EngineInfo) -> Bool {
        _ = engineVersion
        return engineManager?.isInstalled(info) ?? false
    }

    var isEngineBusy: Bool { activities.contains { $0.title.hasPrefix("Downloading Wine") } }

    /// Downloads an engine if it is missing. Returns nil when that failed (the error is shown).
    @discardableResult
    func ensureEngine(_ info: EngineInfo) async -> Engine? {
        guard let manager = engineManager else { return nil }
        if let e = manager.engine(info) { return e }
        if info.downloads.isEmpty {
            errorMessage = "\(info.name) isn't installed. In Terminal, run:\n\(EngineCatalog.gptkHomebrewCommand)"
            return nil
        }
        let activity = begin("Downloading Wine \(info.version)", "Starting")
        defer { end(activity) }
        do {
            let engine = try await manager.install(info) { [weak self] fraction, message in
                Task { @MainActor in self?.progress(activity, fraction, message) }
            }
            engineVersion += 1
            return engine
        } catch {
            errorMessage = "Couldn't install \(info.name): \(error.localizedDescription)"
            return nil
        }
    }

    func removeEngine(_ info: EngineInfo) {
        do { try engineManager?.remove(info); engineVersion += 1 }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: Activities

    func begin(_ title: String, _ message: String, progress: Double? = nil) -> UUID {
        let a = Activity(title: title, message: message, progress: progress)
        activities.append(a)
        return a.id
    }

    func progress(_ id: UUID, _ fraction: Double?, _ message: String) {
        guard let i = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[i].progress = fraction
        activities[i].message = message
    }

    func end(_ id: UUID) { activities.removeAll { $0.id == id } }

    // MARK: Spaces

    func nextColor() -> Int { SpaceColor.next(after: state.spaces.map(\.colorIndex)) }

    /// Creates a space (downloading the engine first if needed).
    func createSpace(name: String, engineInfo: EngineInfo = EngineCatalog.wineStaging, presetID: String? = nil) async -> Space? {
        guard let paths, let engine = await ensureEngine(engineInfo) else { return nil }
        let activity = begin("Creating “\(name)”", "Setting up Windows. This takes about a minute the first time.")
        defer { end(activity) }
        do {
            let space = try await SpaceManager(paths: paths).create(name: name, engine: engine,
                                                                     colorIndex: nextColor(), presetID: presetID)
            mutate { $0.spaces.append(space) }
            return space
        } catch {
            errorMessage = "Couldn't create the space: \(error.localizedDescription)"
            return nil
        }
    }

    /// Uses an environment found on the Mac (CrossOver bottle, older prefix) in place, with its games.
    func adopt(_ found: FoundEnvironment) {
        let space = Space(name: found.name, path: found.url.path, engineID: found.suggestedEngineID, origin: .external,
                          originNote: found.originNote, presetID: found.presetID, colorIndex: nextColor())
        mutate { s in
            s.spaces.append(space)
            for g in found.games {
                s.games.append(Game(title: g.title, spaceID: space.id, executablePath: Game.storedPath(for: g.executable, in: space),
                                    arguments: g.arguments))
            }
        }
        ensureLauncherEntry(for: space)
        refreshStores()
    }

    func removeSpace(_ space: Space, deleteFiles: Bool) {
        if deleteFiles, let paths {
            do { try SpaceManager(paths: paths).delete(space) }
            catch { errorMessage = "Couldn't delete the space: \(error.localizedDescription)"; return }
        }
        mutate { s in
            s.games.removeAll { $0.spaceID == space.id }
            s.spaces.removeAll { $0.id == space.id }
        }
        if selection == .space(space.id) { selection = .allGames }
    }

    func stopAll(in space: Space) {
        guard let engine = engine(for: space) else { return }
        Task {
            await WineLauncher.killAll(engine: engine, space: space)
            await MainActor.run { for g in state.games(in: space) { running[g.id] = nil } }
        }
    }

    // MARK: Presets (Steam, Epic…)

    func presetSpace(_ preset: AppPreset) -> Space? { state.spaces.first { $0.presetID == preset.id } }

    func isInstalled(_ preset: AppPreset) -> Bool { presetSpace(preset).map(preset.isInstalled) ?? false }

    func installPreset(_ preset: AppPreset) async {
        guard let paths else { return }
        var space = presetSpace(preset)
        if space == nil { space = await createSpace(name: preset.name, presetID: preset.id) }
        guard let space, let engine = engine(for: space) else { return }
        let activity = begin("Setting up \(preset.name)", "Starting")
        defer { end(activity) }
        do {
            try await PresetInstaller(paths: paths).install(preset, in: space, engine: engine) { [weak self] f, m in
                Task { @MainActor in self?.progress(activity, f, m) }
            }
            ensureLauncherEntry(for: space)
            refreshStores()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A library tile for the store launcher itself (Steam, Epic…).
    func ensureLauncherEntry(for space: Space) {
        guard let preset = AppPresets.preset(space.presetID), preset.isInstalled(in: space) else { return }
        let path = Game.storedPath(for: preset.executableURL(in: space), in: space)
        guard !state.games.contains(where: { $0.spaceID == space.id && $0.executablePath == path }) else { return }
        mutate { $0.games.append(Game(title: preset.name, kind: .app, spaceID: space.id, executablePath: path)) }
    }

    // MARK: Store discovery

    /// Adds games that Steam or Epic installed and drops ones that were uninstalled.
    func refreshStores() {
        guard paths != nil else { return }
        var changed = false
        var next = state
        for space in state.spaces where space.exists {
            if let preset = AppPresets.preset(space.presetID), preset.isInstalled(in: space) {
                let path = Game.storedPath(for: preset.executableURL(in: space), in: space)
                if !next.games.contains(where: { $0.spaceID == space.id && $0.kind == .app }) {
                    next.games.append(Game(title: preset.name, kind: .app, spaceID: space.id, executablePath: path))
                    changed = true
                }
            }
            var found: [StoreGame] = []
            if AppPresets.steam.isInstalled(in: space) { found += SteamLibrary.scan(space).filter(\.installed) }
            if AppPresets.epic.isInstalled(in: space) { found += EpicLibrary.scan(space).filter(\.installed) }
            let keys = Set(found.map { key(for: $0.source) })
            for g in found {
                let k = key(for: g.source)
                guard !next.hiddenStoreKeys.contains(k), !next.games.contains(where: { $0.storeKey == k && $0.spaceID == space.id }) else { continue }
                next.games.append(Game(title: g.title, spaceID: space.id, source: g.source))
                changed = true
            }
            let before = next.games.count
            next.games.removeAll { $0.spaceID == space.id && $0.storeKey != nil && !keys.contains($0.storeKey!) }
            changed = changed || next.games.count != before
        }
        if changed { state = next; save() }
        fetchMissingCovers()
    }

    private func key(for source: Game.Source) -> String {
        Game(title: "", spaceID: UUID(), source: source).storeKey ?? ""
    }

    // MARK: Covers

    func coverImage(for game: Game) -> NSImage? {
        guard let paths, let file = game.coverFile else { return nil }
        return NSImage(contentsOf: paths.covers.appendingPathComponent(file))
    }

    func setCover(_ image: URL, for game: Game) {
        guard let paths else { return }
        let name = "\(game.id.uuidString).\(image.pathExtension.isEmpty ? "png" : image.pathExtension.lowercased())"
        let target = paths.covers.appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: image, to: target)
            var g = game; g.coverFile = name; update(g)
        } catch { errorMessage = "Couldn't use that image: \(error.localizedDescription)" }
    }

    func clearCover(for game: Game) { var g = game; g.coverFile = nil; update(g) }

    private var coverFetches = Set<UUID>()

    private func fetchMissingCovers() {
        guard let paths else { return }
        for game in state.games where game.coverFile == nil && !coverFetches.contains(game.id) {
            guard case .steam(let appID) = game.source, let url = SteamLibrary.coverURL(appID: appID) else { continue }
            coverFetches.insert(game.id)
            let file = "steam-\(appID).jpg", target = paths.covers.appendingPathComponent(file)
            Task {
                if !FileManager.default.fileExists(atPath: target.path) {
                    guard let (data, response) = try? await URLSession.shared.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil else { return }
                    try? data.write(to: target)
                }
                await MainActor.run {
                    if var g = self.game(game.id), g.coverFile == nil { g.coverFile = file; self.update(g) }
                }
            }
        }
    }

    // MARK: Games

    func addGame(_ game: Game) {
        mutate { $0.games.append(game) }
        selectedGameID = game.id
    }

    func remove(_ game: Game) {
        mutate { s in
            s.games.removeAll { $0.id == game.id }
            if let k = game.storeKey { s.hiddenStoreKeys.insert(k) }
        }
        if selectedGameID == game.id { selectedGameID = nil }
    }

    func isRunning(_ game: Game) -> Bool { running[game.id]?.isRunning == true }

    func play(_ game: Game) {
        guard let paths, let space = space(game.spaceID) else { return }
        Task {
            guard let engine = await ensureEngine(EngineCatalog.info(space.engineID) ?? EngineCatalog.wineStaging) else { return }
            do {
                let plan = try LaunchPlanner.plan(for: game, in: space, verboseLogs: verboseLogs)
                if !plan.chromiumHelpers.isEmpty {
                    try ChromiumHelperWrapper.apply(helpers: plan.chromiumHelpers, in: space)
                }
                try SpaceManager(paths: paths).prepareGraphics(plan.backend, engine: engine, space: space)
                let gameID = game.id
                let program = try WineLauncher.start(
                    engine: engine, space: space, arguments: plan.arguments, workingDirectory: plan.workingDirectory,
                    backend: plan.backend, tweaks: plan.tweaks, logsFolder: paths.logs, logName: game.title
                ) { [weak self] _ in
                    Task { @MainActor in self?.finished(gameID) }
                }
                var g = game
                g.lastPlayedAt = Date()
                update(g)
                if case .executable = game.source { running[game.id] = program }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finished(_ gameID: UUID) {
        if let program = running.removeValue(forKey: gameID), var g = game(gameID) {
            g.secondsPlayed += Date().timeIntervalSince(program.startedAt)
            update(g)
        }
        refreshStores()
    }

    func stop(_ game: Game) {
        guard let space = space(game.spaceID) else { return }
        running[game.id]?.terminate()
        stopAll(in: space)
    }

    /// Runs any Windows program in a space without adding it to the library.
    func run(_ file: URL, in space: Space) {
        guard let paths else { return }
        Task {
            var found = engine(for: space)
            if found == nil { found = await ensureEngine(EngineCatalog.info(space.engineID) ?? .wineStaging) }
            guard let engine = found else { return }
            do {
                _ = try WineLauncher.start(engine: engine, space: space, arguments: WineLauncher.arguments(toOpen: file),
                                           workingDirectory: file.deletingLastPathComponent(), backend: .auto,
                                           tweaks: LaunchTweaks(verboseLogs: verboseLogs),
                                           logsFolder: paths.logs, logName: file.deletingPathExtension().lastPathComponent)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Wine's own tools: winecfg, regedit, taskmgr, explorer.
    func runTool(_ tool: String, in space: Space) {
        guard let paths, let engine = engine(for: space) else { return }
        do {
            _ = try WineLauncher.start(engine: engine, space: space, arguments: [tool], workingDirectory: space.driveC,
                                       backend: .wined3d, logsFolder: paths.logs, logName: tool)
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Onboarding

    func finishOnboarding(root: URL) {
        libraryRoot = root
        load()
        onboardingDone = true
    }

    func resetOnboarding() { onboardingDone = false }
}

extension EngineInfo {
    static var wineStaging: EngineInfo { EngineCatalog.wineStaging }
}
