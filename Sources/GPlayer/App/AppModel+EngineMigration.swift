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
        let installed = Set(EngineCatalog.known.filter { manager.isInstalled($0) }.map(\.id))
        let busy = Set(state.spaces.filter { isEngineInUse(by: $0, processes: processes) }.map(\.id))
        let plan = EngineMigration.plan(spaces: state.spaces, installed: installed, busy: busy)
        if !plan.switches.isEmpty {
            mutate { EngineMigration.apply(plan, to: &$0) }
            carryOverLaunchRecords(plan.switches)
            engineVersion += 1
        }
        for id in plan.install { if let info = EngineCatalog.info(id) { updateEngineInBackground(info) } }
        for id in plan.remove {
            guard retiredRemovalsTried.insert(id).inserted, let info = EngineCatalog.info(id) else { continue }
            Task {
                await Task.detached(priority: .utility) { _ = try? manager.remove(info) }.value
                engineVersion += 1
            }
        }
    }

    /// Something runs in the space, is being started or installed in it, or is queued for it: its engine's files are in use.
    /// Programs count whatever they are, Wine's own services too (a Wine server of the old engine that is winding down must
    /// be gone before the new Wine starts there).
    private func isEngineInUse(by space: Space, processes: [WineProcess]) -> Bool {
        !WineProcesses.programs(in: space, from: processes).isEmpty
            || movingSpaces.contains(space.id) || installingSpaces.contains(space.id) || queueHolder(in: space.id) != nil
            || (launchesStarting[space.id] ?? 0) > 0
            || state.games(in: space).contains { preparing.contains($0.id) || isRunning($0) }
    }

    /// What the app remembers about launches of the moved spaces' games belongs to the engine they ran on (the "Try Other
    /// Graphics" offer after a failure, say): the replacement is the same Wine, so it goes with them.
    private func carryOverLaunchRecords(_ switches: [EngineMigration.Plan.Switch]) {
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
