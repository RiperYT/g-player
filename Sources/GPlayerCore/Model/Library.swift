import Foundation

/// Everything G-Player remembers, saved as `library.json` in the library folder.
public struct LibraryState: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var spaces: [Space] = []
    public var games: [Game] = []
    /// Older libraries kept hidden store games here. Discovery turns them into entries with `hidden` set
    /// (see `StoreMerge`). Still decoded so old files load.
    public var hiddenStoreKeys: Set<String> = []
    /// Games this version of G-Player can't read: one a newer version wrote with a source or a field this one doesn't know. They
    /// are kept exactly as they were written and written back on every save, so an older version never costs a newer one its
    /// games, and they are not shown or used. A library file that is damaged in any other way is still refused.
    public var unreadableGames: [JSONValue] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case version, spaces, games, hiddenStoreKeys }

    /// A game that can't be read goes to `unreadableGames` instead of failing the whole library.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        spaces = try c.decode([Space].self, forKey: .spaces)
        hiddenStoreKeys = try c.decode(Set<String>.self, forKey: .hiddenStoreKeys)
        var list = try c.nestedUnkeyedContainer(forKey: .games)
        while !list.isAtEnd {
            switch try list.decode(GameRecord.self) {
            case .game(let game): games.append(game)
            case .unreadable(let raw): unreadableGames.append(raw)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(spaces, forKey: .spaces)
        try c.encode(hiddenStoreKeys, forKey: .hiddenStoreKeys)
        var list = c.nestedUnkeyedContainer(forKey: .games)
        for game in games { try list.encode(game) }
        for raw in unreadableGames { try list.encode(raw) }
    }

    /// One entry of `games`: a game, or what could not be read as one.
    private enum GameRecord: Decodable {
        case game(Game)
        case unreadable(JSONValue)

        init(from decoder: Decoder) throws {
            if let game = try? Game(from: decoder) { self = .game(game) }
            else { self = .unreadable(try JSONValue(from: decoder)) }
        }
    }

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
