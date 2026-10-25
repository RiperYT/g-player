import Foundation
import GPlayerCore

/// A launch whose graphics Automatic picked and G-Player can learn from, until the game is gone.
struct AutoLaunch {
    /// What ran (never `.auto`).
    let backend: GraphicsBackend
    /// The engine it ran on, so what is learned belongs to it. A space that moves to a newer revision of the same Wine takes
    /// the record along (`migrateEngines`).
    var engineID: String
    let startedAt: Date
    /// It is another try with other graphics: the game's Stop ends the tries while it starts.
    let retried: Bool
    /// The game has run for a minute and the graphics were written down as working. The record stays while it runs, for the
    /// "picture missing" button.
    var settled = false
}

/// How another try with other graphics is made.
struct GraphicsRetryLaunch {
    /// What the game will have learned once its program has started: the failure that led here. Written then, not before
    /// (nil: written already, because the user pressed a button).
    var learned: AutoGraphics?
    /// G-Player does it on a log's evidence, without being asked: it never asks or shows a dialog either, and a launch that
    /// would isn't made.
    var automatic: Bool
}

/// The work of another try with other graphics for a game. The token tells it from a newer one, so an old try that ends
/// late can't clear what the newer owns.
struct GraphicsRetryTask {
    let token: UUID
    let task: Task<Void, Never>
}

/// A "picture missing" request: the launch the user is looking at, held until they confirm, since the game may quit while
/// the question is open.
struct OtherGraphicsRequest {
    let gameID: UUID
    let launched: AutoLaunch
}

/// Where the tries with other graphics stand for a game.
enum RetryState {
    case none
    /// G-Player is preparing another start (stopping the game, closing Steam, waiting for installs): Stop prevents it.
    case trying
    /// Stop was pressed and the preparation is winding down.
    case stopping
    /// The game was started again and hasn't shown up yet: it can't be called back, only the tries can be stopped.
    case starting
}

/// Automatic graphics: when a launch fails with a log to show for it, the next backend that makes sense is tried; what
/// worked is remembered per game; and a game that runs but shows nothing, or fails with nothing to show, gets a button for
/// the next one. The rules are core's (`GraphicsRetry`, `CompatResolver.graphicsChoice`); this carries them out.
extension AppModel {
    /// A game G-Player may try other graphics for (`GraphicsRetry.mayTry`).
    func canTryOtherGraphics(_ game: Game) -> Bool {
        guard let space = space(game.spaceID) else { return false }
        return GraphicsRetry.mayTry(game, spaceMayChange: space.mayChange)
    }

    /// What automatic graphics do for the game now; nil when the graphics aren't automatic.
    func graphicsChoice(for game: Game) -> CompatResolver.GraphicsChoice? {
        guard game.graphicsAreAutomatic, let space = space(game.spaceID) else { return nil }
        return CompatResolver.graphicsChoice(compatInput(for: game, in: space))
    }

    /// Forgets which graphics worked and which didn't: the next launch starts from the best one again.
    func forgetGraphics(for game: Game) {
        guard var g = self.game(game.id), g.autoGraphics != nil else { return }
        g.autoGraphics = nil
        update(g)
    }

    /// `GraphicsRetry.mayRestartSteamSilently`, for what is open in the game's space now.
    func mayRestartSteamSilently(for game: Game, in space: Space) -> Bool {
        let now = Date()
        var running = Set<UUID>(), busy = Set<UUID>()
        for other in state.games(in: space) where other.id != game.id {
            // The launcher's own tile is Steam, which is what gets closed.
            if other.kind == .game, gamePrograms[other.id] != nil { running.insert(other.id) }
            if preparing.contains(other.id) || (startingUntil[other.id].map { $0 > now } ?? false) { busy.insert(other.id) }
        }
        if let owner = steamRestarts[space.id] { busy.insert(owner) }
        return GraphicsRetry.mayRestartSteamSilently(for: game.id, running: running, busy: busy,
                                                     installsQueued: installingSpaces.contains(space.id))
    }

    func retryState(for game: Game) -> RetryState {
        let stopped = stoppedRetries.contains(game.id)
        if retryTasks[game.id] != nil { return stopped ? .stopping : .trying }
        if !stopped, autoLaunches[game.id]?.retried == true, isPreparing(game), !isRunning(game) { return .starting }
        return .none
    }

    /// Another try with other graphics is under way, or its game is still starting.
    func isRetrying(_ game: Game) -> Bool {
        switch retryState(for: game) {
        case .trying, .starting: true
        case .none, .stopping: false
        }
    }

    /// Ends the tries with other graphics for a game: the one under way starts nothing more (the work winds down and
    /// frees the game itself), and no other follows.
    func cancelRetry(_ id: UUID) {
        stoppedRetries.insert(id)
        retryTasks[id]?.task.cancel()
    }

    /// Stop while the game was started again and hasn't shown up. The start can't be undone, so this ends the tries and
    /// the learning for it, and nothing else.
    func stopTryingOtherGraphics(_ game: Game) {
        cancelRetry(game.id)
        autoLaunches[game.id] = nil
    }

    /// True when a try with other graphics was stopped: what it would start next is not started.
    func retryStopped(_ retry: GraphicsRetryLaunch?, _ id: UUID) -> Bool {
        retry != nil && (Task.isCancelled || stoppedRetries.contains(id))
    }

    // MARK: Watching a launch

    /// The launch to watch, when G-Player picked the graphics and they are what ran (`GraphicsRetry.learns`).
    func autoLaunch(for game: Game, in space: Space, backend: GraphicsBackend, retried: Bool,
                    steam: GraphicsRetry.SteamAtLaunch) -> AutoLaunch? {
        guard let choice = graphicsChoice(for: game),
              GraphicsRetry.learns(from: game, spaceMayChange: space.mayChange, choice: choice, steam: steam) else { return nil }
        return AutoLaunch(backend: backend, engineID: engineInfo(for: space).id, startedAt: Date(), retried: retried)
    }

    /// The launch to judge now that its game is gone: not one that went with a Steam G-Player is quitting.
    func launchToJudge(_ id: UUID) -> AutoLaunch? {
        guard let auto = autoLaunches[id], let game = game(id), !closingSteam.contains(game.spaceID) else { return nil }
        return auto
    }

    /// Writes what a launch taught about the game's graphics, unless the graphics have stopped being automatic since.
    private func learn(_ id: UUID, on engineID: String, _ change: (inout AutoGraphics) -> Void) {
        guard var g = game(id), canTryOtherGraphics(g) else { return }
        var learned = (g.autoGraphics ?? AutoGraphics(engineID: engineID)).current(on: engineID)
        change(&learned)
        let next: AutoGraphics? = learned.isEmpty ? nil : learned
        guard next != g.autoGraphics else { return }
        g.autoGraphics = next
        update(g)
    }

    /// The launch has run for a minute: its graphics work.
    private func recordWorking(_ id: UUID) {
        guard var auto = autoLaunches[id], !auto.settled else { return }
        auto.settled = true
        autoLaunches[id] = auto
        learn(id, on: auto.engineID) { $0.markWorked(auto.backend) }
    }

    /// A game that was seen running is gone: its launch worked if it had run for a minute by then.
    func settleIfWorked(_ id: UUID, since seen: Date, now: Date) {
        guard let auto = autoLaunches[id], now.timeIntervalSince(max(seen, auto.startedAt)) >= GraphicsRetry.secondsToWork else { return }
        recordWorking(id)
        autoLaunches[id] = nil
    }

    /// Games that keep running for a minute with the graphics Automatic picked. A launch that never showed up is dropped
    /// after five minutes, one whose game is gone at once.
    func noticeWorkingGames(_ found: [UUID: [WineProcess]]) {
        let now = Date()
        for (id, auto) in autoLaunches {
            let since: Date?
            if running[id]?.isRunning == true { since = auto.startedAt }
            else if found[id] != nil { since = firstSeen[id].map { max($0, auto.startedAt) } }
            else { since = nil }
            guard let since else {
                if auto.settled || now.timeIntervalSince(auto.startedAt) > 300 { autoLaunches[id] = nil }
                continue
            }
            if now.timeIntervalSince(since) >= GraphicsRetry.secondsToWork { recordWorking(id) }
        }
    }

    // MARK: When a launch ends

    /// What a launch with automatic graphics amounts to, once it has ended (`GraphicsRetry.outcome`). Returns what to tell the
    /// user: nil when the game is being started again with other graphics and there is nothing to say yet.
    ///
    /// Only a graphics failure or a crash found in a log makes G-Player try the next backend on its own, and only if the
    /// launch it would make can go ahead without asking; the failed backend is written down once that launch has started.
    /// Any other failure (it closed in seconds, it never showed up) is shown as it is, with a button to try other graphics.
    /// - Parameter auto: the launch as it was when it began. It no longer counts when a newer launch has replaced it.
    func learnFromEnd(_ found: [Diagnosis], ran seconds: Double, auto: AutoLaunch?, for id: UUID) -> [Diagnosis]? {
        guard let auto, autoLaunches[id]?.startedAt == auto.startedAt, !preparing.contains(id),
              let game = game(id), let space = space(game.spaceID), canTryOtherGraphics(game),
              let choice = graphicsChoice(for: game) else { return found }
        switch GraphicsRetry.outcome(of: found, ran: seconds, choice: choice, backend: auto.backend) {
        case .nothing:
            return found
        case .worked:
            autoLaunches[id] = nil
            if !auto.settled { learn(id, on: auto.engineID) { $0.markWorked(auto.backend) } }
            return found
        case .exhausted:
            autoLaunches[id] = nil
            return LogDiagnosis.mentioning(tried: choice.tried(afterFailing: auto.backend), in: found)
        case .offer:
            autoLaunches[id] = nil
            failedAutoLaunches[id] = auto
            return found
        case .retry(let next):
            autoLaunches[id] = nil
            failedAutoLaunches[id] = auto
            guard !stoppedRetries.contains(id), game.storeKey == nil || mayRestartSteamSilently(for: game, in: space) else {
                return found
            }
            var learned = (game.autoGraphics ?? AutoGraphics(engineID: auto.engineID)).current(on: auto.engineID)
            learned.markFailed(auto.backend)
            playAgain(game, String(localized: "\(auto.backend.displayName) didn't work for “\(game.title)”. Trying \(next.displayName)…"),
                      stopping: false, retry: GraphicsRetryLaunch(learned: learned, automatic: true)) { [weak self] cancelled in
                // It couldn't start (it would have asked something) or was stopped: the failure stays what is shown.
                if cancelled { self?.diagnoses[id] = found } else { self?.report(found, for: id) }
            }
            return nil
        }
    }

    /// The graphics to offer after a failure no log explained, or nil: nothing to offer.
    func graphicsOffer(for game: Game) -> GraphicsBackend? {
        guard didNotStart(game), let auto = failedAutoLaunches[game.id], canTryOtherGraphics(game),
              let space = space(game.spaceID), engineInfo(for: space).id == auto.engineID,
              let choice = graphicsChoice(for: game) else { return nil }
        return choice.next(afterFailing: auto.backend)
    }

    /// "Try Other Graphics" after a failure: the user's word that the graphics are to blame.
    func tryOtherGraphicsAfterFailure(_ game: Game) {
        guard let g = self.game(game.id), let auto = failedAutoLaunches[g.id], let next = graphicsOffer(for: g),
              !preparing.contains(g.id) else { return }
        failedAutoLaunches[g.id] = nil
        learn(g.id, on: auto.engineID) { $0.markFailed(auto.backend) }
        playAgain(g, String(localized: "Trying \(next.displayName) for “\(g.title)”…"), stopping: false,
                  retry: GraphicsRetryLaunch(learned: nil, automatic: false))
    }

    // MARK: A game that runs but shows nothing

    /// The graphics "Picture Missing? Try Other Graphics" would switch a running game to: nil when G-Player didn't start this
    /// run on automatic graphics, or nothing else is left to try.
    func otherGraphics(for game: Game) -> GraphicsBackend? {
        guard canTryOtherGraphics(game), isRunning(game), let choice = graphicsChoice(for: game) else { return nil }
        return GraphicsRetry.otherGraphics(for: choice, launched: autoLaunches[game.id]?.backend)
    }

    func askOtherGraphics(_ game: Game) {
        if let auto = autoLaunches[game.id], otherGraphics(for: game) != nil {
            pendingOtherGraphics = OtherGraphicsRequest(gameID: game.id, launched: auto)
        }
    }

    /// What the confirmation says. Steam is only said to restart when it will do so without asking.
    func otherGraphicsMessage(for request: OtherGraphicsRequest) -> String {
        guard let game = game(request.gameID) else { return "" }
        var parts = [String(localized: "“\(game.title)” closes, so anything you haven't saved may be lost.")]
        if case .steam = game.source, let space = space(game.spaceID) {
            parts.append(mayRestartSteamSilently(for: game, in: space) ? String(localized: "Steam restarts too.")
                                                                       : String(localized: "Steam may ask to restart first."))
        }
        if let next = graphicsChoice(for: game).flatMap({ GraphicsRetry.otherGraphics(for: $0, launched: request.launched.backend) }) {
            parts.append(String(localized: "G-Player then starts it again with other graphics (\(next.displayName))."))
        } else {
            parts.append(String(localized: "G-Player then starts it again with other graphics."))
        }
        return parts.joined(separator: " ")
    }

    /// The user confirmed: stops the game, writes its graphics down as not working, and plays it again with the next ones.
    /// If the game has quit since the question was asked, it is started anyway: the user said these graphics don't work.
    func tryOtherGraphics(_ request: OtherGraphicsRequest) {
        guard let g = game(request.gameID) else { return }
        guard !preparing.contains(g.id) else {
            errorMessage = String(localized: "“\(g.title)” is starting. Try again once it has opened.")
            return
        }
        let auto = request.launched
        guard let next = graphicsChoice(for: g).flatMap({ GraphicsRetry.otherGraphics(for: $0, launched: auto.backend) }) else {
            errorMessage = String(localized: "G-Player has no other graphics left to try for “\(g.title)”.")
            return
        }
        let wasRunning = isRunning(g)
        // Stopping it is the user's doing: what the game leaves behind is not a failure to show or to learn from.
        autoLaunches[g.id] = nil
        launches[g.id] = nil
        storeLaunches[g.id] = nil
        learn(g.id, on: auto.engineID) { $0.markFailed(auto.backend) }
        playAgain(g, String(localized: "Trying \(next.displayName) for “\(g.title)” instead of \(auto.backend.displayName)…"), stopping: wasRunning,
                  retry: GraphicsRetryLaunch(learned: nil, automatic: false))
    }

    // MARK: Starting again

    /// Plays the game again, with a note in the sidebar saying why. The note has Stop, which ends the tries.
    /// - Parameter ifNotStarted: runs when the game wasn't started; the flag says it was stopped by the user.
    private func playAgain(_ game: Game, _ note: String, stopping: Bool, retry: GraphicsRetryLaunch,
                           ifNotStarted: ((_ cancelled: Bool) -> Void)? = nil) {
        guard let space = space(game.spaceID) else { ifNotStarted?(false); return }
        let id = game.id
        // A try the user asks for starts a new round; an earlier Stop doesn't count against it.
        if !retry.automatic { stoppedRetries.remove(id) }
        preparing.insert(id)
        let activity = begin(String(localized: "Trying other graphics"), note)
        setStop(activity, help: String(localized: "Stop trying other graphics. Nothing more is started.")) { [weak self] in self?.cancelRetry(id) }
        let token = UUID()
        retryTasks[id] = GraphicsRetryTask(token: token, task: Task {
            var started = false
            if stopping { await stopAndWait(game, in: space) }
            if !Task.isCancelled, let latest = self.game(id) { started = await launch(latest, skipping: [], retry: retry) }
            let cancelled = Task.isCancelled || stoppedRetries.contains(id)
            // The game is free again, unless a newer try has taken it over.
            if retryTasks[id]?.token == token {
                retryTasks[id] = nil
                preparing.remove(id)
            }
            cancellers[activity] = nil
            if !started { ifNotStarted?(cancelled) }
            // Long enough to read; the game takes a while to show up.
            if started && !cancelled { try? await Task.sleep(for: .seconds(6)) }
            end(activity)
        })
    }

    /// Stops the game's own programs (never Steam) and waits for them to be gone, up to 15 seconds.
    private func stopAndWait(_ game: Game, in space: Space) async {
        running[game.id]?.terminate()
        stopPrograms(of: game, in: space)
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(500))
            let gone = await Task.detached(priority: .userInitiated) {
                RunningGames.programs(of: [(game: game, space: space)], in: WineProcesses.snapshot()).isEmpty
            }.value
            if gone || Task.isCancelled { break }
        }
        firstSeen[game.id] = nil                            // the launch that follows is a new one
        refreshPrograms()
    }
}
