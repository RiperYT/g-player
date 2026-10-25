import Foundation
import GPlayerCore

/// How an install of Windows components ended.
enum ComponentInstall {
    /// Installed, or there was nothing to install. Failures are shown and remembered by the installer.
    case done
    /// Something runs in the space, so the components wait for it to quit.
    case waiting
    /// The user stopped it.
    case cancelled
    /// An external space the user hasn't let G-Player change.
    case notAllowed
}

/// How closing Steam ended.
enum SteamQuit {
    /// Steam didn't quit in time.
    case failed
    /// Steam quit, and the rest of its space (its web helpers, Wine's services) with it.
    case spaceEmpty
    /// Steam quit, but something else keeps the space open.
    case spaceBusy

    var gone: Bool { self != .failed }
}

/// Checks a launch can skip because the user already answered them.
enum PlayCheck: Hashable {
    /// "Play Anyway" despite anti-cheat or a known failure.
    case blockers
    /// Play with the Steam that is already running, without this game's settings.
    case runningSteam
}

/// Steam is open and the game's settings only reach it through a fresh Steam.
struct SteamRestart: Identifiable {
    var id: UUID { gameID }
    let gameID: UUID
    let skipped: Set<PlayCheck>
}

/// Components the user asked for, waiting for Steam to be closed so they can install.
struct LauncherQuit: Identifiable {
    var id: UUID { gameID }
    let gameID: UUID
    let components: [String]
}

/// An external space G-Player wants to change, waiting for the user's answer.
struct ChangesRequest: Identifiable {
    let id = UUID()
    let spaceID: UUID
    /// Run after the answer is saved, with the answer: everything that waited for this space.
    var then: [@MainActor (Bool) -> Void]
}

/// The compatibility layers, as the app uses them.
extension AppModel {
    /// The program that really starts a game: its own .exe, or for a Steam game the best guess in its folder.
    /// Reads the disk, so it runs off the main thread.
    nonisolated static func mainExecutable(of game: Game, in space: Space) -> URL? {
        switch game.source {
        case .executable, .legendary: return game.executableURL(in: space)
        case .steam(let id):
            guard let folder = SteamLibrary.installFolder(appID: id, in: space) else { return nil }
            return ExecutableScanner.scan(folder, title: game.title, maxDepth: 4).first { $0.score > -40 }?.url
        case .epic: return nil
        }
    }

    /// The file name of the program a game starts, without reading the disk: its own .exe, or the one the analysis
    /// looked at.
    func programName(of game: Game) -> String? {
        if game.source.startsProgramItself, let path = game.executablePath, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        return game.analysis?.programPath.map { ($0 as NSString).lastPathComponent }
    }

    /// True when the game has no analysis yet, or one from an older analyzer.
    func needsAnalysis(_ game: Game) -> Bool {
        guard let a = game.analysis else { return true }
        return (a.version ?? 0) < GameAnalysis.currentVersion
    }

    /// Works out what a game is (engine, DirectX, anti-cheat) off the main thread and caches it on the game.
    @discardableResult
    func analyze(_ game: Game, force: Bool = false) async -> GameAnalysis? {
        if !force, let a = game.analysis, !needsAnalysis(game) { return a }
        guard let space = space(game.spaceID) else { return nil }
        let found = await Task.detached(priority: .userInitiated) { () -> GameAnalysis? in
            guard let exe = AppModel.mainExecutable(of: game, in: space) else { return nil }
            return GameAnalyzer.analyze(executable: exe)
        }.value
        guard let found else { return nil }
        // Only if the game still starts the program that was looked at (it may have been changed meanwhile).
        guard var g = self.game(game.id), g.executablePath == game.executablePath else { return nil }
        g.analysis = found
        update(g)
        return found
    }

    /// Analyses games that have none yet (or an outdated one) in the background, once per game per run.
    func analyzeMissing() {
        for game in games where game.kind == .game && needsAnalysis(game) && !analysisAttempts.contains(game.id) {
            analysisAttempts.insert(game.id)
            Task { await self.analyze(game, force: true) }
        }
    }

    func fixes(for game: Game) -> [GameFix] {
        var steamID: String?
        if case .steam(let id) = game.source { steamID = id }
        return GameFixDatabase.bundled.fixes(steamAppID: steamID, exeName: programName(of: game))
    }

    /// What the layers would do for this game right now, for the inspector. No file writes; the engine's ready backends
    /// are read from disk once per change of engines (`engineInfo`).
    func compatPreview(for game: Game) -> CompatPlan? {
        guard game.kind == .game, let space = space(game.spaceID) else { return nil }
        return CompatResolver.resolve(compatInput(for: game, in: space))
    }

    func compatInput(for game: Game, in space: Space) -> CompatResolver.Input {
        .init(engine: engineInfo(for: space), analysis: game.analysis, fixes: fixes(for: game),
              options: game.launchOptions, userBackend: game.graphics, isStoreGame: game.storeKey != nil,
              programNames: programName(of: game).map { [$0] } ?? [], autoGraphics: game.autoGraphics)
    }

    func setOptions(_ options: LaunchOptions, for game: Game) {
        guard var g = self.game(game.id) else { return }
        // Another profile is another way to run the game: what was learned under the old one no longer applies.
        if options.profile != g.launchOptions.profile { g.autoGraphics = nil }
        g.options = options
        update(g)
        diagnoses[game.id] = nil
    }

    /// Graphics chosen by hand. For a game that also switches the profile to Custom, so the choice is used.
    func setGraphics(_ backend: GraphicsBackend, for game: Game) {
        guard var g = self.game(game.id) else { return }
        g.graphics = backend
        g.autoGraphics = nil                                // a choice made by hand ends what Automatic learned
        if g.kind == .game { var o = g.launchOptions; o.profile = .custom; g.options = o }
        update(g)
    }

    /// The button on a diagnosis: install what was missing, or switch profile, then play again.
    func applyRemedy(_ remedy: Diagnosis.Remedy, for game: Game) {
        switch remedy {
        case .installComponents(let ids):
            guard let space = space(game.spaceID) else { return }
            let install = {
                Task {
                    // Installers need the space to themselves. When it's only Steam, offer to close it for a minute.
                    if await Self.isBusy(space), await Self.isSteamRunning(in: space) {
                        self.launcherQuit = LauncherQuit(gameID: game.id, components: ids)
                        return
                    }
                    await self.installThenPlay(ids, game: game, in: space)
                }
            }
            // Pressing the button in a space G-Player may not change asks again, even after an earlier "Don't Allow".
            if space.mayChange { _ = install() } else { askToChange(space) { allowed in if allowed { _ = install() } } }
        case .useProfile(let p):
            var o = game.launchOptions; o.profile = p
            setOptions(o, for: game)
            if let g = self.game(game.id) { play(g) }
        case .none:
            break
        }
    }

    /// "Visual C++ 2015–2022 (40 MB)", "DirectX 9 helpers and XACT audio (100 MB)": names from the catalog, and
    /// their download size when every one is known (the DirectX components share one download, counted once).
    func componentsLabel(_ ids: [String]) -> String {
        let canonical = ids.map(RuntimeCatalog.canonicalID)
        let list = CompatResolver.list(canonical.map(RuntimeCatalog.plainName))
        let sizes = canonical.map { RuntimeCatalog.component($0)?.approximateBytes }
        guard !sizes.isEmpty, !sizes.contains(nil) else { return list }
        return "\(list) (\(Set(sizes.compactMap { $0 }).reduce(0, +).formattedBytes))"
    }

    /// The last launch went wrong (not just "components install later").
    func didNotStart(_ game: Game) -> Bool {
        diagnoses[game.id]?.contains { $0.title != AppModel.componentsLaterTitle } ?? false
    }

    /// True for the "it didn't start" set (or what is left of it).
    func isCommonSet(_ ids: [String]) -> Bool {
        ids.count > 1 && Set(ids).isSubset(of: RuntimeCatalog.commonSet)
    }

    /// " (105 MB)": the download size when every part's size is known (shared downloads counted once).
    func sizeLabel(_ ids: [String]) -> String {
        let sizes = ids.map { RuntimeCatalog.component(RuntimeCatalog.canonicalID($0))?.approximateBytes }
        guard !sizes.isEmpty, !sizes.contains(nil) else { return "" }
        return " (\(Set(sizes.compactMap { $0 }).reduce(0, +).formattedBytes))"
    }

    // MARK: Changing external spaces

    /// Asks once whether G-Player may change an external space; `then` runs with the answer. Requests for a space
    /// that is already being asked about wait for that answer instead of asking twice.
    func askToChange(_ space: Space, then: @escaping @MainActor (Bool) -> Void) {
        if let i = changesRequests.firstIndex(where: { $0.spaceID == space.id }) {
            changesRequests[i].then.append(then)
        } else {
            changesRequests.append(ChangesRequest(spaceID: space.id, then: [then]))
        }
    }

    /// Saves the answer to the first request and runs what waited for it.
    func answerChangesRequest(_ allowed: Bool) {
        guard !changesRequests.isEmpty else { return }
        let request = changesRequests.removeFirst()
        if let space = space(request.spaceID) { setAllowsChanges(allowed, for: space) }
        request.then.forEach { $0(allowed) }
    }

    /// Saves the user's answer for an external space.
    func setAllowsChanges(_ allowed: Bool, for space: Space) {
        guard var s = self.space(space.id) else { return }
        s.allowsChanges = allowed
        update(s)
        componentsVersion += 1
    }

    /// True when G-Player had to leave the game's space as it is, so the inspector can say so.
    func changesRefused(for game: Game) -> Bool { space(game.spaceID)?.allowsChanges == false }

    // MARK: Runtime components

    /// True while any Windows program runs in the space. Installers wait for every program in a space to
    /// quit, so G-Player doesn't install into a busy space (Steam open, a game running).
    nonisolated static func isBusy(_ space: Space) async -> Bool {
        await Task.detached(priority: .utility) {
            WineProcesses.isRunning(in: space, processes: WineProcesses.snapshot())
        }.value
    }

    /// Ends Steam's helpers left in `space` after steam.exe has gone, once they have stayed on their own for a few seconds
    /// (Steam restarting itself has them alone for a moment). Left there, the space never empties, and a Steam started
    /// into them gets the old window, which ignores clicks. True when none are left.
    func endOrphanedSteamHelpers(in space: Space) async -> Bool {
        guard !(await Self.orphanedSteamHelpers(in: space)).isEmpty else { return true }
        try? await Task.sleep(for: .seconds(5))
        let orphans = await Self.orphanedSteamHelpers(in: space)
        guard !orphans.isEmpty else { return true }
        orphans.forEach { kill($0.pid, SIGTERM) }
        try? await Task.sleep(for: .seconds(3))
        (await Self.orphanedSteamHelpers(in: space)).forEach { kill($0.pid, SIGKILL) }
        try? await Task.sleep(for: .seconds(1))
        return (await Self.orphanedSteamHelpers(in: space)).isEmpty
    }

    nonisolated static func orphanedSteamHelpers(in space: Space) async -> [WineProcess] {
        await Task.detached(priority: .userInitiated) {
            WineProcesses.orphanedSteamHelpers(in: space, processes: WineProcesses.snapshot())
        }.value
    }

    nonisolated static func isSteamRunning(in space: Space) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            WineProcesses.isSteamRunning(in: space, processes: WineProcesses.snapshot())
        }.value
    }

    func installedComponents(in space: Space) -> Set<String> {
        guard let paths else { return [] }
        return RuntimeInstaller(paths: paths).installed(in: space)
    }

    /// Installs what's missing of `ids` into the space, after any install already queued there, with progress (and a
    /// stop button) in the sidebar. Never throws: a failed component is reported and remembered, and the game still
    /// starts.
    @discardableResult
    func installComponents(_ ids: [String], in space: Space, engine: Engine? = nil, reason: String,
                           retryFailed: Bool = false) async -> ComponentInstall {
        guard self.space(space.id)?.mayChange ?? space.mayChange else { return .notAllowed }
        return await enqueue(in: space.id, holds: String(localized: "Windows components \(reason)", comment: "Follows “Waiting for” in the sidebar: “Waiting for Windows components for “Game”…”")) {
            await self.installNow(ids, in: space, engine: engine, reason: reason, retryFailed: retryFailed)
        }.value
    }

    /// The install itself; only ever runs from the space's queue.
    func installNow(_ ids: [String], in space: Space, engine: Engine?, reason: String, retryFailed: Bool) async -> ComponentInstall {
        guard let paths else { return .done }
        await leftoversCleaning?.value                  // the start's clean-up of temporary downloads is over before one begins
        // Read now: the user may have said no while this waited in the queue.
        guard self.space(space.id)?.mayChange == true else { return .notAllowed }
        let installer = RuntimeInstaller(paths: paths)
        let wanted = ids.filter(RuntimeCatalog.isInstallable)
        let missing = await Task.detached { installer.missing(wanted, in: space, retryFailed: retryFailed) }.value
        guard !missing.isEmpty else {
            pendingComponents[space.id]?.subtract(ids)
            clearWaitingNotes(in: space)
            return .done
        }
        if await Self.isBusy(space) {
            pendingComponents[space.id, default: []].formUnion(missing)
            return .waiting
        }
        var resolved = engine
        if resolved == nil { resolved = await ensureEngine(EngineCatalog.info(space.engineID) ?? .wineStaging) }
        guard let engine = resolved else { return .done }
        let activity = begin(String(localized: "Installing Windows components \(reason)", comment: "The end is a phrase like “for “Game”” or “in “Main””"), componentsLabel(missing), setup: true)
        activeInstalls[space.id, default: 0] += 1
        defer { Self.decrement(&activeInstalls, space.id) }
        let work = Task.detached {
            try await installer.install(missing, in: space, engine: engine) { [weak self] f, m in
                Task { @MainActor in self?.progress(activity, f, m) }
            }
        }
        setStop(activity, help: String(localized: "Stop installing. A game waiting for this starts without it.")) { work.cancel() }
        defer { cancellers[activity] = nil; end(activity) }
        var result = ComponentInstall.done
        do {
            try await work.value
        } catch is CancellationError {
            result = .cancelled
            // Launches waiting for these start without them instead of installing them again.
            skippedComponents[space.id, default: []].formUnion(missing)
        } catch {
            errorMessage = String(localized: "Couldn't install everything \(reason): \(error.localizedDescription)", comment: "The first placeholder is a phrase like “for “Game”” or “in “Main””")
        }
        pendingComponents[space.id]?.subtract(ids)
        if result == .done { clearWaitingNotes(in: space) }
        componentsVersion += 1
        return result
    }

    /// Drops "Components install later" from games in a space once nothing waits to be installed there.
    private func clearWaitingNotes(in space: Space) {
        guard pendingComponents[space.id]?.isEmpty ?? true else { return }
        for game in state.games(in: space) {
            guard var notes = diagnoses[game.id] else { continue }
            notes.removeAll { $0.title == Self.componentsLaterTitle }
            diagnoses[game.id] = notes.isEmpty ? nil : notes
        }
    }

    /// Installs components that waited for a busy space, once the space is free.
    func installPendingComponents() {
        for (id, ids) in pendingComponents where !ids.isEmpty && !installingSpaces.contains(id) {
            guard let space = space(id) else { continue }
            Task {
                guard !(await Self.isBusy(space)) else { return }
                await installComponents(Array(ids), in: space, reason: String(localized: "in “\(space.name)”", comment: "Ends “Installing Windows components …”: where they are installed"))
            }
        }
    }

    // MARK: Registry

    /// Sets a game's registry values with one `regedit /S` call, and removes per-program values the game set last
    /// time and no longer wants. Skipped when it would write exactly what the space got last. Runs from the space's
    /// queue (as part of a launch), so two launches can't write the same file at once.
    func applyRegistryNow(_ values: [RegistryValue], for gameID: UUID, in space: Space, engine: Engine) async {
        guard let paths, self.space(space.id)?.mayChange == true else { return }
        // What each game set lives next to drive_c, where Windows programs don't clean up.
        let records = space.url.appendingPathComponent(".gplayer-registry", isDirectory: true)
        let record = records.appendingPathComponent("\(gameID.uuidString).json")
        let temp = space.driveC.appendingPathComponent("windows/temp", isDirectory: true)
        let file = temp.appendingPathComponent("gplayer-settings.reg")                      // the last file applied
        let previous = (try? Data(contentsOf: record)).flatMap { try? JSONDecoder().decode([RegistryValue].self, from: $0) } ?? []
        let text = RegistryFile.text(values + RegistryFile.removals(previous: previous, current: values))
        if let old = try? String(contentsOf: file, encoding: .utf8), old == text { return }
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            // A regedit that hangs must not hold the space's queue: it gets a minute.
            let status = try await WineLauncher.runAndWait(engine: engine, space: space,
                                                           arguments: ["regedit", "/S", space.windowsPath(for: file)],
                                                           workingDirectory: space.driveC, backend: .wined3d,
                                                           logsFolder: paths.logs, logName: "Settings", timeout: 60)
            guard status == 0 else { throw ShellError.failed("regedit exited with \(status)") }
            try JSONEncoder().encode(values).write(to: record, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: file)               // try again next launch
        }
    }

    /// Installs components the user asked for, then starts the game again.
    func installThenPlay(_ ids: [String], game: Game, in space: Space) async {
        skippedComponents[space.id]?.subtract(ids)
        let result = await installComponents(ids, in: space, reason: String(localized: "for \(game.title)", comment: "Ends “Installing Windows components …”: what they are for"), retryFailed: true)
        // Stop means stop: the game doesn't start (and doesn't install the same components again).
        guard result != .cancelled else { return }
        if result == .waiting {
            errorMessage = String(localized: "Something else is open in “\(space.name)”. Close it, then press the button again.")
            return
        }
        if let g = self.game(game.id) { play(g) }
    }

    /// Closes Steam, installs what the game needs, then starts it (which opens Steam again).
    func quitSteamThenInstall(_ request: LauncherQuit) {
        guard let game = game(request.gameID), let space = space(game.spaceID) else { return }
        preparing.insert(game.id)
        Task {
            let quit = await quitSteam(in: space)
            preparing.remove(game.id)
            guard quit.gone else {
                errorMessage = String(localized: "Steam didn't quit. Quit it from its menu (Steam › Exit), then press the button again.")
                return
            }
            await installThenPlay(request.components, game: game, in: space)
        }
    }

    /// Asks Steam to quit and waits for it, up to a minute, then for the rest of the space to quit (20 seconds at most), and
    /// says how far it got. While it quits, games that close with it aren't failures to learn from.
    func quitSteam(in space: Space) async -> SteamQuit {
        guard let paths, let engine = engine(for: space) else { return .failed }
        closingSteam.insert(space.id)
        defer { closingSteam.remove(space.id) }
        let activity = begin(String(localized: "Closing Steam"), String(localized: "Waiting for Steam to quit"))
        defer { end(activity) }
        let steam = AppPresets.steam
        let exe = steam.executableURL(in: space)
        _ = try? WineLauncher.start(engine: engine, space: space, arguments: [exe.path, "-shutdown"],
                                    workingDirectory: exe.deletingLastPathComponent(), backend: .auto,
                                    tweaks: LaunchTweaks(dllOverrides: steam.dllOverrides, environment: steam.environment),
                                    logsFolder: paths.logs, logName: "Steam shutdown")
        for _ in 0..<40 {
            // Stopped (a try with other graphics that was ended): Steam was asked to quit, but nothing waits for it.
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return .failed }
            // steam.exe has gone but its helpers stay: leftovers, ended, or the space never empties.
            if !(await Self.orphanedSteamHelpers(in: space)).isEmpty { _ = await endOrphanedSteamHelpers(in: space) }
            if !(await Self.isSteamRunning(in: space)) {
                // Closed on purpose: nothing that closed with it is a failure to learn from.
                for g in state.games(in: space) { autoLaunches[g.id] = nil }
                // steam.exe is gone seconds before its web helpers (the window) and Wine's services are, and a Steam
                // started into those never gets going: the old window stays up and ignores clicks.
                return await WineLauncher.waitForAll(engine: engine, space: space, timeout: 20) ? .spaceEmpty : .spaceBusy
            }
        }
        return .failed
    }

    // MARK: Steam

    /// Quits the running Steam, waits for it, then starts the game, so Steam passes on the game's settings.
    func restartSteamAndPlay(_ request: SteamRestart) {
        guard let game = game(request.gameID), let space = space(game.spaceID) else { return }
        preparing.insert(game.id)
        Task {
            let quit = await quitSteam(in: space)
            preparing.remove(game.id)
            guard quit.gone else {
                errorMessage = String(localized: "Steam didn't quit. Quit it from its menu (Steam › Exit), then press Play again.")
                return
            }
            if let g = self.game(game.id) { play(g, skipping: request.skipped) }
        }
    }
}
