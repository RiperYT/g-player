import Foundation

/// When a store app that was just set up (Steam) takes the library to its tile. Someone looking at something else isn't taken away
/// from it: the library says what to do next in a note at the top of All Games instead.
public enum StoreReadyMove {
    /// Where the person is when the setup ends.
    public enum Place: Equatable, Sendable {
        /// Get Apps' list: Install was pressed there, and the tile is where it leads.
        case getApps
        /// A page opened over Get Apps' list (the Epic Games page): someone is working there.
        case getAppsPage
        /// The page of the space the app was set up in.
        case storeSpace
        /// All Games, with or without a game selected (the one being looked at stays).
        case allGames(gameSelected: Bool)
        /// Anything else: Recently Played, Files, another space, Hidden.
        case elsewhere
    }

    public static func movesToTile(from place: Place) -> Bool {
        switch place {
        case .getApps, .storeSpace: true
        case .allGames(let gameSelected): !gameSelected
        case .getAppsPage, .elsewhere: false
        }
    }
}
