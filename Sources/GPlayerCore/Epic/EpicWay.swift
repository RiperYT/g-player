import Foundation

/// The two ways to Epic's games, which the Epic Games card in Get Apps offers one under the other, each with what it trades.
public enum EpicWay: CaseIterable, Sendable {
    /// Epic's own launcher, in a space of its own (`AppPresets.epic`).
    case launcher
    /// Epic's games through Legendary, without the launcher (`EpicGames`).
    case legendary

    public var title: String {
        switch self {
        case .launcher: AppPresets.epic.name
        case .legendary: "Without the launcher"
        }
    }

    public var detail: String {
        switch self {
        case .launcher: AppPresets.epic.summary
        case .legendary: "Faster, through Legendary, an open-source Epic client not made by Epic."
        }
    }

    /// The official launcher is the recommended way; the other is the alternative.
    public var badge: String { self == .launcher ? "Recommended" : "Alternative" }
}
