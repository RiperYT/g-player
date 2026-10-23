import Foundation
import GPlayerCore

/// Wine Mono (.NET for Wine) for the launchers that run .NET code (`AppPreset.needsDotNet`): fetched into the engine once,
/// registered in the space once. What is needed, and when, is decided by `WineMono` and `LaunchPlanner`; this does the work.
extension AppModel {
    /// Brings Wine Mono into `engine` and registers it in `space`, as `plan` says. Only for a space G-Player may change (an external
    /// one the user allowed: `Space.mayChange`, read now), and from the space's queue. True when nothing is left to do, so `mscoree`
    /// can stay on for the launch. Never throws: a failure is shown, and the program starts without .NET, as it did before.
    func prepareWineMono(_ plan: WineMono.Plan, engine: Engine, in space: Space) async -> Bool {
        guard let paths, self.space(space.id)?.mayChange == true else { return false }
        if plan.fetch, !(await ensureWineMono(in: engine)) { return false }
        guard plan.register else { return true }
        // Another launch in the queue may have registered it since the plan was made.
        let package = plan.package
        if await Task.detached(priority: .userInitiated, operation: { WineMono.isRegistered(package, in: space) }).value { return true }
        // A program that is open keeps the environment it started with, and the registry of a busy space isn't on disk yet to look
        // at afterwards: the next start does it.
        if await Self.isBusy(space) { return false }
        let activity = begin(WineMono.registerTitle, "Adding .NET to “\(space.name)”", setup: true)
        defer { end(activity); cancellers[activity] = nil }
        let work = Task.detached { try await WineMono.register(package, engine: engine, space: space, logsFolder: paths.logs) }
        setStop(activity, help: "Stop setting up Wine Mono. The program starts without .NET.") { work.cancel() }
        do {
            try await work.value
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = "Couldn't set up Wine Mono in “\(space.name)”: \(error.localizedDescription) The program starts without .NET."
            return false
        }
    }

    /// Downloads Wine Mono into the engine unless it is there (about 40 MB, checked against its pinned SHA-256), with an entry in
    /// the sidebar that can be stopped. Asked again while it downloads (two launches in two spaces), it waits for that download.
    /// False when it couldn't be had or the user stopped it (a failure is shown).
    func ensureWineMono(in engine: Engine) async -> Bool {
        guard engine.info.mono != nil, let manager = engineManager else { return false }
        if engine.hasWineMono { return true }
        if let running = monoInstalls[engine.info.id] { return await running.value }
        let task = Task { await self.downloadWineMono(into: engine, with: manager) }
        monoInstalls[engine.info.id] = task
        return await task.value
    }

    private func downloadWineMono(into engine: Engine, with manager: EngineManager) async -> Bool {
        await leftoversCleaning?.value
        let activity = begin(WineMono.downloadTitle, "Starting", setup: true)
        defer { end(activity); cancellers[activity] = nil; monoInstalls[engine.info.id] = nil }
        let log = InstallLog(title: "Install Wine Mono \(engine.info.mono?.version ?? "") for \(engine.info.id)")
        let logs = manager.paths.logs
        let work = Task.detached {
            try await manager.installWineMono(into: engine) { [weak self] fraction, message in
                log.record(message)
                Task { @MainActor in self?.progress(activity, fraction, message) }
            }
        }
        // What came stays on disk, so downloading again goes on from there.
        setStop(activity, help: "Stop downloading Wine Mono. What came is kept, and the download goes on from there next time.") { work.cancel() }
        do {
            try await work.value
            log.write(outcome: "Ready", to: logs)
            engineVersion += 1                      // views that ask the engine about it read it again
            return true
        } catch is CancellationError {
            log.write(outcome: "Stopped", to: logs)
            return false
        } catch {
            log.write(outcome: InstallLog.failure(error), to: logs)
            errorMessage = "Couldn't download Wine Mono: \(error.localizedDescription) The program starts without .NET."
            return false
        }
    }
}
