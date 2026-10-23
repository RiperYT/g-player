import Foundation

/// Moving spaces off retired engines (`EngineInfo.replacedBy`) onto their replacements, so that after an update everything
/// keeps working as it did: a space G-Player may change never ends up on an engine that isn't there, nothing is switched
/// under a running program, a space of another app is not touched until the user says yes, and the old engine goes once
/// nothing uses it and its replacement is there. The decisions are pure; `AppModel` supplies what is installed and what is
/// busy, and carries the plan out.
public enum EngineMigration {
    public struct Plan: Equatable, Sendable {
        public struct Switch: Equatable, Sendable {
            public let space: UUID
            public let from: String
            public let to: String

            public init(space: UUID, from: String, to: String) { self.space = space; self.from = from; self.to = to }
        }

        /// Spaces to put on another engine now.
        public var switches: [Switch] = []
        /// Engines to install in the background, so that spaces on a retired engine can move and the retired engine can go:
        /// the replacements that aren't installed.
        public var install: [String] = []
        /// Retired engines that are installed, whose replacement is installed and that no space stays on: their folders can go.
        public var remove: [String] = []

        public init(switches: [Switch] = [], install: [String] = [], remove: [String] = []) {
            self.switches = switches; self.install = install; self.remove = remove
        }

        public var isEmpty: Bool { switches.isEmpty && install.isEmpty && remove.isEmpty }
    }

    /// What the app knows about a space besides the programs the process table shows: work it has begun there.
    public struct SpaceActivity: Equatable, Sendable {
        /// The space is being moved to another engine.
        public var movingEngine: Bool
        /// Installs or store setups are queued or running in it.
        public var installing: Bool
        /// Something is queued for it or holds its queue.
        public var queued: Bool
        /// Launches that have begun there and whose program hasn't started yet.
        public var launchesStarting: Int
        /// A game of the space is between pressing Play and its program starting, or is running.
        public var gameStarting: Bool
        public var gameRunning: Bool
        /// Add Game is working in it (from choosing the space until the installer has quit or the game was copied).
        public var addingGame: Bool

        public init(movingEngine: Bool = false, installing: Bool = false, queued: Bool = false, launchesStarting: Int = 0,
                    gameStarting: Bool = false, gameRunning: Bool = false, addingGame: Bool = false) {
            self.movingEngine = movingEngine; self.installing = installing; self.queued = queued
            self.launchesStarting = launchesStarting; self.gameStarting = gameStarting; self.gameRunning = gameRunning
            self.addingGame = addingGame
        }

        public var isActive: Bool {
            movingEngine || installing || queued || launchesStarting > 0 || gameStarting || gameRunning || addingGame
        }
    }

    /// Something runs, starts or is queued in the space, so its engine's files are in use and it can't move. Programs count
    /// whatever they are, Wine's own services too (`explorer.exe /desktop` and `services.exe` stay while anything else does);
    /// the Wine server and the loader of the engine aren't Windows programs and don't show among them, which is why an
    /// engine's folder is looked at once more before it is deleted (`mayRemove`).
    public static func isInUse(_ space: Space, processes: [WineProcess], activity: SpaceActivity) -> Bool {
        activity.isActive || !WineProcesses.programs(in: space, from: processes).isEmpty
    }

    /// A retired engine's folder may be deleted: a plan made from a fresh look says nothing is left on it, and no process runs
    /// a file from inside it (Wine's own `wine-preloader` and `wineserver` included, which the Windows programs don't show).
    /// Anything else is tried again at the next look.
    public static func mayRemove(_ id: String, plan: Plan, folder: URL, executables: [ProcessExecutable]) -> Bool {
        plan.remove.contains(id) && WineProcesses.executables(inside: folder, from: executables).isEmpty
    }

    /// What to do about the spaces on retired engines, given the ids of the engines installed (retired ones too) and the
    /// spaces something runs or is being started in (`busy`).
    ///
    /// Only a space G-Player may change moves (`Space.mayChange`): the first start on the new Wine updates the files in its
    /// prefix, which a space of another app is spared until the user says yes. One that may change moves when
    /// its retired engine isn't installed (it would otherwise fall back to Wine Staging: the replacement installs the first
    /// time a program starts there), or when the replacement is installed and the space is idle. Every other space stays on
    /// its retired engine, and so does that engine, until nothing is left on it. A retired engine that is installed without
    /// its replacement asks for the replacement to be installed, whether a space is on it or not; it is removed only once the
    /// replacement is installed and no space is left on it.
    public static func plan(spaces: [Space], installed: Set<String>, busy: Set<UUID>) -> Plan {
        var plan = Plan()
        var staying = Set<String>()
        func install(_ id: String) { if !plan.install.contains(id) { plan.install.append(id) } }
        for space in spaces {
            guard let old = EngineCatalog.info(space.engineID), let new = EngineCatalog.replacement(of: old) else { continue }
            if space.mayChange, !installed.contains(old.id) || (installed.contains(new.id) && !busy.contains(space.id)) {
                plan.switches.append(Plan.Switch(space: space.id, from: old.id, to: new.id))
                continue
            }
            staying.insert(old.id)
            if !installed.contains(new.id) { install(new.id) }
        }
        for old in EngineCatalog.retired where installed.contains(old.id) {
            guard let new = EngineCatalog.replacement(of: old) else { continue }
            if !installed.contains(new.id) { install(new.id) }
            else if !staying.contains(old.id) { plan.remove.append(old.id) }
        }
        return plan
    }

    /// A program is about to start in `space` on `engine`. When the space is on a retired engine that isn't installed and `engine`
    /// is its replacement (what `ensureEngine` hands back then), the space moves now, so that what the start records, such as
    /// the graphics it learns, names the engine it ran on. Nothing can run from an engine that isn't there, so nothing is in the
    /// way. Nil for every other start.
    public static func moveForStart(_ space: Space, on engine: EngineInfo, installed: Set<String>) -> Plan.Switch? {
        guard let old = EngineCatalog.info(space.engineID), !installed.contains(old.id) else { return nil }
        return plan(spaces: [space], installed: installed, busy: []).switches.first { $0.to == engine.id }
    }

    /// The user switches `space` to `info` on its page. From a retired engine to its replacement it is the move the app makes by
    /// itself (the same Wine, so what was learned about the games' graphics and the launch records go with the space). Nil for any
    /// other switch: another Wine learns afresh.
    public static func switchBetweenRevisions(of space: Space, to info: EngineInfo) -> Plan.Switch? {
        guard space.engineID != info.id, EngineCatalog.isRevision(space.engineID, of: info) else { return nil }
        return Plan.Switch(space: space.id, from: space.engineID, to: info.id)
    }

    /// Puts the plan's spaces on their new engines, and what G-Player learned about their games' graphics with them: the
    /// replacement is the same Wine, so the learning still holds. A space that is no longer on the engine the plan saw (the
    /// user switched it meanwhile) is left as it is, and so is one G-Player may not change (the user said no meanwhile).
    public static func apply(_ plan: Plan, to state: inout LibraryState) {
        for move in plan.switches {
            guard let i = state.spaces.firstIndex(where: { $0.id == move.space && $0.engineID == move.from }),
                  state.spaces[i].mayChange else { continue }
            state.spaces[i].engineID = move.to
            for j in state.games.indices where state.games[j].spaceID == move.space && state.games[j].autoGraphics?.engineID == move.from {
                state.games[j].autoGraphics?.engineID = move.to
            }
        }
    }

    /// The one sentence that says why a replacement is downloading in the background.
    public static func updateNote(for info: EngineInfo) -> String {
        "Updating \(info.name) (adds video playback in games). Your games keep working meanwhile."
    }
}
