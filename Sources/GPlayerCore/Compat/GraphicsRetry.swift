import Foundation

/// When G-Player may change a game's graphics by itself, and what it learns from a launch. The rules live here, pure and
/// tested; the app only carries them out. The guiding rule: G-Player acts on its own only on evidence in a log. Anything
/// that merely looks like a failure (a player quitting after half a minute, a slow first start of Steam, a program that
/// hands over to the real one) is never written down as the backend's fault; the user may say so with a button.
public enum GraphicsRetry {
    /// How long a game must keep running for its graphics to count as working.
    public static let secondsToWork: Double = 60
    /// A game that ended sooner than this (and left evidence of failing in a log) never got to be played, so its graphics
    /// are to blame. One that ran longer may have been played, or have recovered (a D3D12 failure line followed by a
    /// working DirectX 11 fallback, a page fault as it exits): that is the user's to judge.
    public static let secondsBeforePlayable: Double = 30

    /// Games G-Player may try other graphics for: automatic graphics, in a space it may change (the backend's DLLs reach no
    /// other), and not an Epic game, whose launcher passes on the settings it started with, so a new backend wouldn't
    /// reach the game.
    public static func mayTry(_ game: Game, spaceMayChange: Bool) -> Bool {
        guard spaceMayChange, game.graphicsAreAutomatic else { return false }
        if case .epic = game.source { return false }
        return true
    }

    // MARK: Which launches teach

    /// Where Steam stood when a game was started.
    public enum SteamAtLaunch: Sendable, Equatable {
        /// The game doesn't go through Steam.
        case notSteam
        /// Steam wasn't open, so this launch started it with the game's settings.
        case started
        /// Steam was open, G-Player knows how it was started, and the game needs nothing else.
        case runningAsPlanned
        /// Steam was open with settings G-Player doesn't know, or other than the game's (the user chose to play with it):
        /// the game runs with whatever Steam has.
        case runningOtherwise
    }

    public static func steamAtLaunch(isSteamGame: Bool, wasRunning: Bool, knownSettings: LauncherSettings?,
                                     needsFreshLauncher: Bool) -> SteamAtLaunch {
        guard isSteamGame else { return .notSteam }
        guard wasRunning else { return .started }
        return knownSettings != nil && !needsFreshLauncher ? .runningAsPlanned : .runningOtherwise
    }

    /// A launch G-Player learns from: it chose the graphics (automatic, in a space it may change), there was more than one
    /// to choose from, and they are what the game really runs with.
    public static func learns(from game: Game, spaceMayChange: Bool, choice: CompatResolver.GraphicsChoice,
                              steam: SteamAtLaunch) -> Bool {
        mayTry(game, spaceMayChange: spaceMayChange) && choice.candidates.count > 1 && steam != .runningOtherwise
    }

    // MARK: When a launch ends

    public enum Outcome: Sendable, Equatable {
        /// Nothing to learn: it ended well, or in a way graphics don't explain (missing components, anti-cheat).
        case nothing
        /// The game ran for a minute: these graphics work.
        case worked
        /// A log shows the graphics (or the game) failing, the game ended within seconds of starting, and another backend
        /// is worth trying: G-Player does it by itself.
        case retry(GraphicsBackend)
        /// It failed, but not in a way that proves the graphics' fault (no log says why: it closed within seconds or never
        /// showed up; or a log shows trouble in a game that ran for a while), and another backend is worth trying: the user
        /// may ask for it.
        case offer(GraphicsBackend)
        /// It failed, and every backend has been tried.
        case exhausted
    }

    /// What a launch with automatic graphics, which used `backend`, amounts to. Only a graphics failure or a crash found in a
    /// log (Wine's, the game's, Unity's) is evidence, and only for a game that ended before it could have been played;
    /// closing right away is no evidence at all.
    public static func outcome(of found: [Diagnosis], ran seconds: Double, choice: CompatResolver.GraphicsChoice,
                               backend: GraphicsBackend) -> Outcome {
        if seconds >= secondsToWork { return .worked }
        let kinds = Set(found.map(\.kind))
        guard !kinds.isDisjoint(with: [.graphics, .crash, .closedRightAway]),
              kinds.isDisjoint(with: [.missingComponent, .antiCheat]) else { return .nothing }
        guard let next = choice.next(afterFailing: backend) else { return .exhausted }
        let evidence = !kinds.isDisjoint(with: [.graphics, .crash]) && seconds < secondsBeforePlayable
        return evidence ? .retry(next) : .offer(next)
    }

    // MARK: Steam

    /// How long a store game may take to show up before it counts as not opening: a minute when its launcher was already
    /// running, four when the launch started the launcher too. A Steam that starts cold (and updates Wine's files on the
    /// first start on a new engine, or checks for its own update after a crash) can take over a minute before it even
    /// starts the game, and calling that a failure offered other graphics, which meant restarting Steam, again and again.
    public static func secondsToShowUp(launcherWasRunning: Bool) -> TimeInterval { launcherWasRunning ? 60 : 240 }

    /// Whether Steam may be closed for a retry without asking: nothing else in its space is open, starting or being
    /// installed, so nothing is lost with it. Otherwise the usual "Steam is already running" question is asked.
    /// - Parameters:
    ///   - gameID: the game being tried again.
    ///   - running: library entries with a program open in the space.
    ///   - busy: library entries between pressing Play and their program (preparing or starting), and the game whose retry
    ///     is already restarting Steam.
    ///   - installsQueued: components are being installed in the space or wait to be.
    public static func mayRestartSteamSilently(for gameID: UUID, running: Set<UUID>, busy: Set<UUID>,
                                               installsQueued: Bool) -> Bool {
        !installsQueued && running.subtracting([gameID]).isEmpty && busy.subtracting([gameID]).isEmpty
    }

    // MARK: A game that runs but shows nothing

    /// The graphics the "picture missing" button would switch a running game to. Only for a run G-Player started on automatic
    /// graphics (`launched`), since only then does it know what the game runs with.
    public static func otherGraphics(for choice: CompatResolver.GraphicsChoice, launched: GraphicsBackend?) -> GraphicsBackend? {
        launched.flatMap { choice.alternative(to: $0) }
    }
}
