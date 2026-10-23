import AppKit
import Foundation
import GPlayerCore

/// What the app knows about Epic Games through Legendary.
struct EpicState: Equatable {
    /// The signed-in account's name, nil when nobody is (or it isn't known yet: `looked`).
    var account: String?
    /// Legendary has been asked who is signed in, so a missing account means "signed out" and not "not looked yet".
    var looked = false
    /// The games the account owns, as Epic last said (kept on disk).
    var games: [EpicGame] = []
    /// What Legendary has installed, by its name for the game.
    var installed: [String: LegendaryInstalledGame] = [:]
    /// What Legendary is busy with ("Installing “Sample Game”"). It does one thing at a time: it locks what it installs.
    var busy: String?
    /// The name of the game being installed, while one is.
    var installing: String?
    /// The name of the game being uninstalled, while one is.
    var uninstalling: String?
    /// The list of games is being fetched from Epic.
    var refreshing = false
    /// Epic has been asked for the list in this run (what is shown before is the one kept on disk).
    var fetched = false
    /// Legendary's list of installed games has been read in this run (`installed` is what it said).
    var installedKnown = false
    /// Why the last fetch of the list failed, for the page.
    var refreshFailure: String?
    var showSignIn = false

    var isSignedIn: Bool { account != nil }
    /// A new install, sign-in or fetch has to wait.
    var isOccupied: Bool { busy != nil || refreshing }
    /// What Legendary is doing, in words, when it is doing anything.
    var activity: String? { busy ?? (refreshing ? "getting your games" : nil) }
}

/// Plans a launch again with Legendary's parameters (`LaunchPlanner.plan(legendary:)`), right before it starts.
typealias EpicReplan = @Sendable (LegendaryLaunch) throws -> LaunchPlan

/// Epic Games without Epic's launcher: signing in, the list of games, installing, launching, uninstalling. Legendary does the
/// work (`Legendary`); what the user sees and which space it all lives in is decided here and in `EpicGames`.
extension AppModel {
    // MARK: What is on this Mac

    /// The list of games from the last time. Nothing is started: each Legendary command takes seconds, so who is signed in and
    /// what is installed are looked at when the Epic Games page opens (`openEpicPage`) or something changes them.
    func loadEpic() {
        guard let paths else { return }
        Legendary(paths: paths).endLeftovers()          // one a G-Player that crashed left running would hold Legendary's lock
        epic.games = EpicGames.loadList(in: paths)
        fetchMissingCovers()
        // Only a library with an Epic game in it has anything that can be out of date (Legendary's record of where it is).
        if state.games.contains(where: { $0.legendaryAppName != nil }) { lookAtEpicIfNeeded() }
    }

    /// Looks once per run at what Legendary has, when nothing has yet.
    func lookAtEpicIfNeeded() { if !epic.looked { lookAtEpic() } }

    /// Asks Legendary who is signed in and which games it has installed (from what is on this Mac: no Epic account is asked,
    /// no network used) once the look before it is over, and brings the library's Epic games in line.
    func lookAtEpic() {
        let before = epicLooking
        epicLooking = Task {
            await before?.value
            await lookAtEpicNow()
        }
    }

    private func lookAtEpicNow() async {
        guard let paths else { return }
        let legendary = Legendary(paths: paths)
        guard legendary.isDownloaded else { epic.looked = true; return }
        do {
            try await legendary.ensureInstalled()                         // the file is checked, and fetched again if it isn't the pinned one
            let status = try await legendary.status()
            let installed = try await legendary.installedGames()
            epic.account = status.account
            epic.installed = Dictionary(installed.map { ($0.appName, $0) }, uniquingKeysWith: { first, _ in first })
            epic.installedKnown = true
            mergeEpicGames(installed)
        } catch {
            // A look that fails says nothing; what the user asks for next says why it can't be done.
        }
        epic.looked = true
    }

    private func mergeEpicGames(_ installed: [LegendaryInstalledGame]) {
        guard let space = EpicGames.space(in: spaces) else { return }
        let merged = EpicGames.merge(existing: state.games, installed: installed, space: space)
        guard merged.changed else { return }
        // A library with an Epic game in it can't be read by a G-Player from before Epic Games: the file as it is is kept first,
        // and without that copy no game is added.
        if EpicGames.addsGames(merged.games, to: state.games), let paths {
            do { try LibraryStore(paths: paths).keepBeforeEpic() }
            catch {
                if !epicBackupWarned {
                    epicBackupWarned = true
                    errorMessage = "G-Player couldn't keep a copy of library.json before adding your first Epic game, so your Epic games aren't in the library yet. \(error.localizedDescription)"
                }
                return
            }
        }
        mutate { $0.games = merged.games }
        fetchMissingCovers()
        analyzeMissing()
        refreshPrograms()
    }

    /// The Epic Games page opened: look once per run (signing in, installing and uninstalling keep what it shows up to date, and
    /// Refresh looks again), and ask Epic for the list once per run. Not tied to the page: leaving it doesn't stop Legendary
    /// halfway through the list.
    func openEpicPage() {
        lookAtEpicIfNeeded()
        Task {
            await epicLooking?.value
            if epic.isSignedIn, !epic.fetched { await refreshEpicList() }
        }
    }

    /// Refresh: what is on this Mac, and the list from Epic.
    func refreshEpic() async {
        lookAtEpic()
        await epicLooking?.value
        await refreshEpicList()
    }

    /// Asks Epic for the games the account owns. Needs the network.
    func refreshEpicList() async {
        guard let paths, epic.isSignedIn, !epic.isOccupied else { return }
        epic.refreshing = true
        epic.refreshFailure = nil
        defer { epic.refreshing = false }
        do {
            let legendary = Legendary(paths: paths)
            try await legendary.ensureInstalled()
            let games = try await legendary.library()
            epic.games = games
            epic.fetched = true
            try? EpicGames.saveList(games, in: paths)
            fetchMissingCovers()
        } catch is CancellationError {
            return
        } catch {
            epic.refreshFailure = error.localizedDescription
        }
    }

    // MARK: Legendary itself

    /// Makes sure the pinned Legendary is on this Mac. The first time it downloads (15 MB, from its GitHub release), with an
    /// entry in the sidebar that can be stopped. False when it couldn't be had or the user stopped it (the error is shown).
    private func prepareLegendary(_ legendary: Legendary) async -> Bool {
        guard !legendary.isDownloaded else {
            do { try await legendary.ensureInstalled(); return true }               // checks the file quietly
            catch { errorMessage = "Couldn't get Legendary: \(error.localizedDescription)"; return false }
        }
        let activity = begin("Getting Legendary", "Downloading about 15 MB", progress: 0)
        defer { end(activity); cancellers[activity] = nil }
        let work = Task {
            try await legendary.ensureInstalled { [weak self] fraction in
                Task { @MainActor in self?.progress(activity, fraction, "Downloading about 15 MB") }
            }
        }
        setStop(activity, help: "Stop downloading Legendary.") { work.cancel() }
        do { try await work.value; return true }
        catch is CancellationError { return false }
        catch { errorMessage = "Couldn't get Legendary: \(error.localizedDescription)"; return false }
    }

    // MARK: Signing in and out

    /// Gets Legendary (the first time) and opens the sign-in sheet.
    func beginEpicSignIn() {
        guard let paths, !epic.isOccupied else { return }
        epic.busy = "Getting Legendary"
        Task {
            defer { epic.busy = nil }
            if await prepareLegendary(Legendary(paths: paths)) { epic.showSignIn = true }
        }
    }

    /// The sheet has Epic's code: it closes, and Legendary signs in with it.
    func finishEpicSignIn(code: String) {
        epic.showSignIn = false
        guard let paths, epic.busy == nil else { return }
        Task {
            guard await signInToEpic(code: code, paths: paths) else { return }
            lookAtEpic()
            await refreshEpicList()
        }
    }

    private func signInToEpic(code: String, paths: LibraryPaths) async -> Bool {
        epic.busy = "Signing in"
        let activity = begin("Signing in to Epic Games", "Checking with Epic")
        defer { end(activity); epic.busy = nil }
        do {
            let legendary = Legendary(paths: paths)
            try await legendary.ensureInstalled()
            let status = try await legendary.signIn(code: code)
            epic.account = status.account
            epic.looked = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Forgets the login on this Mac and the list of games. The games stay installed, and need a sign-in to start.
    func signOutOfEpic() {
        guard let paths, !epic.isOccupied else { return }
        epic.busy = "Signing out"
        Task {
            defer { epic.busy = nil }
            do {
                let legendary = Legendary(paths: paths)
                try await legendary.ensureInstalled()
                try await legendary.signOut()
                epic.account = nil
                epic.games = []
                epic.refreshFailure = nil
                epic.fetched = false
                EpicGames.forgetList(in: paths)
            } catch {
                errorMessage = "Couldn't sign out: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Install and uninstall

    /// Installs a game into the Epic Games space (made on G-Player Wine the first time), with progress in the sidebar and a Stop
    /// that goes on from where it stopped next time. One at a time.
    func installEpicGame(_ game: EpicGame) {
        guard let paths, epic.isSignedIn, !epic.isOccupied else { return }
        epic.busy = "Installing “\(game.title)”"
        epic.installing = game.appName
        Task {
            defer { epic.busy = nil; epic.installing = nil }
            await installEpic(game, paths: paths)
        }
    }

    private func installEpic(_ game: EpicGame, paths: LibraryPaths) async {
        let legendary = Legendary(paths: paths)
        guard await prepareLegendary(legendary) else { return }
        var home = EpicGames.space(in: spaces)
        if home == nil { home = await createSpace(name: EpicGames.spaceName, presetID: EpicGames.presetID) }
        guard let home else { return }
        let base = EpicGames.installBase(in: home)
        let title = game.title, appName = game.appName
        let activity = begin("Installing “\(title)”", "Preparing", setup: true)
        defer { end(activity); cancellers[activity] = nil }
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let log = paths.logs.appendingPathComponent("Epic install \(Files.safeName(title)) \(stamp).log")
        let work = Task.detached {
            try await legendary.install(appName, basePath: base, log: log,
                                        hasRoom: { DiskSpace.problem(needing: $0, available: DiskSpace.available(at: base), for: "It") },
                                        status: { [weak self] status in
                Task { @MainActor in self?.progress(activity, status.fraction, status.message) }
            })
        }
        setStop(activity, help: "Stop installing. It goes on from where it stopped the next time.") { work.cancel() }
        do { try await work.value }
        catch is CancellationError { }                                           // stopped: what came stays for next time
        catch { errorMessage = "Couldn't install “\(title)”. \(error.localizedDescription)" }
        lookAtEpic()
        await epicLooking?.value
    }

    /// Removes an Epic game and its files, after the user said so. It leaves the library's list once Legendary no longer lists it.
    func uninstallEpicGame(_ game: Game) {
        guard case .legendary(let appName) = game.source, let paths else { return }
        if let reason = epicUninstallBlock(for: game) { errorMessage = "Can't uninstall “\(game.title)” now. \(reason)"; return }
        epic.busy = "Uninstalling “\(game.title)”"
        epic.uninstalling = appName
        let folder = epic.installed[appName]?.folder
        Task {
            defer { epic.busy = nil; epic.uninstalling = nil }
            let legendary = Legendary(paths: paths)
            guard await prepareLegendary(legendary) else { return }
            let activity = begin("Uninstalling “\(game.title)”", "Removing its files")
            defer { end(activity) }
            do { try await legendary.uninstall(appName); dropEpicEntry(game) }
            catch { errorMessage = "Couldn't uninstall “\(game.title)”. \(error.localizedDescription)" }
            lookAtEpic()
            await epicLooking?.value
            if let folder, !epic.installed.keys.contains(appName), FileManager.default.fileExists(atPath: folder.path) {
                errorMessage = "“\(game.title)” is uninstalled, but some of its files are still in \(folder.path). You can delete that folder."
            }
        }
    }

    // MARK: Starting a game

    /// Asks Legendary how to start the game, right now, and plans the launch with its answer. The answer holds a one-time code
    /// Epic gives the game to log in with, so this comes as late as possible and the game starts at once; the code is in no log
    /// and no message (`LaunchSecrets`). Online when Epic answers, offline when it can't be reached.
    func epicPlan(_ replan: @escaping EpicReplan, appName: String, engine: Engine, paths: LibraryPaths) async throws -> LaunchPlan {
        let legendary = Legendary(paths: paths)
        try await legendary.ensureInstalled()
        let answer = try await legendary.launchParameters(for: appName, wine: engine.wine)
        return try await Task.detached(priority: .userInitiated) { try replan(answer.launch) }.value
    }
}

extension AppModel {
    /// The library entry of an owned game that is installed, or nil.
    func epicGame(for game: EpicGame) -> Game? {
        let source = Game.Source.legendary(appName: game.appName)
        return state.games.first { $0.source == source }
    }
}

extension AppModel {
    /// Why an Epic game can't be uninstalled now (the buttons' help), or nil.
    func epicUninstallBlock(for game: Game) -> String? {
        EpicGames.uninstallBlock(gameIsRunning: isRunning(game), gameIsStarting: isPreparing(game), busy: epic.activity)
    }

    /// Why an Epic game can't be started now, or nil: it is being uninstalled, or its files aren't where Legendary says.
    func epicPlayBlock(for game: Game) -> String? {
        guard case .legendary(let appName) = game.source else { return nil }
        if let reason = EpicGames.playBlock(appName: appName, uninstalling: epic.uninstalling) { return reason }
        return epicNote(for: game)?.detail
    }

    /// How an Epic game stands with Legendary's record, once its list has been read this run.
    func epicHealth(of game: Game) -> EpicGames.Health {
        guard case .legendary(let appName) = game.source, let space = space(game.spaceID) else { return .ok }
        return EpicGames.health(record: epic.installed[appName], recordsKnown: epic.installedKnown, space: space)
    }

    /// What to say about an Epic game whose files aren't where Legendary says, or nil.
    func epicNote(for game: Game) -> EpicGames.Note? { EpicGames.note(for: epicHealth(of: game), title: game.title) }

    /// Takes an Epic game out of the library: once Legendary has uninstalled it or forgotten it.
    func dropEpicEntry(_ game: Game) {
        mutate { $0.games = EpicGames.removing(appName: game.legendaryAppName ?? "", of: game.spaceID, from: $0.games) }
        if selectedGameID == game.id { selectedGameID = nil }
    }

    /// Repair: points Legendary's record at the files, which are in this library's Epic Games space.
    func repairEpicGame(_ game: Game) {
        guard let appName = game.legendaryAppName, let paths, !epic.isOccupied,
              case .filesNotFound(let base?) = epicHealth(of: game) else { return }
        epic.busy = "Repairing “\(game.title)”"
        Task {
            defer { epic.busy = nil }
            let legendary = Legendary(paths: paths)
            do {
                try await legendary.ensureInstalled()
                try await legendary.relink(appName, to: base)
            } catch {
                errorMessage = "Couldn't repair “\(game.title)”. \(error.localizedDescription)"
            }
            lookAtEpic()
            await epicLooking?.value
        }
    }

    /// Remove…, for a game that can't be started: Legendary forgets it (no file is touched) and it leaves the library.
    func forgetEpicGame(_ game: Game) {
        guard let appName = game.legendaryAppName, let paths, !epic.isOccupied, epicHealth(of: game) != .ok else { return }
        epic.busy = "Removing “\(game.title)”"
        Task {
            defer { epic.busy = nil }
            let legendary = Legendary(paths: paths)
            do {
                try await legendary.ensureInstalled()
                try await legendary.uninstall(appName, keepFiles: true)
                dropEpicEntry(game)
            } catch {
                errorMessage = "Couldn't remove “\(game.title)”. \(error.localizedDescription)"
            }
            lookAtEpic()
        }
    }
}
