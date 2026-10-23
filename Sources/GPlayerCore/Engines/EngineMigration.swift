import Foundation

/// Moving spaces off retired engines (`EngineInfo.replacedBy`) onto their replacements, so that after an update everything
/// keeps working as it did: a space never ends up on an engine that isn't there, nothing is switched under a running
/// program, and the old engine goes once nothing uses it. The decisions are pure; `AppModel` supplies what is installed and
/// what is busy, and carries the plan out.
public enum EngineMigration {
    public struct Plan: Equatable, Sendable {
        public struct Switch: Equatable, Sendable {
            public let space: UUID
            public let from: String
            public let to: String
        }

        /// Spaces to put on another engine now.
        public var switches: [Switch] = []
        /// Engines to install in the background, so spaces still on a retired engine can move: the replacements that aren't
        /// installed.
        public var install: [String] = []
        /// Retired engines no space refers to any more: their folders can go.
        public var remove: [String] = []

        public var isEmpty: Bool { switches.isEmpty && install.isEmpty && remove.isEmpty }
    }

    /// What to do about the spaces on retired engines, given the ids of the engines installed (retired ones too) and the
    /// spaces something runs or is being started in (`busy`).
    ///
    /// A space moves when its retired engine isn't installed (it would otherwise fall back to Wine Staging: the replacement
    /// installs the first time a program starts there), or when the replacement is installed and the space is idle. A space on
    /// an installed retired engine stays on it, busy or while the replacement is still to come, and the replacement is to be
    /// installed. A retired engine goes once no space is left on it.
    public static func plan(spaces: [Space], installed: Set<String>, busy: Set<UUID>) -> Plan {
        var plan = Plan()
        var staying = Set<String>()
        for space in spaces {
            guard let old = EngineCatalog.info(space.engineID), let new = EngineCatalog.replacement(of: old) else { continue }
            if !installed.contains(old.id) || (installed.contains(new.id) && !busy.contains(space.id)) {
                plan.switches.append(Plan.Switch(space: space.id, from: old.id, to: new.id))
                continue
            }
            staying.insert(old.id)
            if !installed.contains(new.id), !plan.install.contains(new.id) { plan.install.append(new.id) }
        }
        for old in EngineCatalog.retired where installed.contains(old.id) && !staying.contains(old.id) {
            plan.remove.append(old.id)
        }
        return plan
    }

    /// Puts the plan's spaces on their new engines, and what G-Player learned about their games' graphics with them: the
    /// replacement is the same Wine, so the learning still holds. A space that is no longer on the engine the plan saw (the user
    /// switched it meanwhile) is left as it is.
    public static func apply(_ plan: Plan, to state: inout LibraryState) {
        for move in plan.switches {
            guard let i = state.spaces.firstIndex(where: { $0.id == move.space && $0.engineID == move.from }) else { continue }
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
