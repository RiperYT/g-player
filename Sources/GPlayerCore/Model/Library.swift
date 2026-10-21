import Foundation

/// Everything G-Player remembers, saved as `library.json` in the library folder.
public struct LibraryState: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var spaces: [Space] = []
    public var games: [Game] = []
    /// Store games the user removed; discovery won't add them back.
    public var hiddenStoreKeys: Set<String> = []

    public init() {}

    public func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }
    public func games(in space: Space) -> [Game] { games.filter { $0.spaceID == space.id } }
}
