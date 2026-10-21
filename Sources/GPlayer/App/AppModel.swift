import AppKit
import Foundation
import GPlayerCore
import Observation

enum SidebarItem: Hashable {
    case allGames, recent, hidden, space(UUID), files, apps
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
    private(set) var state = LibraryState() {
        // The Hidden item disappears with the last hidden game, so don't leave it selected.
        didSet { if selection == .hidden, state.hiddenGames.isEmpty { selection = .allGames } }
    }
    var selection: SidebarItem? = .allGames
    var selectedGameID: UUID?
    var searchText = ""
    var activities: [Activity] = []
    var errorMessage: String?
    var addGameSource: ImportSource?
    var showAddGame = false
    var showNewSpace = false
    /// The game waiting for the "Remove from Library" confirmation.
    var gamePendingRemoval: Game?
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
    var visibleGames: [Game] { state.visibleGames }
    var hiddenGames: [Game] { state.hiddenGames }
    func visibleGames(in space: Space) -> [Game] { state.visibleGames(in: space) }
    func hiddenGames(in space: Space) -> [Game] { state.hiddenGames(in: space) }
    func space(_ id: UUID?) -> Space? { id.flatMap { state.space($0) } }
    func game(_ id: UUID?) -> Game? { id.flatMap { gid in state.games.first { $0.id == gid } } }

    // MARK: Persistence

    func load() {
        guard let paths else { return }
        images.removeAllObjects()
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
        let icons = state.games(in: space).compactMap(\.iconFile)
        mutate { s in
            s.games.removeAll { $0.spaceID == space.id }
            s.spaces.removeAll { $0.id == space.id }
        }
        icons.forEach(deleteIcon)
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

    /// Adds games that Steam or Epic installed and drops ones they no longer list. A game that is being updated
    /// stays, with its hidden state and playtime.
    func refreshStores() {
        guard paths != nil else { return }
        var changed = false
        var next = state
        var keys = state.hiddenStoreKeys
        for space in state.spaces where space.exists {
            if let preset = AppPresets.preset(space.presetID), preset.isInstalled(in: space) {
                let path = Game.storedPath(for: preset.executableURL(in: space), in: space)
                if !next.games.contains(where: { $0.spaceID == space.id && $0.kind == .app }) {
                    next.games.append(Game(title: preset.name, kind: .app, spaceID: space.id, executablePath: path))
                    changed = true
                }
            }
            var found: [StoreGame] = []
            if AppPresets.steam.isInstalled(in: space) { found += SteamLibrary.scan(space) }
            if AppPresets.epic.isInstalled(in: space) { found += EpicLibrary.scan(space) }
            let merged = StoreMerge.merge(existing: next.games, found: found, hiddenKeys: keys, spaceID: space.id)
            next.games = merged.games
            keys = merged.hiddenKeys
            changed = changed || merged.changed
        }
        next.hiddenStoreKeys = keys
        if changed { state = next; save() }
        fetchMissingCovers()
        extractMissingIcons()
    }

    // MARK: Covers and icons

    /// Decoded covers and icons by file name, so a redraw doesn't read the file again.
    private let images = NSCache<NSString, NSImage>()
    private var coverFetches = Set<UUID>()
    private var iconAttempts = Set<UUID>()

    /// A file inside the Covers folder. Only plain file names count, so a damaged library file
    /// can't point at (or delete) anything outside that folder.
    private func coverURL(_ file: String) -> URL? {
        guard let paths, !file.isEmpty, !file.contains("/"), file != ".", file != ".." else { return nil }
        return paths.covers.appendingPathComponent(file)
    }

    private func image(named file: String?) -> NSImage? {
        guard let file, let url = coverURL(file) else { return nil }
        if let cached = images.object(forKey: file as NSString) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: file as NSString)
        return image
    }

    private func forgetImage(_ file: String?) {
        if let file { images.removeObject(forKey: file as NSString) }
    }

    func coverImage(for game: Game) -> NSImage? { image(named: game.coverFile) }

    func iconImage(for game: Game) -> NSImage? { image(named: game.iconFile) }

    func setCover(_ image: URL, for game: Game) {
        guard let paths, var g = self.game(game.id) else { return }
        let name = "\(game.id.uuidString).\(image.pathExtension.isEmpty ? "png" : image.pathExtension.lowercased())"
        let target = paths.covers.appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: image, to: target)
            forgetImage(name)
            g.coverFile = name; update(g)
        } catch { errorMessage = "Couldn't use that image: \(error.localizedDescription)" }
    }

    func clearCover(for game: Game) {
        guard var g = self.game(game.id) else { return }
        forgetImage(g.coverFile)
        g.coverFile = nil; update(g)
    }

    /// Deletes a game's icon PNG.
    private func deleteIcon(_ file: String) {
        forgetImage(file)
        if let url = coverURL(file) { try? FileManager.default.removeItem(at: url) }
    }

    /// Reads each added program's icon from its .exe once, off the main thread, and keeps it as a PNG.
    func extractMissingIcons() {
        for game in state.games where game.iconFile == nil && !iconAttempts.contains(game.id) {
            guard case .executable = game.source, let space = space(game.spaceID),
                  let exe = game.executableURL(in: space), exe.pathExtension.lowercased() == "exe" else { continue }
            // A name of its own each time, so a slow read of an old program can't overwrite a newer icon.
            let id = game.id, file = "icon-\(UUID().uuidString).png"
            guard let target = coverURL(file) else { continue }
            iconAttempts.insert(id)
            Task.detached(priority: .utility) {
                guard let ico = PEIcon.icoData(fromExecutableAt: exe), let png = Self.largestPNG(fromICO: ico) else { return }
                do { try png.write(to: target, options: .atomic) } catch { return }
                await MainActor.run {
                    // Keep the icon only if the game still starts this program and has no icon yet.
                    guard var g = self.game(id), g.iconFile == nil,
                          self.space(g.spaceID).flatMap({ g.executableURL(in: $0) }) == exe else {
                        try? FileManager.default.removeItem(at: target)
                        return
                    }
                    g.iconFile = file
                    self.update(g)
                }
            }
        }
    }

    /// The biggest image in an .ico (PNG or BMP entries) as PNG data. Images over 512 pixels are skipped,
    /// so a crafted file can't make G-Player decode something huge.
    nonisolated static func largestPNG(fromICO data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
            .filter { $0.pixelsWide <= 512 && $0.pixelsHigh <= 512 }
        guard let best = reps.max(by: { $0.pixelsWide < $1.pixelsWide }) else { return nil }
        return best.representation(using: .png, properties: [:])
    }

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
        extractMissingIcons()
        selectedGameID = game.id
    }

    /// Hides a game from the library views, or shows it again. The game stays in `library.json`.
    func setHidden(_ game: Game, _ hidden: Bool) {
        guard var g = self.game(game.id) else { return }
        g.hidden = hidden ? true : nil
        update(g)
        if selectedGameID == game.id { selectedGameID = nil }
    }

    /// Removes a game the user added, and its icon. Its files stay in the space.
    func remove(_ game: Game) {
        guard game.canRemove else { return }
        let icon = (self.game(game.id) ?? game).iconFile
        mutate { $0.games.removeAll { $0.id == game.id } }
        if let icon { deleteIcon(icon) }
        if selectedGameID == game.id { selectedGameID = nil }
    }

    /// Points a game at another program. Its icon is read again from the new one.
    func setExecutable(_ game: Game, to url: URL) {
        guard var g = self.game(game.id), let space = space(g.spaceID) else { return }
        let oldIcon = g.iconFile
        g.executablePath = Game.storedPath(for: url, in: space)
        g.iconFile = nil
        update(g)
        if let oldIcon { deleteIcon(oldIcon) }
        iconAttempts.remove(g.id)
        extractMissingIcons()
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
                // The game may have changed while Wine was starting (hidden, new icon), so write to the current one.
                if var current = self.game(game.id) { current.lastPlayedAt = Date(); update(current) }
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
