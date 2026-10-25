import Foundation
import GPlayerCore

/// How a download of Wine Mono into an engine ended.
enum WineMonoFetch {
    case ready, stopped, failed(Error)
}

/// Wine Mono (.NET for Wine) for the launchers that run .NET code (`AppPreset.dotNetReason`): fetched into the engine once,
/// registered in the space once. What is needed, and when, is decided by `WineMono` and `LaunchPlanner`; this does the work.
extension AppModel {
    /// Brings Wine Mono into `engine` and registers it in `space`, as `plan` says, and says what came of it: a note for the space
    /// when it didn't (`wineMonoNotes`), an alert for a failure that isn't the Mac being offline. Only for a space G-Player may change
    /// (read now), and from the space's queue. Never throws: whatever is being started goes on without .NET, as it did before.
    /// - Parameters:
    ///   - program: what the .NET is for, as the user knows it ("Epic Games Launcher").
    ///   - purpose: why it is needed ("Epic Online Services").
    ///   - consequence: what happens next when it isn't there ("Epic Games Launcher starts without .NET."); a program that doesn't
    ///     exist yet (an installer's first start) is told differently from one that starts now.
    func prepareWineMono(_ plan: WineMono.Plan, engine: Engine, in space: Space, program: String, purpose: String,
                         consequence: String) async -> WineMono.Outcome {
        let outcome = await attemptWineMono(plan, engine: engine, in: space, purpose: purpose)
        switch outcome {
        case .ready:
            clearWineMonoNote(in: space)
        default:
            if let note = WineMono.note(for: outcome, program: program, purpose: purpose),
               WineMono.showsNote(for: outcome, alreadyShown: wineMonoNotesShown.contains(space.id)) {
                wineMonoNotes[space.id] = note
                wineMonoNotesShown.insert(space.id)
            }
            if let alert = WineMono.alert(for: outcome, space: space.name, consequence: consequence) { errorMessage = alert }
        }
        return outcome
    }

    /// The space has Wine Mono in place: what was said about it not being there is out of date.
    func clearWineMonoNote(in space: Space) {
        wineMonoNotes[space.id] = nil
        wineMonoNotesShown.remove(space.id)
    }

    func closeWineMonoNote(_ spaceID: UUID) { wineMonoNotes[spaceID] = nil }

    /// While it works the engine and the space count as busy (`busySpaces`): the engine can't be removed under it.
    private func attemptWineMono(_ plan: WineMono.Plan, engine: Engine, in space: Space, purpose: String) async -> WineMono.Outcome {
        guard let paths, self.space(space.id)?.mayChange == true else { return .notAllowed }
        monoWork[space.id, default: 0] += 1
        defer { Self.decrement(&monoWork, space.id) }
        let package = plan.package
        if !WineMono.pathFits(package, in: engine.wineRoot) {
            return .tooLong(WineMono.loadPathLength(of: package, in: engine.wineRoot))
        }
        // Another launch may have done it since the plan was made.
        let (inEngine, registered, earlier) = await Task.detached(priority: .userInitiated) {
            (engine.hasWineMono, WineMono.isRegistered(package, in: space), WineMono.failure(in: space))
        }.value
        if inEngine && registered { return .ready }
        // The space before anything is downloaded: programs that run in it (the launcher is open) keep the environment they
        // started with, so Wine Mono couldn't help them yet, and the registry of a busy space isn't on disk to look at afterwards.
        if await Self.isBusy(space) { return .spaceBusy }
        if let earlier, WineMono.isWaiting(earlier, for: package) { return .waiting(earlier) }
        if !inEngine {
            switch await ensureWineMono(in: engine, purpose: purpose) {
            case .ready: break
            case .stopped: return .stopped(everything: false)
            case .failed(let error): return failed(by: error, package: package, in: space)
            }
        }
        guard !registered else { return .ready }
        let activity = begin(WineMono.registerTitle, String(localized: "Adding .NET to “\(space.name)”"), setup: true)
        registeringMono.insert(space.id)
        stoppedMono.remove(space.id)
        defer { registeringMono.remove(space.id); stoppedMono.remove(space.id); end(activity); cancellers[activity] = nil }
        let work = Task.detached { try await WineMono.register(package, engine: engine, space: space, logsFolder: paths.logs) }
        setStop(activity, help: String(localized: "Stop setting up Wine Mono. What is being started goes on without .NET.")) { work.cancel() }
        do {
            try await work.value
            WineMono.forgetFailure(in: space)
            return .ready
        } catch {
            // Stop All kills the setup's own program, and what that leaves behind isn't a failure to tell anyone about.
            return failed(by: error, package: package, in: space, stoppedEverything: stoppedMono.contains(space.id))
        }
    }

    /// The outcome of an attempt that threw, kept in the space when it is a failure (so the next starts don't try again at once).
    private func failed(by error: Error, package: WineMonoPackage, in space: Space, stoppedEverything: Bool = false) -> WineMono.Outcome {
        let outcome = WineMono.outcome(after: error, stoppedEverything: stoppedEverything, package: package)
        if case .failed(let failure) = outcome { WineMono.record(failure, in: space) }
        return outcome
    }

    /// Downloads Wine Mono into the engine unless it is there (about 40 MB, checked against its pinned SHA-256), with an entry in
    /// the sidebar that can be stopped. Asked again while it downloads (two launches in two spaces), it waits for that download.
    func ensureWineMono(in engine: Engine, purpose: String) async -> WineMonoFetch {
        guard engine.info.mono != nil, let manager = engineManager else {
            return .failed(ShellError.failed(String(localized: "G-Player doesn't know a Wine Mono for \(engine.info.name).")))
        }
        if engine.hasWineMono { return .ready }
        if let running = monoInstalls[engine.info.id] { return await running.value }
        let task = Task { await self.downloadWineMono(into: engine, purpose: purpose, with: manager) }
        monoInstalls[engine.info.id] = task
        return await task.value
    }

    private func downloadWineMono(into engine: Engine, purpose: String, with manager: EngineManager) async -> WineMonoFetch {
        await leftoversCleaning?.value
        let activity = begin(WineMono.downloadTitle, String(localized: "Starting"), setup: true, note: String(localized: "\(purpose) needs .NET", comment: "The sidebar note under the download; the placeholder says what for, e.g. “Epic Online Services”"))
        defer { end(activity); cancellers[activity] = nil; monoInstalls[engine.info.id] = nil }
        let log = InstallLog(title: "Install Wine Mono \(engine.info.mono?.version ?? "") for \(engine.info.id)")
        let logs = manager.paths.logs
        let work = Task.detached {
            var logged = manager
            logged.log = { log.record($0) }                  // English, whatever the app's language
            try await logged.installWineMono(into: engine) { [weak self] fraction, message in
                Task { @MainActor in self?.progress(activity, fraction, message) }
            }
        }
        // What came stays on disk, so downloading again goes on from there.
        setStop(activity, help: String(localized: "Stop downloading Wine Mono. What came is kept, and the download goes on from there next time.")) { work.cancel() }
        do {
            try await work.value
            log.write(outcome: "Ready", to: logs)
            engineVersion += 1                      // views that ask the engine about it read it again
            return .ready
        } catch is CancellationError {
            log.write(outcome: "Stopped", to: logs)
            return .stopped
        } catch {
            log.write(outcome: InstallLog.failure(error), to: logs)
            return .failed(error)
        }
    }
}
