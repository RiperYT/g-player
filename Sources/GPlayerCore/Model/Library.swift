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

    /// The library after its folder moved from `old` to `new`: the spaces G-Player made (in `old/Spaces`) are in `new/Spaces`
    /// now. `library.json` keeps each space's absolute path, so without this a moved library finds none of them. Only those
    /// spaces move: one found elsewhere on the Mac (a bottle, a prefix) stays where it was, also when it lies inside the old
    /// folder (a library in ~/Games next to a prefix of the user's own). Games keep their paths: those inside a space are
    /// relative to it.
    public func movingLibrary(from old: URL, to new: URL) -> LibraryState {
        // The folder as it was written into library.json (the user's own spelling) and as G-Player standardizes it.
        let prefixes = Set([old.path, old.standardizedFileURL.path].map { path in
            (path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path) + "/Spaces/"
        })
        let newSpaces = LibraryPaths(root: new).spaces.path
        var moved = self
        for i in moved.spaces.indices where moved.spaces[i].origin == .managed {
            let path = moved.spaces[i].path
            guard let prefix = prefixes.first(where: { path.hasPrefix($0) }) else { continue }
            moved.spaces[i].path = newSpaces + "/" + path.dropFirst(prefix.count)
        }
        return moved
    }

    /// What All Games, Recently Played, search and the space pages list.
    public var visibleGames: [Game] { games.filter { !$0.isHidden } }
    public var hiddenGames: [Game] { games.filter(\.isHidden) }
    public func visibleGames(in space: Space) -> [Game] { games(in: space).filter { !$0.isHidden } }
    public func hiddenGames(in space: Space) -> [Game] { games(in: space).filter(\.isHidden) }
}
