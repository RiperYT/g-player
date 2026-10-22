import Foundation
import GPlayerCore
import Observation

/// One installer of Add Game, from the space's queue to its end. The sheet shows where it is, and can stop it or say it is done.
@MainActor @Observable
final class InstallerRun {
    enum Phase { case queued, running, finishing }

    private(set) var phase = Phase.queued
    /// "The Installer Is Done": go on though its programs may still be open.
    private(set) var markedDone = false
    /// Every program of the installer has quit.
    fileprivate(set) var processesEnded = false
    private(set) var cancelled = false

    func markDone() { markedDone = true }
    func cancel() { cancelled = true }
    fileprivate func start() { phase = .running }
    fileprivate func finish() { phase = .finishing }
}

/// Add Game's steps that touch the engines and the space's queue, so the sheet only shows them.
extension AppModel {
    /// The engine of `space`, downloaded first when it isn't installed (the sidebar shows that). Nil when it couldn't be:
    /// the reason is shown.
    func engineReady(for space: Space) async -> Engine? {
        if let engine = engine(for: space) { return engine }
        return await ensureEngine(EngineCatalog.info(space.engineID) ?? .wineStaging)
    }

    /// Runs `installer` in `space` from the space's queue: after the Windows components being installed there and before
    /// anything else, so two installers never run at once (a second one fails with error 1618). Returns the programs it
    /// added, best guess first, once it and what it started have quit or the user said it is done.
    ///
    /// Stopping (`run.cancel()`, or cancelling the calling task) ends the installer and what it started, then throws
    /// `CancellationError`. Whatever the installer was started from is deleted only after that, by the caller.
    func runInstaller(_ installer: URL, in space: Space, engine: Engine, title: String, run: InstallerRun) async throws -> [ExecutableCandidate] {
        guard let paths else { throw CancellationError() }
        let activity = begin("Installing “\(title)”", "Starting", waitsIn: queueHolder(in: space.id) == nil ? nil : space.id)
        defer { cancellers[activity] = nil; end(activity) }
        setStop(activity, help: "Stop the installer. What it already installed stays.") { run.cancel() }
        let queued = enqueue(in: space.id, holds: "the installer of “\(title)”") { () -> Result<[ExecutableCandidate], Error> in
            await self.runInstallerNow(installer, in: space, engine: engine, title: title, run: run, activity: activity, paths: paths)
        }
        // The queue's task isn't a child of this one, so cancelling this call has to reach it by the run.
        let result = await withTaskCancellationHandler {
            // A stop while the installer still waits for its turn leaves at once; the queue ends it as soon as it is reached.
            while run.phase == .queued && !run.cancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { run.cancel() }
            }
            if run.cancelled && run.phase == .queued { return Result<[ExecutableCandidate], Error>.failure(CancellationError()) }
            return await queued.value
        } onCancel: { Task { @MainActor in run.cancel() } }
        return try result.get()
    }

    /// The installer itself; only ever runs from the space's queue.
    private func runInstallerNow(_ installer: URL, in space: Space, engine: Engine, title: String, run: InstallerRun,
                                 activity: UUID, paths: LibraryPaths) async -> Result<[ExecutableCandidate], Error> {
        if run.cancelled { return .failure(CancellationError()) }
        run.start()
        startedWaiting(activity)
        progress(activity, nil, "Running \(installer.lastPathComponent)")
        // Programs open in the space before the installer started aren't the installer's to stop.
        let wasBusy = await Self.isBusy(space)
        let before = await Task.detached(priority: .userInitiated) { ProgramSnapshot.take(of: space) }.value
        if run.cancelled { return .failure(CancellationError()) }
        let program: RunningProgram
        do {
            program = try WineLauncher.start(engine: engine, space: space, arguments: WineLauncher.arguments(toOpen: installer),
                                             workingDirectory: installer.deletingLastPathComponent(), backend: .auto,
                                             logsFolder: paths.logs, logName: "Install \(title)") { _ in
                // The first program may hand over to another and quit: the installer is over when none is left.
                Task {
                    await WineLauncher.waitForAll(engine: engine, space: space)
                    await MainActor.run { run.processesEnded = true }
                }
            }
        } catch { return .failure(error) }
        while !run.processesEnded && !run.markedDone && !run.cancelled {
            do { try await Task.sleep(for: .milliseconds(400)) } catch { run.cancel() }
        }
        if run.cancelled {
            program.terminate()
            // What it started goes too, unless something else was open in the space before it: that isn't ours to stop.
            if await !WineLauncher.waitForAll(engine: engine, space: space, timeout: 10), !wasBusy {
                await WineLauncher.killAll(engine: engine, space: space)
            }
            return .failure(CancellationError())
        }
        run.finish()
        progress(activity, nil, "Looking for what it installed…")
        let found = await Task.detached(priority: .userInitiated) { ProgramSnapshot.newPrograms(in: space, since: before) }.value
        return .success(found)
    }
}

/// Spaces G-Player makes for an Add Game that may come to nothing.
extension AppModel {
    /// Removes a space G-Player made for a game that wasn't added, for good (it has only Windows in it), once what is queued
    /// in it (the Windows components every new space gets) has run. Only if it is still empty then: no game in the library
    /// and no game files in it, so nothing the user put there meanwhile is lost.
    func discardEmptySpace(_ id: UUID) {
        guard let space = space(id), space.origin == .managed else { return }
        enqueue(in: id, isInstall: false, holds: "“\(space.name)” to be removed") {
            guard let space = self.space(id), self.state.games(in: space).isEmpty, SpaceManager.holdsNoGames(space) else { return }
            self.pendingComponents[id] = nil
            // Its Wine server may still be winding down after the components' installers: it goes first.
            if let engine = self.engineManager?.engine(id: space.engineID) { await WineLauncher.killAll(engine: engine, space: space) }
            self.removeSpace(space, deleteFiles: true, permanently: true)
        }
    }
}
