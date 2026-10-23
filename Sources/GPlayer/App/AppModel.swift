import AppKit
import Foundation
import GPlayerCore
import Observation

struct LaunchRecord {
    let program: RunningProgram
    let profile: LaunchProfile
    let diagnose: Bool
}

struct BlockedLaunch: Identifiable {
    var id: UUID { gameID }
    let gameID: UUID
    let notes: [CompatNote]
    let skipped: Set<PlayCheck>
}

enum SidebarItem: Hashable {
    case allGames, recent, hidden, space(UUID), files, apps
}

/// Long work shown at the bottom of the sidebar (engine downloads, store setup, imports).
struct Activity: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var progress: Double?
    /// What the Stop button does, for its tooltip.
    var stopHelp = "Stop"
    /// Stop was pressed; the work is winding down.
    var stopping = false
    /// Setting something up (an engine, a space, Windows components, a store app): quitting asks first (`quitQuestion`).
    var isSetup = false
    /// The space whose queue this waits in, until its turn comes: the sidebar then says what the queue is busy with.
    var waitsIn: UUID?
    /// One more plain sentence under the message, for work the user didn't ask for (the engine update that goes on in the
    /// background) and so should hear why it runs.
    var note: String?
}

@MainActor @Observable
final class AppModel {
    // MARK: Settings (stored in UserDefaults)
    /// Where the settings live: the user's defaults, or a throwaway suite when the UI is drawn for review (`SnapshotRenderer`).
    @ObservationIgnored private let defaults: UserDefaults
    var libraryRoot: URL? {
        didSet { defaults.set(libraryRoot?.path, forKey: "libraryRoot") }
    }
    var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: "onboardingDone") }
    }
    var verboseLogs: Bool {
        didSet { defaults.set(verboseLogs, forKey: "verboseLogs") }
    }
    /// Show the engine menus (a space's page, New Space) so each space can choose between G-Player Wine and Wine Staging.
    /// Off by default: nobody has to know what a Wine engine is, and new spaces get G-Player Wine.
    var choosesEngines: Bool {
        didSet { defaults.set(choosesEngines, forKey: "choosesEngines") }
    }
    /// Use Apple's Game Porting Toolkit when the user installed it. Off by default (Apple's license).
    var useAppleToolkit: Bool {
        didSet {
            defaults.set(useAppleToolkit, forKey: "useAppleToolkit"); engineVersion += 1
            if useAppleToolkit != oldValue { syncD3DMetal() }
        }
    }
    /// Apple's D3DMetal as copied from the user's toolkit, if it has been (`D3DMetalStore`).
    var d3dMetal: D3DMetalStore.Info?
    var isImportingD3DMetal = false
    /// The space move to G-Player Wine waiting for the user's answer, and spaces being moved.
    var engineMove: EngineMove?
    var movingSpaces: Set<UUID> = []
    /// A G-Player Wine engine had programs open when D3DMetal was to go in or out; tried again once they quit.
    @ObservationIgnored var d3dMetalWaiting = false
    /// The last job that walks or changes the installed engines' folders (linking D3DMetal, the engine fixes, deleting a retired
    /// engine): the next one waits for it, so none works in a folder another is filling or deleting.
    @ObservationIgnored var engineFilesWork: Task<Void, Never>?
    /// Which backends each installed engine can run, read from disk once per change of engines (views ask often).
    @ObservationIgnored private let readyCache = ReadyCache()

    // MARK: State
    /// Why the library can't be used right now. While it stands nothing is saved and the window asks the user what to do
    /// (`LibraryProblemView`), so a library that is only out of reach is never replaced by an empty one.
    private(set) var libraryProblem: LibraryProblem?
    /// Where the library was before the user located it somewhere else, until it has loaded from there: its spaces' paths
    /// point into the old folder and are moved to the new one (`LibraryState.movingLibrary`).
    @ObservationIgnored private var libraryMovedFrom: URL?
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
    /// Every launch until it ends, for the diagnosis afterwards.
    var launches: [UUID: LaunchRecord] = [:]
    /// What went wrong in a game's last launch, if anything.
    var diagnoses: [UUID: [Diagnosis]] = [:]
    /// A launch waiting for the user to confirm despite a blocker (anti-cheat, known broken).
    var blockedLaunch: BlockedLaunch?
    var acknowledgedBlockers = Set<UUID>()
    var analysisAttempts = Set<UUID>()
    /// Components a busy space still needs, installed once nothing runs there.
    var pendingComponents: [UUID: Set<String>] = [:]
    /// Components the user stopped installing for a space; launches skip them until the app quits.
    var skippedComponents: [UUID: Set<String>] = [:]
    /// Games between pressing Play and their program starting (analysis, components, settings).
    var preparing = Set<UUID>()
    /// A Steam game waiting for the user to restart Steam or play with the running one.
    var steamRestart: SteamRestart?
    /// Components waiting for the user to let G-Player close Steam.
    var launcherQuit: LauncherQuit?
    /// A game the user just started that didn't start: shown in a dialog in the middle of the window.
    var failedLaunch: UUID?
    /// The game whose "Share What Worked" sheet is open.
    var sharingWorked: UUID?
    /// External spaces waiting for the user to allow or refuse changes, first one shown.
    var changesRequests: [ChangesRequest] = []
    var changesRequest: ChangesRequest? { changesRequests.first }
    /// Engines downloading in the background to take over from a retired one (`migrateEngines`): their download shows no errors,
    /// and says why it runs.
    private(set) var updatingEngines: Set<String> = []
    /// Why the background update of an engine failed in this run (its error's text), by engine id, until it is tried again or
    /// has come. Settings › Engines and the sidebar say so in one line (`EngineMigration.updateFailure`).
    private(set) var engineUpdateFailures: [String: String] = [:]
    /// Engines whose failed update the user hid from the sidebar.
    private(set) var closedUpdateNotices: Set<String> = []
    /// The replacements the background update has tried in this run, whether they came, failed or were stopped: a failed one
    /// is tried again at the next start, not before.
    @ObservationIgnored var engineUpdatesTried: Set<String> = []
    /// Retired engines whose folder was deleted, or failed to be, in this run (not tried again). A look that found the engine in
    /// use doesn't count: the next look tries again.
    @ObservationIgnored var retiredRemovalsTried: Set<String> = []
    /// The copy of library.json before the first move to another engine couldn't be made, and the user was told (once per run).
    @ObservationIgnored var engineBackupWarned = false
    /// Retired engines whose removal waits for its turn or is under way (`removeRetiredEngine`).
    @ObservationIgnored var removingEngines: Set<String> = []
    /// Launches that have begun and whose program hasn't started yet, per space. The space's engine mustn't change under one
    /// (`migrateEngines`).
    @ObservationIgnored var launchesStarting: [UUID: Int] = [:]
    /// Spaces an Add Game is working in, and how many: from the choice of the space until the installer has quit or the game was
    /// copied in. The space's engine mustn't change, or be deleted, under the steps in between (`migrateEngines`).
    @ObservationIgnored var addGameSpaces: [UUID: Int] = [:]
    /// Stops for activities that can be stopped, by activity id.
    var cancellers: [UUID: () -> Void] = [:]
    /// Work queued per space (installs, store setup), so two installers never run in one space at once.
    private var spaceQueues: [UUID: Task<Void, Never>] = [:]
    /// Installs and store setups queued or running, per space (launches use the queue too but don't count).
    private var queuedInstalls: [UUID: Int] = [:]
    private var queuedWork: [UUID: Int] = [:]
    /// Engine downloads running, by engine id (`ensureEngine`), and why the last one of each failed.
    @ObservationIgnored private var engineInstalls: [String: Task<Engine?, Never>] = [:]
    @ObservationIgnored private var engineFailures: [String: Error] = [:]
    /// Engines whose download the user stopped (Stop in the sidebar), so the first run doesn't go on to the next one.
    @ObservationIgnored private var stoppedEngines: Set<String> = []
    /// The clean-up of what an earlier run left (`cleanEngineLeftovers`); an engine or component install waits for it, so it
    /// never removes the file or folder of the one that has just begun.
    @ObservationIgnored var leftoversCleaning: Task<Void, Never>?
    /// Store apps being set up (`installPreset`), by preset id: a second request for the same one is ignored, so
    /// "Steam" never becomes "Steam" and "Steam 2".
    private(set) var installingPresets: Set<String> = []
    /// The first spaces onboarding promised ("main", "steam") that aren't made yet. Kept on disk, so quitting before
    /// the engines are in doesn't lose them.
    private(set) var firstRunSpaces: [String] {
        didSet { defaults.set(firstRunSpaces, forKey: "firstRunSpaces") }
    }
    @ObservationIgnored private var makingFirstRunSpaces = false
    /// The user stopped the first run's download, so the first spaces wait for the engines (`resumeFirstRunSpaces`) and aren't
    /// made on whatever engine happens to be there. They go on once an engine is installed, or at the next start.
    private(set) var firstRunPaused = false
    /// The note about that was closed.
    var pausedNoteClosed = false
    /// The first run's engine installs while they run (`installFirstRunEngines`); onboarding shows them.
    private var firstRunInstall: Task<Void, Never>?
    var isInstallingFirstRun: Bool { firstRunInstall != nil }
    /// The one-time note about G-Player Wine was shown and closed, or isn't for this person (`FirstRunSetup.upgradeNoteApplies`).
    var engineNoteSeen: Bool {
        didSet { defaults.set(engineNoteSeen, forKey: "engineNoteSeen") }
    }
    /// The store app just set up, while its "ready" note shows in the library (`AppModel+FirstRun`).
    var storeReadyID: String?
    var engineVersion = 0                        // bumps when engines change, so views re-read them
    var componentsVersion = 0                    // bumps when components are installed

    /// - Parameter watching: false keeps the model passive (no process watcher, no observers), for drawing the UI.
    init(defaults d: UserDefaults = .standard, watching: Bool = true) {
        defaults = d
        libraryRoot = d.string(forKey: "libraryRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
        onboardingDone = d.bool(forKey: "onboardingDone")
        verboseLogs = d.bool(forKey: "verboseLogs")
        choosesEngines = d.bool(forKey: "choosesEngines")
        useAppleToolkit = d.bool(forKey: "useAppleToolkit")
        firstRunSpaces = d.stringArray(forKey: "firstRunSpaces") ?? []
        engineNoteSeen = d.bool(forKey: "engineNoteSeen")
        if libraryRoot != nil { load(expectingLibrary: true); cleanEngineLeftovers() }
        // For screenshots and UI checks: `open G-Player.app --args -selectGame "<title>"` (not saved).
        if let title = d.volatileDomain(forName: UserDefaults.argumentDomain)["selectGame"] as? String,
           let g = state.games.first(where: { $0.title == title }) {
            selection = g.isHidden ? .hidden : .allGames
            selectedGameID = g.id
        }
        guard watching else { return }
        NotificationCenter.default.addObserver(forName: .gplayerOpenFile, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let url = note.object as? URL, let source = ImportSource(url) else { return }
                self.openAddGame(source, explains: true)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStores(); self?.refreshPrograms() }
        }
        watchPrograms()
        if onboardingDone, libraryRoot != nil { resumeFirstRunSpaces() }
    }

    /// The library's folders, or nil while there is no library or it can't be used (`libraryProblem`): every write to the
    /// library goes through this, so none happens then.
    var paths: LibraryPaths? { libraryProblem == nil ? libraryRoot.map(LibraryPaths.init) : nil }
    /// Why a library folder can't be used (its path is too long for Wine), or nil. See `PrefixPath`. For the library in
    /// use the answer says how to move it; for a folder being chosen, to choose another.
    func libraryRootProblem(_ root: URL) -> String? {
        if onboardingDone, root.standardizedFileURL == libraryRoot?.standardizedFileURL {
            return PrefixPath.existingLibraryProblem(root)
        }
        return PrefixPath.libraryRootProblem(root)
    }
    var spaces: [Space] { state.spaces }
    var games: [Game] { state.games }
    var visibleGames: [Game] { state.visibleGames }
    var hiddenGames: [Game] { state.hiddenGames }
    func visibleGames(in space: Space) -> [Game] { state.visibleGames(in: space) }
    func hiddenGames(in space: Space) -> [Game] { state.hiddenGames(in: space) }
    func space(_ id: UUID?) -> Space? { id.flatMap { state.space($0) } }
    func game(_ id: UUID?) -> Game? { id.flatMap { gid in state.games.first { $0.id == gid } } }

    // MARK: Persistence

    /// Opens the library. A library that can't be read (`libraryProblem`) is never replaced by an empty one: the state stays
    /// empty, nothing is saved, and the user decides. Returns true when the library is open.
    /// - Parameter expectingLibrary: the folder is one a library was set up in, so one that is gone is a problem and not made
    ///   again, empty. Without it that is so once onboarding is done; at start it is always so (the folder was made then).
    @discardableResult
    func load(expectingLibrary: Bool? = nil) -> Bool {
        guard let root = libraryRoot else { return false }
        images.removeAllObjects()
        let store = LibraryStore(paths: LibraryPaths(root: root))
        switch store.open(expectingLibrary: expectingLibrary ?? onboardingDone) {
        case .blocked(let problem):
            libraryProblem = problem
            state = LibraryState()
            return false
        case .ready(var loaded):
            libraryProblem = nil
            do { try store.paths.createFolders() } catch { errorMessage = "Couldn't create the library folders: \(error.localizedDescription)" }
            var moved = false
            if let old = libraryMovedFrom {
                loaded = loaded.movingLibrary(from: old, to: root)
                libraryMovedFrom = nil
                moved = true
            }
            state = loaded
            if moved { save() }
            migrateAppleToolkitSetting()
            migrateManualGraphics()
            migrateEngines()
            applyEngineFixes()
            syncD3DMetal()
            refreshStores()
            return true
        }
    }

    /// Try Again on the library screen.
    func retryLibrary() {
        if load() { libraryOpened() }
    }

    /// Locate… on the library screen: `chosen` is the folder the library is in now. A folder without one is refused.
    func locateLibrary(_ chosen: URL) {
        guard let folder = LibraryStore.libraryFolder(in: chosen) else {
            errorMessage = "“\(chosen.lastPathComponent)” has no G-Player library in it. Choose the folder that holds library.json."
            return
        }
        if libraryMovedFrom == nil, let old = libraryRoot, old.standardizedFileURL != folder { libraryMovedFrom = old }
        libraryRoot = folder
        if load() { libraryOpened() }
    }

    /// Use Previous Copy on the library screen: the copy G-Player kept of the library as it was before its last change.
    func restorePreviousLibrary() {
        guard let root = libraryRoot else { return }
        do { _ = try LibraryStore(paths: LibraryPaths(root: root)).restorePrevious() }
        catch { errorMessage = "Couldn't use the previous copy: \(error.localizedDescription)"; return }
        if load() { libraryOpened() }
    }

    /// Start Empty on the library screen: an empty library in its place. The damaged library.json stays next to it as
    /// `library.json.broken-…`, and the previous copy as `library.json.before-empty-…`: the first changes to the new library
    /// would rotate it into `library.json.previous` and the last good library would be gone.
    func startEmptyLibrary() {
        guard let problem = libraryProblem, let root = libraryRoot else { return }
        guard problem.canStartEmpty else {
            errorMessage = "G-Player has no copy of library.json, so it won't replace the file. Move it away yourself, then try again."
            return
        }
        // Before anything is written: if the previous copy can't be kept, the empty library isn't started.
        do { try LibraryStore(paths: LibraryPaths(root: root)).keepPreviousBeforeStartingEmpty() }
        catch {
            errorMessage = "G-Player couldn't keep the previous copy of the library, so it won't start an empty one. \(error.localizedDescription)"
            return
        }
        do { try LibraryPaths(root: root).createFolders() }
        catch { errorMessage = "Couldn't create the library folder: \(error.localizedDescription)"; return }
        libraryProblem = nil
        libraryMovedFrom = nil
        state = LibraryState()
        save()
        libraryOpened()
        refreshStores()
    }

    /// What waited for the library: the first spaces onboarding promised.
    private func libraryOpened() {
        if onboardingDone { resumeFirstRunSpaces() }
    }

    private func save() {
        guard let paths else { return }
        do { try LibraryStore(paths: paths).save(state) }
        catch { errorMessage = "Couldn't save the library: \(error.localizedDescription)" }
    }

    func mutate(_ change: (inout LibraryState) -> Void) {
        guard libraryProblem == nil else { return }
        change(&state)
        save()
    }

    func update(_ game: Game) { mutate { s in if let i = s.games.firstIndex(where: { $0.id == game.id }) { s.games[i] = game } } }
    func update(_ space: Space) { mutate { s in if let i = s.spaces.firstIndex(where: { $0.id == space.id }) { s.spaces[i] = space } } }

    // MARK: Engines

    var engineManager: EngineManager? { paths.map(EngineManager.init) }

    func engine(for space: Space) -> Engine? {
        _ = engineVersion
        if space.engineID == EngineCatalog.gptk.id && !useAppleToolkit { return nil }
        return engineManager?.engine(id: space.engineID)
    }

    func isInstalled(_ info: EngineInfo) -> Bool {
        _ = engineVersion
        if info.kind == .gptk && !useAppleToolkit { return false }
        return engineManager?.isInstalled(info) ?? false
    }

    /// The space's engine as far as decisions go: only the backends it can run now (D3DMetal once it is copied in,
    /// say), or the catalogue's list while the engine isn't installed yet.
    func engineInfo(for space: Space) -> EngineInfo {
        let info = EngineCatalog.info(space.engineID) ?? EngineCatalog.wineStaging
        if readyCache.version != engineVersion || readyCache.toolkitOn != useAppleToolkit {
            readyCache.backends = [:]; readyCache.version = engineVersion; readyCache.toolkitOn = useAppleToolkit
        }
        if let ready = readyCache.backends[info.id] { return ready.map { info.limited(to: $0) } ?? info }
        let ready = engine(for: space).map(readyBackends(of:))
        readyCache.backends[info.id] = .some(ready)
        return ready.map { info.limited(to: $0) } ?? info
    }

    /// What `engine` can run now, with D3DMetal only while Apple's toolkit is turned on.
    func readyBackends(of engine: Engine) -> [GraphicsBackend] {
        engine.readyBackends.filter { $0 != .d3dmetal || useAppleToolkit }
    }

    /// A space on Apple's toolkit while the toolkit is turned off.
    func needsAppleToolkit(_ space: Space) -> Bool { space.engineID == EngineCatalog.gptk.id && !useAppleToolkit }

    /// The engine for a new space made without a choice (`EngineCatalog.engineForNewSpace`).
    var newSpaceEngine: EngineInfo { EngineCatalog.engineForNewSpace(installed: installedEngines) }

    /// The engine for a new space made without a choice (`EngineCatalog.engineForNewSpace`), or the one picked in the New
    /// Space sheet while the engine menus are on.
    func engineForNewSpace(picking picked: String?) -> EngineInfo {
        EngineCatalog.engineForNewSpace(installed: installedEngines, picked: picked, choosing: choosesEngines)
    }

    /// What a space's page offers about its engine (`EngineSwitch.pageOffer`).
    func engineOffer(for space: Space) -> EngineSwitch.PageOffer {
        EngineSwitch.pageOffer(engineID: space.engineID, choosingEngines: choosesEngines)
    }

    /// Some space runs on this engine.
    func isInUse(_ info: EngineInfo) -> Bool { state.spaces.contains { $0.engineID == info.id } }

    /// What an engine picker adds after an engine's name: recommended, and whether it needs a download (with its
    /// size). `listsInstalled` also says "installed", for the picker that chooses an engine for a new space.
    func engineNote(_ info: EngineInfo, listsInstalled: Bool = false) -> String {
        var notes = info.isRecommended ? ["recommended"] : []
        if isInstalled(info) { if listsInstalled { notes.append("installed") } }
        else {
            let mb = EngineCatalog.megabytes(info.downloadBytes(wineStagingInstalled: isInstalled(EngineCatalog.wineStaging)))
            notes.append("\(mb) MB to download")
        }
        return notes.isEmpty ? "" : "  · " + notes.joined(separator: ", ")
    }

    /// Puts G-Player's Wine fixes into engines installed before they existed (new installs get them right away). Retired
    /// engines too: spaces still run on them. In turn with the other work in engine folders (`engineFilesWork`).
    private func applyEngineFixes() {
        guard let manager = engineManager else { return }
        let previous = engineFilesWork
        engineFilesWork = Task {
            await previous?.value
            await Task.detached(priority: .utility) {
                for info in EngineCatalog.known { if let engine = manager.engine(info) { EngineFixes.apply(to: engine) } }
            }.value
        }
    }

    /// Spaces from before 0.3 that already run on the toolkit keep working: turn it on once for them. The answer is
    /// saved either way, so spaces found later never turn it on by themselves.
    private func migrateAppleToolkitSetting() {
        guard defaults.object(forKey: "useAppleToolkit") == nil else { return }
        useAppleToolkit = state.spaces.contains { $0.engineID == EngineCatalog.gptk.id }
    }

    /// 0.2 had only the graphics picker. A choice made there means the Custom profile now, or Recommended would
    /// override it.
    private func migrateManualGraphics() {
        var changed = false
        for i in state.games.indices where state.games[i].kind == .game && state.games[i].graphics != .auto
            && state.games[i].options == nil {
            state.games[i].options = LaunchOptions(profile: .custom)
            changed = true
        }
        if changed { save() }
    }

    /// What an engine's download is called in the sidebar, and what views look for to show its progress.
    static func downloadTitle(_ info: EngineInfo) -> String { "Downloading \(info.name)" }

    /// The engine's download while it runs.
    func download(of info: EngineInfo) -> Activity? { activities.first { $0.title == Self.downloadTitle(info) } }

    var isEngineBusy: Bool { EngineCatalog.all.contains { download(of: $0) != nil } }

    /// The engines installed on this Mac, retired ones included: they still run the spaces that are on them.
    var installedEngines: [EngineInfo] { EngineCatalog.known.filter { isInstalled($0) } }

    /// Downloads an engine if it is missing. Returns nil when that failed (the error is shown). Asked again while
    /// the engine downloads (onboarding and a new space can ask at once), it waits for that download: two would
    /// write the same file.
    /// - Parameter updating: the download is the background update that replaces a retired engine
    ///   (`updateEngineInBackground`): nothing is asked of the user, so a failure is not shown.
    @discardableResult
    func ensureEngine(_ info: EngineInfo, updating: Bool = false) async -> Engine? {
        guard let manager = engineManager else { return nil }
        if info.kind == .gptk && !useAppleToolkit {
            errorMessage = "This space uses \(info.name), which is turned off. Turn it on in Settings › Engines."
            return nil
        }
        if let e = manager.engine(info) { return e }
        // A retired engine that isn't installed is never installed again: its replacement does the same work, and a space
        // that asked for the old one moves to it.
        if let replacement = EngineCatalog.replacement(of: info) {
            let engine = await ensureEngine(replacement, updating: updating)
            migrateEngines()
            return engine
        }
        if info.downloads.isEmpty {
            errorMessage = useAppleToolkit
                ? "\(info.name) isn't installed on this Mac. G-Player doesn't download it; see Settings › Engines."
                : "This space uses \(info.name), which is turned off. Turn it on in Settings › Engines."
            return nil
        }
        if let running = engineInstalls[info.id] {
            let inBackground = updatingEngines.contains(info.id)
            let engine = await running.value
            // A background update that failed said nothing; someone who needed the engine meanwhile hears why.
            if engine == nil, inBackground, !updating, let failure = engineFailures[info.id] {
                errorMessage = "Couldn't install \(info.name): \(failure.localizedDescription)"
            }
            return engine
        }
        if updating { updatingEngines.insert(info.id) }
        let task = Task { await self.installEngine(info, with: manager, updating: updating) }
        engineInstalls[info.id] = task
        return await task.value
    }

    /// Downloads `info` in the background to take over from a retired engine, once per run (`engineUpdatesTried`): offline,
    /// failing or stopped, nothing is said, and the spaces stay on the old engine until the next start.
    func updateEngineInBackground(_ info: EngineInfo) {
        guard engineUpdatesTried.insert(info.id).inserted, engineInstalls[info.id] == nil else { return }
        Task { await ensureEngine(info, updating: true) }
    }

    /// The engine is downloading in the background to replace a retired one (Settings says why).
    func isUpdating(_ info: EngineInfo) -> Bool { updatingEngines.contains(info.id) }

    /// The line to show where the engine's download is offered: its background update failed, and is tried again at the next
    /// start. Nil while it hasn't failed, is under way, or has come.
    func updateFailureLine(for info: EngineInfo) -> String? {
        guard !updatingEngines.contains(info.id), !isInstalled(info), let reason = engineUpdateFailures[info.id] else { return nil }
        return EngineMigration.updateFailure(for: info, reason: reason)
    }

    /// The failed updates the sidebar still shows.
    var updateNotices: [(id: String, line: String)] {
        EngineCatalog.all.filter { !closedUpdateNotices.contains($0.id) }
            .compactMap { info in updateFailureLine(for: info).map { (info.id, $0) } }
    }

    func closeUpdateNotice(_ id: String) { closedUpdateNotices.insert(id) }

    private func installEngine(_ info: EngineInfo, with manager: EngineManager, updating: Bool) async -> Engine? {
        await leftoversCleaning?.value
        // An update nobody asked for isn't "setup" to quit over: what came is kept, and it goes on at the next start.
        let activity = begin(Self.downloadTitle(info), "Starting", setup: !updating,
                             note: updating ? EngineMigration.shortUpdateNote(for: info) : nil)
        defer { end(activity); cancellers[activity] = nil; engineInstalls[info.id] = nil; updatingEngines.remove(info.id) }
        engineFailures[info.id] = nil
        engineUpdateFailures[info.id] = nil
        closedUpdateNotices.remove(info.id)
        stoppedEngines.remove(info.id)
        // What came stays on disk, so downloading again goes on from there.
        setStop(activity, help: "Stop downloading \(info.name). What came is kept, and the download goes on from there next time.") { [weak self] in
            self?.stoppedEngines.insert(info.id)
            self?.engineInstalls[info.id]?.cancel()
        }
        do {
            let engine = try await manager.install(info) { [weak self] fraction, message in
                Task { @MainActor in self?.progress(activity, fraction, message) }
            }
            engineVersion += 1
            if info.kind == .crossover { await prepareD3DMetal() }     // D3DMetal only while Apple's toolkit is on
            if onboardingDone, !firstRunSpaces.isEmpty { resumeFirstRunSpaces() }     // spaces that waited for an engine
            migrateEngines()                                        // spaces on a retired engine can move now
            return engine
        } catch is CancellationError {
            return nil
        } catch {
            engineFailures[info.id] = error
            if updating { engineUpdateFailures[info.id] = error.localizedDescription }       // no alert: a line says so
            else { errorMessage = "Couldn't install \(info.name): \(error.localizedDescription)" }
            return nil
        }
    }

    /// The spaces on this engine that have programs running or installs going on: the engine's files are in use there.
    func busySpaces(using info: EngineInfo) async -> [Space] {
        let onEngine = state.spaces.filter { $0.engineID == info.id }
        let running = await Task.detached(priority: .userInitiated) { () -> [UUID] in
            let all = WineProcesses.snapshot()
            return onEngine.filter { WineProcesses.isRunning(in: $0, processes: all) }.map(\.id)
        }.value
        return onEngine.filter { running.contains($0.id) || installingSpaces.contains($0.id) }
    }

    /// Removes an engine unless programs run on it. Returns the spaces that keep it busy (nothing is removed then).
    @discardableResult
    func removeEngine(_ info: EngineInfo) async -> [Space] {
        let busy = await busySpaces(using: info)
        guard busy.isEmpty else { return busy }
        do { try engineManager?.remove(info); engineVersion += 1 }
        catch { errorMessage = error.localizedDescription }
        return []
    }

    /// Clears what work that never ended left behind, once per start and never while an engine is downloading: the hidden
    /// folders of engine installs, stale downloads, component downloads with their temporary names, and the unpacked folders
    /// of Add Game installers that no program runs from any more (`Leftovers`).
    private func cleanEngineLeftovers() {
        guard let manager = engineManager, engineInstalls.isEmpty, firstRunInstall == nil else { return }
        leftoversCleaning = Task.detached(priority: .utility) {
            manager.cleanLeftovers()
            Leftovers.clean(manager.paths, processes: WineProcesses.snapshot())
        }
    }

    /// The first run's engine: G-Player Wine, with its runtime libraries from Gcenx's Wine Staging archive (downloaded for
    /// them and deleted; Wine Staging isn't installed). Starts once at a time. A failure shows in one message, and the message
    /// says what the first spaces use then.
    func installFirstRunEngines() {
        guard firstRunInstall == nil, let manager = engineManager else { return }
        // G-Player Wine takes about 3.0 GB with its downloads (`FirstRunSetup.diskLabel`): said before anything is downloaded,
        // not when the disk fills up.
        let missing = EngineCatalog.firstRunInstalls.filter { !isInstalled($0) }
        if let problem = manager.diskProblem(installing: missing) { errorMessage = problem; return }
        firstRunPaused = false
        firstRunInstall = Task {
            var failures: [String] = []
            for info in EngineCatalog.firstRunInstalls where await ensureEngine(info) == nil {
                if stoppedEngines.contains(info.id) {                                   // Stop means stop: the first spaces wait
                    firstRunPaused = true                                               // for the engine
                    pausedNoteClosed = false
                    break
                }
                failures.append(errorMessage ?? "\(info.name) wasn't installed.")
                errorMessage = nil                                  // shown together below, not one over the other
            }
            if !failures.isEmpty {
                let gplayerWine = EngineCatalog.installedGPlayerWine(in: installedEngines) != nil, staging = isInstalled(EngineCatalog.wineStaging)
                failures.append(gplayerWine ? "" : staging
                    ? "Your first spaces will use Wine Staging instead. Download G-Player Wine later in Settings › Engines."
                    : "Download G-Player Wine again in Settings › Engines. The first spaces are made once it is installed.")
                errorMessage = failures.filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            firstRunInstall = nil
        }
    }

    /// The engine for the spaces the first run creates, once its installs are over: G-Player Wine, or a Wine Staging that
    /// is installed already when G-Player Wine couldn't be. Nil with neither installed.
    func firstRunEngine() async -> EngineInfo? {
        await firstRunInstall?.value
        return EngineCatalog.firstRunEngine(installed: installedEngines)
    }

    /// Makes the first spaces onboarding offered (Main, Steam) once an engine is there. The list is saved, so quitting
    /// before the engines are in doesn't lose them: `resumeFirstRunSpaces` goes on at the next start.
    func createFirstRunSpaces(main: Bool, steam: Bool) {
        firstRunSpaces = (main ? ["main"] : []) + (steam ? ["steam"] : [])
        resumeFirstRunSpaces()
    }

    /// Installs the engines still missing and makes the first spaces still on the list, each once. With no engine
    /// installed (the download failed) they stay on the list for the next start.
    func resumeFirstRunSpaces() {
        guard !firstRunSpaces.isEmpty, !makingFirstRunSpaces, libraryProblem == nil else { return }
        makingFirstRunSpaces = true
        Task {
            defer { makingFirstRunSpaces = false }
            firstRunPaused = false
            if !EngineCatalog.firstRunInstalls.allSatisfy({ isInstalled($0) }) { installFirstRunEngines() }
            guard let engine = await firstRunEngine() else { return }
            // Stopped by the user: the spaces wait for G-Player Wine, on the saved list, and not on Wine Staging by the way.
            // (An engine that failed to download is another matter: its message says the spaces use the other one.)
            if firstRunPaused { return }
            for key in firstRunSpaces {
                switch key {
                case "main":
                    if !spaces.contains(where: { $0.name == "Main" }) { _ = await createSpace(name: "Main", engineInfo: engine) }
                case "steam":
                    // Also when an earlier start made the space and quit before Steam was in: the install goes on in it.
                    if !isInstalled(AppPresets.steam) { await installPreset(AppPresets.steam, engineInfo: engine) }
                default: break
                }
                firstRunSpaces.removeAll { $0 == key }              // tried: a failure was shown, not tried again at every start
            }
        }
    }

    // MARK: Activities

    func begin(_ title: String, _ message: String, progress: Double? = nil, setup: Bool = false, waitsIn: UUID? = nil,
               note: String? = nil) -> UUID {
        var a = Activity(title: title, message: message, progress: progress)
        a.isSetup = setup
        a.waitsIn = waitsIn
        a.note = note
        activities.append(a)
        return a.id
    }

    /// What the sidebar says under an activity: its message, or while it waits for its turn in a space, what the space is busy
    /// with ("Waiting for the installer of “Game”…").
    func message(of activity: Activity) -> String {
        guard let space = activity.waitsIn, !activity.stopping else { return activity.message }
        return "Waiting for \(queueHolder(in: space) ?? "other work in this space")…"
    }

    /// The queue's turn has come for an activity that waited.
    func startedWaiting(_ id: UUID) {
        if let i = activities.firstIndex(where: { $0.id == id }) { activities[i].waitsIn = nil }
    }

    /// The question to ask before quitting while something is being set up, or nil when nothing is. Setup goes on by itself
    /// at the next start only while the first spaces are on the saved list (`SetupQuit.outcome`); the rest is started again
    /// by hand, and it says so.
    var quitQuestion: (title: String, detail: String)? {
        let titles = activities.filter { $0.isSetup && !$0.stopping }.map(\.title)
        guard !titles.isEmpty else { return nil }
        return SetupQuit.question(titles: titles, outcome: SetupQuit.outcome(onboardingDone: onboardingDone,
                                                                              pendingFirstRunSpaces: !firstRunSpaces.isEmpty))
    }

    func progress(_ id: UUID, _ fraction: Double?, _ message: String) {
        guard let i = activities.firstIndex(where: { $0.id == id }), !activities[i].stopping else { return }
        activities[i].progress = fraction
        activities[i].message = message
    }

    /// Makes an activity stoppable: `stop` runs when the user presses Stop.
    func setStop(_ id: UUID, help: String, _ stop: @escaping () -> Void) {
        cancellers[id] = stop
        if let i = activities.firstIndex(where: { $0.id == id }) { activities[i].stopHelp = help }
    }

    func isStopping(_ id: UUID) -> Bool { activities.first { $0.id == id }?.stopping ?? false }

    func end(_ id: UUID) { activities.removeAll { $0.id == id } }

    func canCancel(_ id: UUID) -> Bool { cancellers[id] != nil }

    /// Stops an activity. It stays in the sidebar, saying so, until its work has really ended.
    func cancel(_ id: UUID) {
        guard let stop = cancellers.removeValue(forKey: id) else { return }
        progress(id, nil, "Stopping…")
        if let i = activities.firstIndex(where: { $0.id == id }) { activities[i].stopping = true }
        stop()
    }

    // MARK: Per-space queue

    /// Spaces with installs or store setup queued or running.
    var installingSpaces: Set<UUID> { Set(queuedInstalls.keys).union(activeInstalls.keys) }
    /// What is queued or running in each space, oldest first, by what it is called to those who wait for it.
    private var queueEntries: [UUID: [QueueEntry]] = [:]
    private struct QueueEntry { let id = UUID(); let holds: String }
    /// What the space's queue is busy with now ("the installer of “Game”"), or nil when it is empty.
    func queueHolder(in spaceID: UUID) -> String? { queueEntries[spaceID]?.first?.holds }
    /// Component installs running right now, per space (also those a launch started).
    var activeInstalls: [UUID: Int] = [:]

    /// Runs `work` after everything queued for the space before it. Queuing happens at once, so the order of calls
    /// is the order of work. Queued work must never wait for the queue of its own space (that would wait forever).
    /// - Parameters:
    ///   - isInstall: counts towards `installingSpaces`. Launches pass false.
    ///   - holds: what the work is called to the ones that wait behind it, after "Waiting for" ("Windows components for
    ///     “Main”", "the installer of “Game”").
    @discardableResult
    func enqueue<T: Sendable>(in spaceID: UUID, isInstall: Bool = true, holds: String,
                              _ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = spaceQueues[spaceID]
        queuedWork[spaceID, default: 0] += 1
        if isInstall { queuedInstalls[spaceID, default: 0] += 1 }
        let entry = QueueEntry(holds: holds)
        queueEntries[spaceID, default: []].append(entry)
        let task = Task { @MainActor () -> T in
            await previous?.value
            let result = await work()
            queueEntries[spaceID]?.removeAll { $0.id == entry.id }
            if queueEntries[spaceID]?.isEmpty == true { queueEntries[spaceID] = nil }
            if isInstall { Self.decrement(&self.queuedInstalls, spaceID) }
            if Self.decrement(&self.queuedWork, spaceID) == 0 { self.spaceQueues[spaceID] = nil }
            return result
        }
        spaceQueues[spaceID] = Task { _ = await task.value }
        return task
    }

    @discardableResult
    static func decrement(_ counts: inout [UUID: Int], _ id: UUID) -> Int {
        let left = (counts[id] ?? 1) - 1
        counts[id] = left > 0 ? left : nil
        return max(left, 0)
    }

    // MARK: Spaces

    func nextColor() -> Int { SpaceColor.next(after: state.spaces.map(\.colorIndex)) }

    /// Creates a space (downloading the engine first if needed). Without a choice it gets `newSpaceEngine`: G-Player
    /// Wine, or Wine Staging while that is the only engine installed. When G-Player Wine can't be downloaded and
    /// Wine Staging is installed, the space gets Staging and the message says so.
    func createSpace(name: String, engineInfo: EngineInfo? = nil, presetID: String? = nil) async -> Space? {
        guard let paths else { return nil }
        // Before an engine is downloaded for it: a library folder with a path too long can't hold any new space.
        if let problem = PrefixPath.existingLibraryProblem(paths.root) { errorMessage = problem; return nil }
        let wanted = engineInfo ?? newSpaceEngine
        var chosen = await ensureEngine(wanted)
        if chosen == nil, wanted.id == EngineCatalog.defaultForNewSpaces.id,
           let staging = engineManager?.engine(EngineCatalog.wineStaging) {
            errorMessage = (errorMessage ?? "\(wanted.name) wasn't installed.")
                + "\n\n“\(name)” uses \(staging.info.name) instead. You can move it to \(wanted.name) from its page once that is installed."
            chosen = staging
        }
        guard let engine = chosen else { return nil }
        // A caller that was stopped while the engine downloaded (Cancel in Add Game) doesn't want the space any more.
        if Task.isCancelled { return nil }
        let activity = begin("Creating “\(name)”", "Setting up Windows. This takes about a minute the first time.", setup: true)
        defer { end(activity) }
        do {
            let space = try await SpaceManager(paths: paths).create(name: name, engine: engine,
                                                                     colorIndex: nextColor(), presetID: presetID)
            mutate { $0.spaces.append(space) }
            // Queued now, so a store setup that follows waits for these installers.
            let base = CompatResolver.baseComponents
            enqueue(in: space.id, holds: "Windows components for “\(name)”") {
                await self.installNow(base, in: space, engine: engine, reason: "for “\(name)”", retryFailed: false)
            }
            return space
        } catch {
            errorMessage = "Couldn't create the space: \(error.localizedDescription)"
            return nil
        }
    }

    /// Uses an environment found on the Mac (CrossOver bottle, older prefix) in place, with its games. One whose path is
    /// too long for Wine is refused, with the reason shown.
    @discardableResult
    func adopt(_ found: FoundEnvironment) -> Bool {
        if let problem = found.pathProblem { errorMessage = "Couldn't add “\(found.name)”. \(problem)"; return false }
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
        return true
    }

    func removeSpace(_ space: Space, deleteFiles: Bool, permanently: Bool = false) {
        if deleteFiles, let paths {
            do { try SpaceManager(paths: paths).delete(space, permanently: permanently) }
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

    /// Works with Apple's toolkit turned off too, so a space that uses it can always be stopped.
    func stopAll(in space: Space) {
        guard let engine = engineManager?.engine(id: space.engineID) else { return }
        for g in state.games(in: space) { autoLaunches[g.id] = nil }      // stopped on purpose: not a failure to learn from
        Task {
            await WineLauncher.killAll(engine: engine, space: space)
            await MainActor.run { for g in state.games(in: space) { running[g.id] = nil }; refreshPrograms() }
        }
    }

    // MARK: Presets (Steam, Epic…)

    func presetSpace(_ preset: AppPreset) -> Space? { state.spaces.first { $0.presetID == preset.id } }

    func isInstalled(_ preset: AppPreset) -> Bool { presetSpace(preset).map(preset.isInstalled) ?? false }

    func isInstalling(_ preset: AppPreset) -> Bool { installingPresets.contains(preset.id) }

    func installPreset(_ preset: AppPreset, engineInfo: EngineInfo? = nil) async {
        guard let paths else { return }
        // The first run and Get Apps can ask at once, and the space only exists once Windows is set up in it (a minute):
        // a second request would make another space.
        guard installingPresets.insert(preset.id).inserted else { return }
        defer { installingPresets.remove(preset.id) }
        var space = presetSpace(preset)
        if let found = space, !found.mayChange {
            // An adopted bottle Steam was removed from: install into it only with the user's go-ahead.
            askToChange(found) { allowed in if allowed { Task { await self.installPreset(preset) } } }
            return
        }
        if space == nil { space = await createSpace(name: preset.name, engineInfo: engineInfo, presetID: preset.id) }
        guard let space else { return }
        // The space's engine may be gone (removed, or a download that was stopped): get it again, don't do nothing.
        var ready = engine(for: space)
        if ready == nil { ready = await ensureEngine(EngineCatalog.info(space.engineID) ?? .wineStaging) }
        guard let engine = ready else { return }
        let activity = begin("Setting up \(preset.name)", "Starting", setup: true, waitsIn: queueHolder(in: space.id) == nil ? nil : space.id)
        defer { end(activity); cancellers[activity] = nil }
        let help = "Stop setting up \(preset.name). You can set it up again later."
        setStop(activity, help: help) { [weak self] in self?.end(activity) }    // while waiting, Stop drops the setup
        // After the space's base components: Steam's first start stops every program in the space.
        await enqueue(in: space.id, holds: "\(preset.name) to finish setting up") {
            self.startedWaiting(activity)
            // Stopped while waiting (the activity is gone), or set up by an earlier press of the same button.
            guard self.activities.contains(where: { $0.id == activity && !$0.stopping }),
                  !preset.isInstalled(in: space) else { return }
            let work = Task.detached {
                try await PresetInstaller(paths: paths).install(preset, in: space, engine: engine) { [weak self] f, m in
                    Task { @MainActor in self?.progress(activity, f, m) }
                }
            }
            self.setStop(activity, help: help) { work.cancel() }
            defer { self.cancellers[activity] = nil }
            do {
                try await work.value
                self.ensureLauncherEntry(for: space)
                self.refreshStores()
                self.noteStoreReady(preset, in: space)
            } catch is CancellationError {
                return
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }.value
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
        analyzeMissing()
        installPendingComponents()
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
        analyzeMissing()
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
        g.analysis = nil                                    // another program: look at it again
        g.autoGraphics = nil                                // and what was learned was about the old one
        update(g)
        if let oldIcon { deleteIcon(oldIcon) }
        iconAttempts.remove(g.id)
        analysisAttempts.remove(g.id)
        diagnoses[g.id] = nil
        extractMissingIcons()
        analyzeMissing()
    }

    /// Started by G-Player and still open, or found running (Steam opened by a game, a game Steam started,
    /// anything still open from before G-Player was restarted).
    func isRunning(_ game: Game) -> Bool {
        running[game.id]?.isRunning == true || gamePrograms[game.id] != nil
    }

    // MARK: Programs running on the Mac

    /// The running Windows programs of each library entry, from the last look at the process table.
    private(set) var gamePrograms: [UUID: [WineProcess]] = [:]
    /// The settings each space's Steam was started with by G-Player, while that Steam runs.
    private var launcherSettings: [UUID: KnownLauncher] = [:]
    /// Store games until their program shows up (Steam takes a while to start a game), so Play isn't offered twice.
    private(set) var startingUntil: [UUID: Date] = [:]
    /// Store games G-Player started in the last minutes, and when each was first seen running: a game Steam starts
    /// writes no log G-Player can read, so coming and going within seconds is how it tells "closed right away".
    var storeLaunches: [UUID: Date] = [:]
    var firstSeen: [UUID: Date] = [:]
    /// Launches whose graphics Automatic picked and G-Player can learn from, until the game is gone. See `AppModel+Graphics`.
    var autoLaunches: [UUID: AutoLaunch] = [:]
    /// Launches that failed without a log saying why, while the failure is shown: the user may ask for other graphics.
    var failedAutoLaunches: [UUID: AutoLaunch] = [:]
    /// Games G-Player is starting again with other graphics, and the work of that.
    var retryTasks: [UUID: GraphicsRetryTask] = [:]
    /// Games whose automatic retries the user stopped, until the user starts them again.
    var stoppedRetries = Set<UUID>()
    /// Spaces where a retry is restarting Steam, and the game it is for: other launches through that Steam wait.
    var steamRestarts: [UUID: UUID] = [:]
    /// Spaces whose Steam G-Player is quitting.
    var closingSteam = Set<UUID>()
    /// The "picture missing" request waiting for the user's yes.
    var pendingOtherGraphics: OtherGraphicsRequest?
    /// Spaces whose launcher was just started: watched closely, as it may update itself and drop the helper wrapper.
    private var helperWatchUntil: [UUID: Date] = [:]
    /// When helpers running without the wrapper were first seen, per space.
    private var unwrappedSince: [UUID: Date] = [:]
    private var lookingAtPrograms = false
    /// Spaces being stopped because Wine ran away in them (`guardRunaways`), so the next look doesn't stop them twice.
    private var stoppingRunaways = Set<UUID>()
    /// A space is past half a runaway limit: the next looks come quickly.
    private var runawayLikely = false

    /// Looks at which programs run, off the main thread. A look already under way makes this a no-op.
    func refreshPrograms() {
        guard !lookingAtPrograms, !state.spaces.isEmpty else { return }
        lookingAtPrograms = true
        let entries = state.games.compactMap { g in space(g.spaceID).map { (game: g, space: $0) } }
        let looked = Date()
        Task {
            let (all, found) = await Task.detached(priority: .utility) { () -> ([WineProcess], [UUID: [WineProcess]]) in
                let all = WineProcesses.snapshot()
                return (all, RunningGames.programs(of: entries, in: all))
            }.value
            lookingAtPrograms = false
            if found != gamePrograms { gamePrograms = found }
            // A look made before a record, or that misses Steam once, doesn't erase it (`KnownLauncher.look`).
            for (id, var known) in launcherSettings {
                let steamRunning = space(id).map { WineProcesses.isSteamRunning(in: $0, processes: all) } ?? false
                launcherSettings[id] = known.look(steamRunning: steamRunning, at: looked) ? known : nil
            }
            if d3dMetalWaiting, !state.spaces.contains(where: { EngineCatalog.info($0.engineID)?.kind == .crossover
                                                              && WineProcesses.isRunning(in: $0, processes: all) }) {
                d3dMetalWaiting = false
                syncD3DMetal()
            }
            migrateEngines(processes: all)                      // a space that has just gone quiet can move to the new engine
            noticeStoreGames(found)
            noticeWorkingGames(found)
            guardHelperWrappers(all)
            guardRunaways(all, found: found)
        }
    }

    /// Wine that starts programs without end (a prefix whose path is too long does it: Explorer never comes up, and every
    /// program starts another one) would use up the Mac's processes. A space past the limits of `SpaceLoad` is stopped at
    /// once, and the user is told.
    private func guardRunaways(_ all: [WineProcess], found: [UUID: [WineProcess]]) {
        var likely = false
        for space in state.spaces where !stoppingRunaways.contains(space.id) {
            // Programs of the space's games count too, also those of a game kept outside the space's folder.
            let load = WineProcesses.load(of: space, from: all,
                                          alsoAttributed: state.games(in: space).flatMap { found[$0.id] ?? [] })
            likely = likely || load.isGrowing
            if load.isRunaway { stopRunaway(space, load) }
        }
        runawayLikely = likely
    }

    /// Kills what runs in the space, then asks its Wine server to quit. Signals first: with thousands of processes the Mac
    /// may refuse to start the `wineserver -k` that follows. What is left or comes back is killed again, up to five times.
    private func stopRunaway(_ space: Space, _ load: SpaceLoad) {
        stoppingRunaways.insert(space.id)
        errorMessage = load.message(spaceName: space.name)
        let games = state.games(in: space)
        for g in games { autoLaunches[g.id] = nil }                 // stopped on purpose: not a failure to learn from
        let engine = engineManager?.engine(id: space.engineID)      // also with Apple's toolkit off, as Stop All
        let entries = games.map { (game: $0, space: space) }
        Task.detached(priority: .userInitiated) {
            // Looked up again each time, so a pid reused since the look that found the runaway is never hit.
            func left() -> [WineProcess] {
                let all = WineProcesses.snapshot()
                let found = RunningGames.programs(of: entries, in: all)
                return WineProcesses.load(of: space, from: all, alsoAttributed: found.values.flatMap { $0 }).processes
                    .filter { $0.pid > 1 }
            }
            left().forEach { kill($0.pid, SIGKILL) }
            if let engine { await WineLauncher.killAll(engine: engine, space: space) }
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(500))
                let rest = left()
                if rest.isEmpty { break }
                rest.forEach { kill($0.pid, SIGKILL) }
            }
            await MainActor.run {
                self.stoppingRunaways.remove(space.id)
                for g in games { self.running[g.id] = nil }
                self.refreshPrograms()
            }
        }
    }

    /// Steam replaces its helper when it updates itself on start, and its window turns black again. While a launcher
    /// with Chromium helpers runs, the wrapper is put back as soon as it is gone; helpers that already started without
    /// it are stopped after 15 seconds if they haven't quit by themselves, and the launcher starts them again.
    private func guardHelperWrappers(_ all: [WineProcess]) {
        let now = Date()
        helperWatchUntil = helperWatchUntil.filter { $0.value > now }
        for space in state.spaces where space.mayChange {
            guard let helpers = AppPresets.preset(space.presetID)?.chromiumHelpers, !helpers.isEmpty else { continue }
            let mine = WineProcesses.programs(in: space, from: all)
            guard mine.contains(where: { !$0.isWineService }) else { unwrappedSince[space.id] = nil; continue }
            let stale = ChromiumHelperWrapper.unwrappedProcesses(helpers: helpers, in: mine)
            if stale.isEmpty { unwrappedSince[space.id] = nil } else if unwrappedSince[space.id] == nil { unwrappedSince[space.id] = now }
            let restart = unwrappedSince[space.id].map { now.timeIntervalSince($0) > 15 } ?? false
            if restart { unwrappedSince[space.id] = nil }
            Task.detached(priority: .utility) {
                _ = try? ChromiumHelperWrapper.apply(helpers: helpers, in: space)
                if restart { stale.forEach { kill($0.pid, SIGKILL) } }
            }
        }
    }

    /// Store games that closed within seconds, or never opened, get the same advice as a game whose log says nothing.
    private func noticeStoreGames(_ found: [UUID: [WineProcess]]) {
        let now = Date()
        for id in found.keys where firstSeen[id] == nil { firstSeen[id] = now }
        for (id, seen) in firstSeen where found[id] == nil {
            firstSeen[id] = nil
            settleIfWorked(id, since: seen, now: now)
            if let launched = storeLaunches.removeValue(forKey: id), now.timeIntervalSince(launched) < 300,
               now.timeIntervalSince(seen) < 45 {
                diagnoseStoreGame(id, seconds: now.timeIntervalSince(seen), opened: true, launched: launched)
            }
        }
        for (id, until) in startingUntil where until <= now && found[id] == nil && firstSeen[id] == nil {
            if let launched = storeLaunches.removeValue(forKey: id) { diagnoseStoreGame(id, seconds: 0, opened: false, launched: launched) }
        }
        let stillStarting = startingUntil.filter { $0.value > now && found[$0.key] == nil }
        if stillStarting != startingUntil { startingUntil = stillStarting }
        storeLaunches = storeLaunches.filter { now.timeIntervalSince($0.value) < 300 }
    }

    /// A store game that came and went (or never came). A Unity game's own log says why, when it wrote one.
    private func diagnoseStoreGame(_ id: UUID, seconds: Double, opened: Bool, launched: Date) {
        guard let game = game(id), let space = space(game.spaceID), let paths else { return }
        let profile = game.launchOptions.profile
        let auto = launchToJudge(id)
        let gameFolder = RunningGames.key(for: game, in: space).folder
        Task {
            let (installed, unityLog) = await Task.detached { () -> (Set<String>, String?) in
                // Only this game's own Player.log: another Unity game in the space writes one too.
                let log = LogDiagnosis.unityLog(in: space, gameFolder: gameFolder, since: launched.addingTimeInterval(-5))
                    .map { LogDiagnosis.tail(of: $0) }
                return (RuntimeInstaller(paths: paths).installed(in: space), log)
            }.value
            var found: [Diagnosis] = []
            if let unityLog {
                found = LogDiagnosis.diagnose(log: unityLog, exitStatus: 1, seconds: max(seconds, 1), profile: profile,
                                              installed: installed)
            }
            if found.isEmpty {
                var d = LogDiagnosis.closedRightAway(seconds: seconds, profile: profile, installed: installed)
                if !opened {
                    d = Diagnosis(kind: .closedRightAway, title: "The game didn't open",
                                  detail: "Steam started it, but no window came up within a minute. It may have closed right away.",
                                  remedy: d.remedy)
                }
                found = [d]
            }
            if let shown = learnFromEnd(found, ran: seconds, auto: auto, for: id) { report(shown, for: id) }
        }
    }

    /// Shows what went wrong with a launch the user just made: in the inspector, and in a dialog in front.
    func report(_ found: [Diagnosis], for id: UUID) {
        diagnoses[id] = found.isEmpty ? nil : found
        guard !found.isEmpty, found.contains(where: { $0.title != Self.componentsLaterTitle }) else { return }
        failedLaunch = id
        NSApp.activate()
    }

    /// Looks again every 4 seconds while G-Player is in front, every 20 seconds behind other windows.
    private func watchPrograms() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshPrograms()
                // Closely while a store game is starting, so one that closes within seconds is seen at all.
                let watching = !self.startingUntil.isEmpty || !self.firstSeen.isEmpty || !self.helperWatchUntil.isEmpty
                    || self.runawayLikely
                let seconds: Double = watching ? 1.5 : NSApp?.isActive == true ? 4 : 20
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    /// True from pressing Play until the program starts (for a store game, until it shows up or a minute passes).
    func isPreparing(_ game: Game) -> Bool {
        preparing.contains(game.id) || (startingUntil[game.id].map { $0 > Date() } ?? false)
    }

    /// Starting, but waiting for installs in the game's space to finish first.
    func isWaitingForInstalls(_ game: Game) -> Bool { preparing.contains(game.id) && installingSpaces.contains(game.spaceID) }

    /// Starts a game through the compatibility layers: analysis → known fixes → profile → components → registry → Wine.
    /// Does nothing while the game is already starting or running.
    func play(_ game: Game, skipping skipped: Set<PlayCheck> = []) {
        // A launcher that is open may be started again: that brings its window back.
        guard paths != nil, space(game.spaceID) != nil, !preparing.contains(game.id),
              !isRunning(game) || game.kind == .app else { return }
        preparing.insert(game.id)
        Task {
            await launch(game, skipping: skipped)
            preparing.remove(game.id)
        }
    }

    /// - Parameter retry: set when this is another try with other graphics (`AppModel+Graphics`). An automatic one never
    ///   asks or shows a dialog: a launch that would is not made.
    /// - Returns: true when the program was started. False when the launch needs the user's answer first (a dialog is
    ///   shown), was not made, or failed (the error is shown).
    @discardableResult
    func launch(_ game: Game, skipping skipped: Set<PlayCheck>, retry: GraphicsRetryLaunch? = nil) async -> Bool {
        // Until its program has started, the space's engine mustn't change under the launch (`migrateEngines`).
        let startingIn = game.spaceID
        launchesStarting[startingIn, default: 0] += 1
        defer { Self.decrement(&launchesStarting, startingIn) }
        guard let paths, let found = space(game.spaceID) else { return false }
        // A bottle of another app whose old engine is gone would meet the newer one on this start, which updates its files:
        // asked first. (An automatic retry never asks; it is not made.)
        let held = retry?.automatic == true
            ? EngineMigration.startNeedsConsent(found, installed: installedEngineIDs)
            : askBeforeNewEngine(for: found) { [weak self] in if let g = self?.game(game.id) { self?.play(g, skipping: skipped) } }
        if held { return false }
        guard let engine = await ensureEngine(EngineCatalog.info(found.engineID) ?? EngineCatalog.wineStaging) else { return false }
        // The space as it is now: the engine that was just installed may be the replacement of the one it was on, and then the
        // launch, and what it records, belong to the engine it runs on.
        let space = settleSpace(found, on: engine)
        // A restart of Steam made for this launch is over when it is.
        defer { if steamRestarts[space.id] == game.id { steamRestarts[space.id] = nil } }
        if retry?.automatic != true { stoppedRetries.remove(game.id) }
        do {
            var current = self.game(game.id) ?? game
            // Planned with what the retry will have learned; written to the game once the program has started.
            if let learned = retry?.learned { current.autoGraphics = learned }
            let startsSteam = space.presetID == AppPresets.steam.id && (current.kind == .app || current.storeKey != nil)
            if startsSteam, closingSteam.contains(space.id) || (steamRestarts[space.id].map { $0 != game.id } ?? false) {
                // A game started now would be handed to the Steam that is quitting.
                errorMessage = "Steam is restarting. Try again in a moment."
                return false
            }
            if current.kind == .game, needsAnalysis(current), let a = await analyze(current, force: true) { current.analysis = a }
            let fixes = current.kind == .game ? self.fixes(for: current) : []
            let planned = current, verbose = verboseLogs, ready = readyBackends(of: engine)
            var steamWasRunning = startsSteam ? await Self.isSteamRunning(in: space) : false
            let launcher = steamWasRunning ? launcherSettings[space.id]?.settings : nil
            // Planning reads the game's folder (program names, .NET), so it runs off the main thread.
            let plan = try await Task.detached(priority: .userInitiated) {
                try LaunchPlanner.plan(for: planned, in: space, fixes: fixes, verboseLogs: verbose, ready: ready,
                                       launcher: launcher)
            }.value
            if let blockers = plan.compat?.blockers, !blockers.isEmpty, !skipped.contains(.blockers),
               !acknowledgedBlockers.contains(game.id) {
                if retry?.automatic != true { blockedLaunch = BlockedLaunch(gameID: game.id, notes: blockers, skipped: skipped) }
                return false
            }
            if plan.needsFreshLauncher, !skipped.contains(.runningSteam), case .steam = current.source,
               await Self.isSteamRunning(in: space) {
                if retry != nil, mayRestartSteamSilently(for: current, in: space) {
                    // Another try with other graphics needs a Steam that starts with them: closed without asking, since
                    // nothing else is open in it. Stopped (or Steam not quitting) means no launch.
                    steamRestarts[space.id] = game.id
                    guard !retryStopped(retry, game.id), (await quitSteam(in: space)).gone, !retryStopped(retry, game.id) else {
                        if retry?.automatic != true, !retryStopped(retry, game.id) {
                            errorMessage = "Steam didn't quit. Quit it from its menu (Steam › Exit), then press Play again."
                        }
                        return false
                    }
                    steamWasRunning = false
                } else if retry?.automatic == true {
                    return false
                } else {
                    steamRestart = SteamRestart(gameID: game.id, skipped: skipped)
                    return false
                }
            }
            if plan.writesToSpace(engine: engine.info.limited(to: ready)), space.origin == .external,
               self.space(space.id)?.allowsChanges == nil {
                guard retry?.automatic != true else { return false }
                // Asked once per space; either answer starts the game.
                askToChange(space) { [weak self] _ in
                    if let g = self?.game(game.id) { self?.play(g, skipping: skipped) }
                }
                return false
            }
            if retryStopped(retry, game.id) { return false }
            diagnoses[game.id] = nil
            failedAutoLaunches[game.id] = nil
            // Waits for installs queued in the space before it, and starts the program in the same turn of the
            // queue, so an installer never runs next to it.
            let started = await enqueue(in: space.id, isInstall: false, holds: "“\(current.title)” to start") {
                await self.prepareAndStart(current, plan: plan, in: space, engine: engine, paths: paths, retry: retry)
            }.value
            let program = try started.get()
            // Steam started now runs with this launch's settings, and games it starts later inherit them.
            if startsSteam && !steamWasRunning { launcherSettings[space.id] = plan.launcherSettings.map { KnownLauncher(settings: $0) } }
            if launches[game.id]?.program.isRunning != true {
                launches[game.id] = LaunchRecord(program: program, profile: current.launchOptions.profile,
                                                 diagnose: current.kind == .game && current.storeKey == nil)
            }
            var isSteamGame = false
            if case .steam = current.source { isSteamGame = true }
            autoLaunches[game.id] = autoLaunch(for: current, in: space, backend: plan.backend, retried: retry != nil,
                                              steam: GraphicsRetry.steamAtLaunch(
                isSteamGame: isSteamGame, wasRunning: steamWasRunning, knownSettings: launcher,
                needsFreshLauncher: plan.needsFreshLauncher))
            // The game may have changed while Wine was starting (hidden, new icon), so write to the current one.
            if var latest = self.game(game.id) {
                latest.lastPlayedAt = Date()
                if let learned = retry?.learned, latest.graphicsAreAutomatic { latest.autoGraphics = learned }
                update(latest)
            }
            // A launcher started again hands over to the open one and quits; the open one stays the running one.
            if case .executable = game.source, running[game.id]?.isRunning != true { running[game.id] = program }
            // A program that died before it was recorded: its exit came first and found nothing to clear.
            if !program.isRunning { finished(game.id, status: program.process.terminationStatus) }
            // A store game starts through its launcher: "Starting…" until it shows up, and look for it soon.
            if !plan.chromiumHelpers.isEmpty { helperWatchUntil[space.id] = Date().addingTimeInterval(180) }
            if current.storeKey != nil && current.kind == .game {
                startingUntil[game.id] = Date().addingTimeInterval(60)
                storeLaunches[game.id] = Date()
                firstSeen[game.id] = nil
            }
            Task { try? await Task.sleep(for: .seconds(5)); refreshPrograms() }
            return true
        } catch is CancellationError {
            return false                                    // stopped while it waited: nothing was started
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Components, registry, Steam's wrapper and DXVK (only where G-Player may change the space), then Wine.
    /// Runs from the space's queue.
    private func prepareAndStart(_ game: Game, plan: LaunchPlan, in space: Space, engine: Engine,
                                 paths: LibraryPaths, retry: GraphicsRetryLaunch?) async -> Result<RunningProgram, Error> {
        // A try with other graphics that was stopped while it waited for the queue starts nothing.
        if retryStopped(retry, game.id) { return .failure(CancellationError()) }
        // Read now: the answer may have changed while this waited.
        if self.space(space.id)?.mayChange == true {
            let wanted = plan.components.filter { !(skippedComponents[space.id]?.contains($0) ?? false) }
            if !wanted.isEmpty {
                switch await installNow(wanted, in: space, engine: engine, reason: "for \(game.title)", retryFailed: false) {
                case .waiting:
                    diagnoses[game.id] = [Diagnosis(kind: .missingComponent, title: Self.componentsLaterTitle,
                        detail: "Another program is open in “\(space.name)”, so the game started without \(componentsLabel(wanted)). G-Player installs them once everything in the space has quit.",
                        remedy: .none)]
                case .cancelled:
                    skippedComponents[space.id, default: []].formUnion(wanted)
                case .done, .notAllowed:
                    break
                }
            }
            if !plan.registry.isEmpty { await applyRegistryNow(plan.registry, for: game.id, in: space, engine: engine) }
        }
        // Installing components and writing settings can take minutes: a Stop since then still prevents the start.
        if retryStopped(retry, game.id) { return .failure(CancellationError()) }
        let helpers = plan.chromiumHelpers, backend = plan.backend
        let allowed = self.space(space.id)?.mayChange == true
        let gameID = game.id, logName = game.title
        // The Steam helper wrapper and DXVK's files compare multi-MB files, so off the main thread.
        return await Task.detached(priority: .userInitiated) { () -> Result<RunningProgram, Error> in
            Result {
                if allowed {
                    if !helpers.isEmpty { _ = try ChromiumHelperWrapper.apply(helpers: helpers, in: space) }
                    try SpaceManager(paths: paths).prepareGraphics(backend, engine: engine, space: space)
                }
                return try WineLauncher.start(
                    engine: engine, space: space, arguments: plan.arguments, workingDirectory: plan.workingDirectory,
                    backend: backend, tweaks: plan.tweaks, logsFolder: paths.logs, logName: logName
                ) { [weak self] status in
                    Task { @MainActor in self?.finished(gameID, status: status) }
                }
            }
        }.value
    }

    static let componentsLaterTitle = "Components install later"

    /// A program of the game quit. A second copy of a launcher that handed over to the open one leaves it running.
    private func finished(_ gameID: UUID, status: Int32) {
        if let program = running[gameID], !program.isRunning {
            running[gameID] = nil
            if var g = game(gameID) { g.secondsPlayed += Date().timeIntervalSince(program.startedAt); update(g) }
        }
        if let record = launches[gameID], !record.program.isRunning, record.diagnose {
            launches[gameID] = nil
            let seconds = Date().timeIntervalSince(record.program.startedAt)
            let log = record.program.logFile
            let profile = record.profile
            let paths = self.paths
            let gameSpace = game(gameID).flatMap { self.space($0.spaceID) }
            let auto = launchToJudge(gameID)
            Task.detached(priority: .utility) {
                var installed: Set<String> = []
                if let paths, let gameSpace { installed = RuntimeInstaller(paths: paths).installed(in: gameSpace) }
                let found = LogDiagnosis.diagnose(log: LogDiagnosis.tail(of: log), exitStatus: status,
                                                  seconds: seconds, profile: profile, installed: installed)
                await MainActor.run {
                    if let shown = self.learnFromEnd(found, ran: seconds, auto: auto, for: gameID) { self.report(shown, for: gameID) }
                }
            }
        }
        if launches[gameID]?.program.isRunning == false { launches[gameID] = nil }
        componentsVersion += 1                              // the space may be free for installs now
        refreshStores()
        refreshPrograms()
    }

    /// Stops a game. A Steam game is stopped on its own, so Steam stays open; anything else stops everything in its
    /// space, as the games' own helpers (launchers, crash reporters) may have other names.
    func stop(_ game: Game) {
        guard let space = space(game.spaceID) else { return }
        // Stop also ends the tries with other graphics. One that hasn't started the game yet is all there is to stop then.
        let tryingNow = retryTasks[game.id] != nil
        if isRetrying(game) { cancelRetry(game.id) }
        autoLaunches[game.id] = nil                         // stopped on purpose: not a failure to learn from
        if tryingNow && !isRunning(game) { return }
        running[game.id]?.terminate()
        startingUntil[game.id] = nil
        if case .steam = game.source {
            stopPrograms(of: game, in: space)
        } else {
            stopAll(in: space)
        }
        Task { try? await Task.sleep(for: .seconds(1)); refreshPrograms() }
    }

    /// What Stop does for this entry, for its tooltip.
    func stopHelp(_ game: Game) -> String {
        if case .steam = game.source, game.kind == .game { return "Quits the game. Steam stays open." }
        return "Quits everything running in “\(space(game.spaceID)?.name ?? "its space")”."
    }

    /// Stops one game's programs and nothing else in the space. The programs are looked up again first, so a pid
    /// reused since the last look is never hit; whatever hasn't quit after five seconds is killed.
    func stopPrograms(of game: Game, in space: Space) {
        let key = RunningGames.key(for: game, in: space)
        Task.detached(priority: .userInitiated) {
            func current() -> [WineProcess] {
                WineProcesses.programs(ofGameIn: key.folder, programName: key.programName, space: space,
                                       from: WineProcesses.snapshot())
            }
            let first = current()
            first.forEach { kill($0.pid, SIGTERM) }
            guard !first.isEmpty else { return }
            try? await Task.sleep(for: .seconds(5))
            let left = Set(first)
            for p in current() where left.contains(p) { kill(p.pid, SIGKILL) }
        }
    }

    /// Runs any Windows program in a space without adding it to the library.
    func run(_ file: URL, in space: Space) {
        guard let paths else { return }
        if askBeforeNewEngine(for: space, then: { [weak self] in self?.run(file, in: space) }) { return }
        Task {
            var found = engine(for: space)
            if found == nil { found = await ensureEngine(EngineCatalog.info(space.engineID) ?? .wineStaging) }
            guard let engine = found else { return }
            // Starts after the installs queued in the space, as a launch does: an installer started next to Windows components
            // being installed fails (error 1618, another installation is in progress).
            let verbose = verboseLogs
            let started = await enqueue(in: space.id, isInstall: false, holds: "\(file.lastPathComponent) to start") { () -> Result<RunningProgram, Error> in
                Result {
                    try WineLauncher.start(engine: engine, space: space, arguments: WineLauncher.arguments(toOpen: file),
                                           workingDirectory: file.deletingLastPathComponent(), backend: .auto,
                                           tweaks: LaunchTweaks(verboseLogs: verbose),
                                           logsFolder: paths.logs, logName: file.deletingPathExtension().lastPathComponent)
                }
            }.value
            if case .failure(let error) = started { errorMessage = error.localizedDescription }
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

/// `AppModel.engineInfo`'s memory: per engine id, its ready backends (nil while it isn't installed).
final class ReadyCache {
    var version = -1
    var toolkitOn = false
    var backends: [String: [GraphicsBackend]?] = [:]
}

