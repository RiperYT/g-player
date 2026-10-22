import Foundation
import GPlayerCore

/// A space G-Player offers to move to G-Player Wine, for a game only D3DMetal can run. Shown before anything happens.
struct EngineMove: Identifiable {
    var id: UUID { gameID }
    let gameID: UUID
    let spaceName: String
    let fromEngine: String
    /// G-Player Wine (Wine 11.0) is older than what the space runs now (Wine Staging 11.18).
    let olderWine: Bool
    let downloadMB: Int64
}

extension AppModel {
    /// Keeps D3DMetal in step with the Apple toolkit setting: turned on, it is copied once from the installed toolkit
    /// (when there is one and nothing was copied before) and linked into every G-Player Wine engine; turned off, it is
    /// taken out of them again, so they run Wine's own Direct3D.
    func syncD3DMetal() {
        Task { await prepareD3DMetal() }
    }

    /// `syncD3DMetal`, for callers that need D3DMetal in place before they go on. One run at a time: the toggle, an
    /// engine install and an import can ask at once, and they share the engine's files.
    func prepareD3DMetal() async {
        let previous = d3dMetalWork
        let work = Task { @MainActor in
            await previous?.value
            await self.linkD3DMetal()
        }
        d3dMetalWork = work
        await work.value
    }

    private func linkD3DMetal() async {
        guard let paths, let manager = engineManager else { return }
        let store = D3DMetalStore(paths: paths)
        let on = useAppleToolkit
        let engines = EngineCatalog.all.filter { $0.kind == .crossover }.compactMap(manager.engine)
        // An engine with programs open keeps what it has until they quit: its DLLs are in use.
        let spaces = state.spaces
        let autoImport = on && store.installed == nil && D3DMetalStore.toolkitSource != nil
        if autoImport { isImportingD3DMetal = true }
        let (failure, waited) = await Task.detached(priority: .utility) { () -> (String?, Bool) in
            var waited = false
            if autoImport, let source = D3DMetalStore.toolkitSource {
                do { try await store.importD3DMetal(from: source) } catch { return (error.localizedDescription, false) }
            }
            let processes = WineProcesses.snapshot()
            for engine in engines {
                let busy = spaces.contains { $0.engineID == engine.info.id && WineProcesses.isRunning(in: $0, processes: processes) }
                if busy { waited = true; continue }
                do {
                    if on { try store.link(into: engine) } else { try store.unlink(from: engine) }
                } catch {
                    return (error.localizedDescription, waited)
                }
            }
            return (nil, waited)
        }.value
        if autoImport { isImportingD3DMetal = false }
        if let failure { errorMessage = failure }
        d3dMetalWaiting = waited
        d3dMetal = store.installed
        engineVersion += 1
    }

    /// Copies D3DMetal from a Game Porting Toolkit the user chose (Apple's .dmg, an opened disk, or the installed
    /// toolkit) and links it into the G-Player Wine engines.
    func importD3DMetal(from source: URL) async {
        guard let paths, !isImportingD3DMetal else { return }
        isImportingD3DMetal = true
        defer { isImportingD3DMetal = false }
        let store = D3DMetalStore(paths: paths)
        do {
            try await Task.detached(priority: .userInitiated) { _ = try await store.importD3DMetal(from: source) }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        await prepareD3DMetal()
    }

    /// Turns Apple's toolkit off and deletes the D3DMetal copied into the library (the button says both).
    func removeD3DMetal() async {
        useAppleToolkit = false
        await prepareD3DMetal()
        guard let paths else { return }
        do { try D3DMetalStore(paths: paths).removeImported() } catch { errorMessage = error.localizedDescription }
        d3dMetal = nil
    }

    /// D3DMetal can come into G-Player Wine: copied already, or a toolkit is installed to copy it from.
    var d3dMetalAvailable: Bool { useAppleToolkit && (d3dMetal != nil || D3DMetalStore.toolkitSource != nil) }

    /// Asks before moving the game's space to G-Player Wine (`moveToGPlayerWine`).
    func offerGPlayerWine(for gameID: UUID) {
        guard let game = game(gameID), let space = space(game.spaceID) else { return }
        let info = EngineCatalog.info(space.engineID)
        let from = info.map { "\($0.name) \($0.version)" } ?? space.engineID
        let mb = isInstalled(EngineCatalog.crossover) ? 0
            : EngineCatalog.crossover.downloadBytes(wineStagingInstalled: isInstalled(EngineCatalog.wineStaging)) / 1_000_000
        engineMove = EngineMove(gameID: gameID, spaceName: space.name, fromEngine: from, olderWine: info?.kind == .wineStaging, downloadMB: mb)
    }

    /// Moves the game's whole space to G-Player Wine and starts the game: G-Player Wine downloads first (nothing changes
    /// if that fails), D3DMetal goes in, Steam quits, and only then does the space switch. An outside space needs the
    /// user's yes to changes, since its prefix gets updated for the other Wine.
    func moveToGPlayerWine(_ gameID: UUID) {
        guard let game = game(gameID), let space = space(game.spaceID), space.engineID != EngineCatalog.crossover.id,
              !movingSpaces.contains(space.id) else { return }
        if !space.mayChange {
            guard space.allowsChanges == nil else {
                errorMessage = "G-Player doesn't change “\(space.name)”: you said so. Allow changes in the space's settings first."
                return
            }
            askToChange(space) { [weak self] allowed in if allowed { self?.moveToGPlayerWine(gameID) } }
            return
        }
        movingSpaces.insert(space.id)
        Task {
            defer { movingSpaces.remove(space.id) }
            guard let gplayerWine = await ensureEngine(EngineCatalog.crossover) else { return }
            await prepareD3DMetal()
            guard readyBackends(of: gplayerWine).contains(.d3dmetal) else {
                if errorMessage == nil {
                    errorMessage = d3dMetalWaiting
                        ? "D3DMetal goes into G-Player Wine once the programs open on it quit. Close them and try again."
                        : "D3DMetal isn't in G-Player Wine yet. Choose your Game Porting Toolkit download in Settings › Engines."
                }
                return
            }
            // Closing Steam already waited for the rest of the space, so it isn't waited for twice.
            var spaceEmpty = false
            if await Self.isSteamRunning(in: space) {
                let quit = await quitSteam(in: space)
                guard quit.gone else {
                    errorMessage = "Steam didn't quit, so “\(space.name)” stays on its engine for now. Quit Steam and try again."
                    return
                }
                spaceEmpty = quit == .spaceEmpty
            }
            if !spaceEmpty, let old = engine(for: space), !(await WineLauncher.waitForAll(engine: old, space: space, timeout: 30)) {
                errorMessage = "Programs in “\(space.name)” are still open, so it stays on its engine for now. Close them and try again."
                return
            }
            guard var current = self.space(space.id) else { return }
            current.engineID = EngineCatalog.crossover.id
            update(current)
            if let g = self.game(gameID) { play(g) }
        }
    }
}
