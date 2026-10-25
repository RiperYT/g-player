import AppKit
import Foundation
import GPlayerCore

/// A one-time note at the top of the library.
enum LibraryNote: Identifiable, Equatable {
    /// Someone who updated: G-Player Wine is new, and their spaces keep what they have.
    case gplayerWine
    /// A store app was just set up (its name): what to do next.
    case storeReady(String)
    /// The first run waits because the user stopped a download (the first spaces still to make, as `FirstRunSetup` names them).
    case setupOnHold([String])
    /// Wine Mono (.NET) isn't in this space, and why (`AppModel.wineMonoNotes`): the launcher is open, the Mac is offline.
    case wineMono(UUID)

    var id: String {
        switch self {
        case .gplayerWine: "gplayer-wine"
        case .storeReady(let name): "ready-\(name)"
        case .setupOnHold: "setup-on-hold"
        case .wineMono(let space): "wine-mono-\(space.uuidString)"
        }
    }
}

/// What a newcomer needs to understand while the first run works and after it: the setup the library waits for, the notes
/// that say what to do next, and the spaces already on this Mac.
extension AppModel {
    // MARK: Setup in progress

    /// What the first run is doing while the library waits for it (`FirstRunSetup.libraryStatus`), or nil when it isn't
    /// working. An engine download counts as the first run's when it is, or when the first spaces wait for it.
    var firstRunStatus: String? {
        guard !firstRunPaused else { return nil }                    // on hold: the library says so in a note, not "getting ready"
        let downloading = EngineCatalog.firstRunInstalls.contains { download(of: $0) != nil }
        return FirstRunSetup.libraryStatus(installed: installedEngines,
                                           downloading: isInstallingFirstRun || (downloading && !firstRunSpaces.isEmpty),
                                           pendingSpaces: firstRunSpaces)
    }

    /// Adding a game waits for the first run: it needs the engine and Main to be there.
    var isSettingUp: Bool { firstRunStatus != nil }

    /// Why Add Game can't open now.
    enum AddGameBlock {
        /// No library to add to: onboarding isn't done, or the library can't be read (its screen is up).
        case noLibrary
        /// The first run is still working.
        case settingUp

        var message: String? {
            self == .settingUp ? String(localized: "G-Player is still setting up. You can add a game when that's done.") : nil
        }
    }

    var addGameBlock: AddGameBlock? {
        if !onboardingDone || libraryRoot == nil || libraryProblem != nil { return .noLibrary }
        return isSettingUp ? .settingUp : nil
    }

    /// Opens Add Game, with `source` when something was dropped or opened. Every way to add a game comes here: the buttons, ⌘N,
    /// drops on the library, the Dock icon and Open With. Nothing opens while the first run works or the library can't be
    /// read. `explains`: the user didn't press one of the buttons, which are dimmed and say why, so say it.
    func openAddGame(_ source: ImportSource? = nil, explains: Bool = false) {
        switch addGameBlock {
        case nil:
            addGameSource = source
            showAddGame = true
        case .settingUp?:
            if explains { errorMessage = AddGameBlock.settingUp.message }
        case .noLibrary?:
            break
        }
    }

    /// The work to show a progress bar for while the first run goes on: the engine download, then the first space.
    var firstRunActivity: Activity? { activities.first }

    // MARK: Notes

    /// The notes to show at the top of All Games, in order.
    var libraryNotes: [LibraryNote] {
        var notes: [LibraryNote] = []
        if firstRunPaused, !firstRunSpaces.isEmpty, !pausedNoteClosed { notes.append(.setupOnHold(firstRunSpaces)) }
        if FirstRunSetup.upgradeNoteApplies(spaces: spaces, seen: engineNoteSeen) { notes.append(.gplayerWine) }
        // What an Epic launcher that is open, or a Mac that is offline, left undone: said where its tile is.
        for space in spaces where wineMonoNotes[space.id] != nil { notes.append(.wineMono(space.id)) }
        // Until the store has been opened once: after that its games are in the library and the note has done its job.
        if let id = storeReadyID, let preset = AppPresets.preset(id), let launcher = launcherTile(of: preset),
           launcher.lastPlayedAt == nil {
            notes.append(.storeReady(preset.name))
        }
        return notes
    }

    func close(_ note: LibraryNote) {
        switch note {
        case .gplayerWine: engineNoteSeen = true
        case .storeReady: storeReadyID = nil
        case .setupOnHold: pausedNoteClosed = true
        case .wineMono(let space): closeWineMonoNote(space)
        }
    }

    private func launcherTile(of preset: AppPreset) -> Game? {
        presetSpace(preset).flatMap { space in state.games.first { $0.spaceID == space.id && $0.kind == .app } }
    }

    /// A store app finished setting up: its tile is selected and the library says what to do next. Someone looking at
    /// another game isn't taken away from it; the note waits in All Games.
    func noteStoreReady(_ preset: AppPreset, in space: Space) {
        guard preset.id == AppPresets.steam.id, let tile = launcherTile(of: preset) else { return }
        storeReadyID = preset.id
        let place: StoreReadyMove.Place
        switch selection {
        case .apps?: place = appsPath.isEmpty ? .getApps : .getAppsPage
        case .space(space.id)?: place = .storeSpace
        case .allGames?, nil: place = .allGames(gameSelected: selectedGameID != nil)
        default: place = .elsewhere
        }
        guard StoreReadyMove.movesToTile(from: place) else { return }
        selection = .allGames
        selectedGameID = tile.id
    }

    // MARK: Spaces already on this Mac

    /// CrossOver and Whisky bottles and Wine prefixes that aren't spaces yet, found off the main thread.
    func findExistingEnvironments() async -> [FoundEnvironment] {
        let known = spaces.map(\.url) + (libraryRoot.map { [$0] } ?? [])
        let toolkit = engineManager?.isInstalled(EngineCatalog.gptk) ?? false, installed = installedEngines
        return await Task.detached { EnvironmentFinder.find(excluding: known, gptkInstalled: toolkit, installed: installed) }.value
    }

    // MARK: Logs

    /// Opens the newest log of the game's launches, or the Logs folder when there is none (a store starts its own games,
    /// and they write no log G-Player keeps).
    func showLog(for game: Game) {
        guard let logs = paths?.logs else { return }
        let prefix = Files.safeName(game.title) + " "
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix(prefix) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
        NSWorkspace.shared.open(newest ?? logs)
    }
}
