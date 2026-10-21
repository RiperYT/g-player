import Foundation

/// Something the library can start: a game, or an app such as Steam.
public struct Game: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case game, app }

    public enum Source: Codable, Hashable, Sendable {
        /// An executable the user added (portable game or installed program).
        case executable
        /// A Steam game, started through Steam with `-applaunch`.
        case steam(appID: String)
        /// An Epic game, started through the Epic Games Launcher.
        case epic(appName: String, launchURI: String)

        public var label: String {
            switch self {
            case .executable: "Added by you"
            case .steam: "Steam"
            case .epic: "Epic"
            }
        }
    }

    public var id: UUID
    public var title: String
    public var kind: Kind
    public var spaceID: UUID
    public var source: Source
    /// Path of the .exe: relative to the space folder when it lives inside it, absolute otherwise.
    public var executablePath: String?
    public var arguments: [String]
    public var graphics: GraphicsBackend
    public var environment: [String: String]
    /// File name inside the library's Covers folder.
    public var coverFile: String?
    public var addedAt: Date
    public var lastPlayedAt: Date?
    public var secondsPlayed: Double

    public init(id: UUID = UUID(), title: String, kind: Kind = .game, spaceID: UUID, source: Source = .executable,
                executablePath: String? = nil, arguments: [String] = [], graphics: GraphicsBackend = .auto,
                environment: [String: String] = [:], coverFile: String? = nil, addedAt: Date = Date(),
                lastPlayedAt: Date? = nil, secondsPlayed: Double = 0) {
        self.id = id; self.title = title; self.kind = kind; self.spaceID = spaceID; self.source = source
        self.executablePath = executablePath; self.arguments = arguments; self.graphics = graphics
        self.environment = environment; self.coverFile = coverFile; self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt; self.secondsPlayed = secondsPlayed
    }

    /// The executable on the Mac.
    public func executableURL(in space: Space) -> URL? {
        guard let p = executablePath, !p.isEmpty else { return nil }
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : space.url.appendingPathComponent(p)
    }

    /// Stores `url` relative to the space when possible, so a moved library keeps working.
    public static func storedPath(for url: URL, in space: Space) -> String {
        Files.relativePath(of: url, to: space.url) ?? url.standardizedFileURL.path
    }

    /// Identity used to avoid adding the same store game twice.
    public var storeKey: String? {
        switch source {
        case .executable: nil
        case .steam(let id): "steam:\(id)"
        case .epic(let name, _): "epic:\(name)"
        }
    }
}
