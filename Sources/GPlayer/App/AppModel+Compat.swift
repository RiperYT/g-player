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
        case .executable: return game.executableURL(in: space)
        case .steam(let id):
            guard let folder = SteamLibrary.installFolder(appID: id, in: space) else { return nil }
            return ExecutableScanner.scan(folder, title: game.title, maxDepth: 4).first { $0.score > -40 }?.url
        case .epic: return nil
        }
    }

    /// The file name of the program a game starts, without reading the disk: its own .exe, or the one the analysis
    /// looked at.
    func programName(of game: Game) -> String? {
        if case .executable = game.source, let path = game.executablePath, !path.isEmpty {
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

    /// What the layers would do for this game right now, for the inspector. No disk reads, no file writes.
    func compatPreview(for game: Game) -> CompatPlan? {
        guard game.kind == .game, let space = space(game.spaceID) else { return nil }
        let engine = EngineCatalog.info(space.engineID) ?? EngineCatalog.wineStaging
        return CompatResolver.resolve(.init(engine: engine, analysis: game.analysis, fixes: fixes(for: game),
                                            options: game.launchOptions, userBackend: game.graphics,
                                            isStoreGame: game.storeKey != nil,
                                            programNames: programName(of: game).map { [$0] } ?? []))
    }

    func setOptions(_ options: LaunchOptions, for game: Game) {
        guard var g = self.game(game.id) else { return }
        g.options = options
        update(g)
        diagnoses[game.id] = nil
    }

    /// Graphics chosen by hand. For a game that also switches the profile to Custom, so the choice is used.
    func setGraphics(_ backend: GraphicsBackend, for game: Game) {
        guard var g = self.game(game.id) else { return }
        g.graphics = backend
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
                    self.skippedComponents[space.id]?.subtract(ids)
                    let result = await self.installComponents(ids, in: space, reason: "for \(game.title)", retryFailed: true)
                    // Stop means stop: the game doesn't start (and doesn't install the same components again).
                    guard result != .cancelled else { return }
                    if let g = self.game(game.id) { self.play(g) }
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
        return await enqueue(in: space.id) {
            await self.installNow(ids, in: space, engine: engine, reason: reason, retryFailed: retryFailed)
        }.value
    }

    /// The install itself; only ever runs from the space's queue.
    func installNow(_ ids: [String], in space: Space, engine: Engine?, reason: String, retryFailed: Bool) async -> ComponentInstall {
        guard let paths else { return .done }
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
        let activity = begin("Installing Windows components \(reason)", componentsLabel(missing))
        activeInstalls[space.id, default: 0] += 1
        defer { Self.decrement(&activeInstalls, space.id) }
        let work = Task.detached {
            try await installer.install(missing, in: space, engine: engine) { [weak self] f, m in
                Task { @MainActor in self?.progress(activity, f, m) }
            }
        }
        setStop(activity, help: "Stop installing. A game waiting for this starts without it.") { work.cancel() }
        defer { cancellers[activity] = nil; end(activity) }
        var result = ComponentInstall.done
        do {
            try await work.value
        } catch is CancellationError {
            result = .cancelled
            // Launches waiting for these start without them instead of installing them again.
            skippedComponents[space.id, default: []].formUnion(missing)
        } catch {
            errorMessage = "Couldn't install everything \(reason): \(error.localizedDescription)"
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
                await installComponents(Array(ids), in: space, reason: "in “\(space.name)”")
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

    // MARK: Steam

    /// Quits the running Steam, waits for it, then starts the game, so Steam passes on the game's settings.
    func restartSteamAndPlay(_ request: SteamRestart) {
        guard let paths, let game = game(request.gameID), let space = space(game.spaceID),
              let engine = engine(for: space) else { return }
        preparing.insert(game.id)
        Task {
            let activity = begin("Restarting Steam", "Waiting for Steam to quit")
            let steam = AppPresets.steam
            let exe = steam.executableURL(in: space)
            _ = try? WineLauncher.start(engine: engine, space: space, arguments: [exe.path, "-shutdown"],
                                        workingDirectory: exe.deletingLastPathComponent(), backend: .auto,
                                        tweaks: LaunchTweaks(dllOverrides: steam.dllOverrides, environment: steam.environment),
                                        logsFolder: paths.logs, logName: "Steam shutdown")
            var quit = false
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(1.5))
                if !(await Self.isSteamRunning(in: space)) { quit = true; break }
            }
            end(activity)
            preparing.remove(game.id)
            guard quit else {
                errorMessage = "Steam didn't quit. Quit it from its menu (Steam › Exit), then press Play again."
                return
            }
            if let g = self.game(game.id) { play(g, skipping: request.skipped) }
        }
    }
}
