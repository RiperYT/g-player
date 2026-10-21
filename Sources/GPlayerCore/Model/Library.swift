import Foundation

/// Everything G-Player remembers, saved as `library.json` in the library folder.
public struct LibraryState: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var spaces: [Space] = []
    public var games: [Game] = []
    /// Older libraries kept hidden store games here. Discovery turns them into entries with `hidden` set
    /// (see `StoreMerge`). Still decoded so old files load.
    public var hiddenStoreKeys: Set<String> = []

    public init() {}

    public func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }
    public func games(in space: Space) -> [Game] { games.filter { $0.spaceID == space.id } }

    /// What All Games, Recently Played, search and the space pages list.
    public var visibleGames: [Game] { games.filter { !$0.isHidden } }
    public var hiddenGames: [Game] { games.filter(\.isHidden) }
    public func visibleGames(in space: Space) -> [Game] { games(in: space).filter { !$0.isHidden } }
    public func hiddenGames(in space: Space) -> [Game] { games(in: space).filter(\.isHidden) }
}
