import Foundation
import GPlayerCore

/// Moving spaces off a retired engine (G-Player Wine 26.3.0-1) onto its replacement, which has the same Wine plus what
/// the update adds. `EngineMigration` decides; this looks at what is installed and busy, and carries the plan out. It runs
/// at start, when an engine install ends, and at every look at the running programs while a space is still on a retired
/// engine, so a space moves the moment it goes quiet. Nothing here writes into a space's files.
extension AppModel {
    /// A space is on a retired engine, or a retired engine is installed and not yet looked at: there is something to decide.
    var needsEngineMigration: Bool {
        guard let manager = engineManager else { return false }
        return state.spaces.contains { EngineCatalog.info($0.engineID)?.isRetired == true }
            || EngineCatalog.retired.contains { manager.isInstalled($0) && !retiredRemovalsTried.contains($0.id) }
    }

    /// `migrateEngines(processes:)` after a look at the programs that run (taken off the main thread).
    func migrateEngines() {
        guard needsEngineMigration else { return }
        Task {
            let processes = await Task.detached(priority: .utility) { WineProcesses.snapshot() }.value
            migrateEngines(processes: processes)
        }
    }

    /// Moves the spaces that can move, starts the background install of what the others wait for, and removes retired
    /// engines nothing uses any more. A space moves only while nothing runs or starts in it, so a launch never changes engine
    /// under its program; one that can't move yet is looked at again at the next look at the programs.
    func migrateEngines(processes: [WineProcess]) {
        guard let manager = engineManager, needsEngineMigration else { return }
        var plan = enginePlan(processes: processes, manager: manager)
        if !plan.switches.isEmpty, !moveSpaces(plan.switches) { plan.remove = [] }       // moved, or not at all
        for id in plan.install { if let info = EngineCatalog.info(id) { updateEngineInBackground(info) } }
        for id in plan.remove { if let info = EngineCatalog.info(id) { removeRetiredEngine(info, manager: manager) } }
    }

    /// Puts the spaces on their new engines, with what was learned about their games' graphics (`EngineMigration.apply`) and what
    /// the app remembers about their launches. Before the first move library.json is kept as it is
    /// (`LibraryStore.keepBeforeEngineUpdate`): an older G-Player would read the moved spaces as unknown. Moves nothing, and says
    /// so, when that copy can't be made (the user is told once per run, and the next look tries again).
    @discardableResult
    func moveSpaces(_ switches: [EngineMigration.Plan.Switch]) -> Bool {
        guard !switches.isEmpty, let paths else { return false }
        do { try LibraryStore(paths: paths).keepBeforeEngineUpdate() }
        catch {
            if !engineBackupWarned {
                engineBackupWarned = true
                errorMessage = "G-Player couldn't keep a copy of library.json before updating G-Player Wine, so your spaces stay on the old version for now. \(error.localizedDescription)"
            }
            return false
        }
        mutate { EngineMigration.apply(EngineMigration.Plan(switches: switches), to: &$0) }
        carryOverLaunchRecords(switches)
        engineVersion += 1
        return true
    }

    /// `EngineMigration.plan` for what is installed and in use now.
    private func enginePlan(processes: [WineProcess], manager: EngineManager) -> EngineMigration.Plan {
        let installed = Set(EngineCatalog.known.filter { manager.isInstalled($0) }.map(\.id))
        let busy = Set(state.spaces.filter { isEngineInUse(by: $0, processes: processes) }.map(\.id))
        return EngineMigration.plan(spaces: state.spaces, installed: installed, busy: busy)
    }

    /// Deletes a retired engine's folder once nothing uses it, off the main thread, after the other work in engine folders
    /// (`engineFilesWork`: linking D3DMetal, the engine fixes) has ended. Right before, it looks again: the plan was made from
    /// a look taken a moment ago, and a program may have started since, so there is a fresh look at the programs and at which
    /// files the running processes come from (`EngineMigration.mayRemove`). If anything uses the engine it is left, and the next
    /// look at the programs tries again.
    private func removeRetiredEngine(_ info: EngineInfo, manager: EngineManager) {
        guard !removingEngines.contains(info.id), !retiredRemovalsTried.contains(info.id) else { return }
        removingEngines.insert(info.id)
        let previous = engineFilesWork
        engineFilesWork = Task {
            await previous?.value
            defer { removingEngines.remove(info.id) }
            let folder = manager.folder(for: info)
            let (processes, executables) = await Task.detached(priority: .utility) {
                (WineProcesses.snapshot(), WineProcesses.executables())
            }.value
            let plan = enginePlan(processes: processes, manager: manager)
            guard EngineMigration.mayRemove(info.id, plan: plan, folder: folder, executables: executables) else { return }
            retiredRemovalsTried.insert(info.id)
            await Task.detached(priority: .utility) { _ = try? manager.remove(info) }.value
            engineVersion += 1
        }
    }

    /// Something runs in the space, is being started or installed in it, or is queued for it: its engine's files are in use
    /// (`EngineMigration.isInUse`). Wine's own services count as programs; the Wine server isn't seen as one, and the engine's
    /// folder is checked for the processes that run from it before it is deleted (`removeRetiredEngine`).
    private func isEngineInUse(by space: Space, processes: [WineProcess]) -> Bool {
        let games = state.games(in: space)
        return EngineMigration.isInUse(space, processes: processes, activity: .init(
            movingEngine: movingSpaces.contains(space.id), installing: installingSpaces.contains(space.id),
            queued: queueHolder(in: space.id) != nil, launchesStarting: launchesStarting[space.id] ?? 0,
            gameStarting: games.contains { preparing.contains($0.id) }, gameRunning: games.contains { isRunning($0) },
            addingGame: (addGameSpaces[space.id] ?? 0) > 0))
    }

    /// What the app remembers about launches of the moved spaces' games belongs to the engine they ran on (the "Try Other
    /// Graphics" offer after a failure, say): the replacement is the same Wine, so it goes with them.
    func carryOverLaunchRecords(_ switches: [EngineMigration.Plan.Switch]) {
        for move in switches {
            for game in state.games where game.spaceID == move.space {
                if autoLaunches[game.id]?.engineID == move.from { autoLaunches[game.id]?.engineID = move.to }
                if failedAutoLaunches[game.id]?.engineID == move.from { failedAutoLaunches[game.id]?.engineID = move.to }
                if let request = pendingOtherGraphics, request.gameID == game.id, request.launched.engineID == move.from {
                    var launched = request.launched
                    launched.engineID = move.to
                    pendingOtherGraphics = OtherGraphicsRequest(gameID: request.gameID, launched: launched)
                }
            }
        }
    }
}
