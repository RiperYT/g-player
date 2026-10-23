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
        /// An Epic game G-Player installed with Legendary, without Epic's launcher. G-Player starts its program itself, with
        /// the parameters Legendary gives for that launch (`LegendaryLaunch`). `appName` is Legendary's name for the game.
        case legendary(appName: String)

        public var label: String {
            switch self {
            case .executable: "Added by you"
            case .steam: "Steam"
            case .epic: "Epic"
            case .legendary: "Epic Games"
            }
        }

        /// G-Player starts the game's own program (an .exe the user added, or an Epic game installed with Legendary), where Steam
        /// and Epic's launcher start theirs themselves.
        public var startsProgramItself: Bool {
            switch self {
            case .executable, .legendary: true
            case .steam, .epic: false
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
    /// Hidden from All Games, Recently Played, spaces and search. Optional so older library files still load.
    public var hidden: Bool?
    /// The program's own icon, read from its .exe, as a PNG file name inside the library's Covers folder.
    public var iconFile: String?
    /// Profile and plain-word options (window, Retina, frame rate, fixes). Nil means the defaults.
    public var options: LaunchOptions?
    /// What the game is (engine, DirectX, anti-cheat), cached. Nil until analysed.
    public var analysis: GameAnalysis?
    /// What G-Player learned about the game's graphics while Automatic chose them. Nil until it learned something, and
    /// optional so older library files still load.
    public var autoGraphics: AutoGraphics?

    public var launchOptions: LaunchOptions { options ?? .default }

    /// The graphics are Automatic: the Recommended or Fast profile with no backend chosen by hand. Only then does
    /// G-Player try other backends by itself and remember what worked. Compatible and Custom are the user's own choice.
    public var graphicsAreAutomatic: Bool {
        kind == .game && graphics == .auto && (launchOptions.profile == .recommended || launchOptions.profile == .fast)
    }

    public init(id: UUID = UUID(), title: String, kind: Kind = .game, spaceID: UUID, source: Source = .executable,
                executablePath: String? = nil, arguments: [String] = [], graphics: GraphicsBackend = .auto,
                environment: [String: String] = [:], coverFile: String? = nil, addedAt: Date = Date(),
                lastPlayedAt: Date? = nil, secondsPlayed: Double = 0, hidden: Bool? = nil, iconFile: String? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.spaceID = spaceID; self.source = source
        self.executablePath = executablePath; self.arguments = arguments; self.graphics = graphics
        self.environment = environment; self.coverFile = coverFile; self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt; self.secondsPlayed = secondsPlayed; self.hidden = hidden
        self.iconFile = iconFile
    }

    /// Reads every field as the synthesized decoder would, except `autoGraphics`: what G-Player learned is a convenience,
    /// so a value there that can't be read means nothing was learned, and never costs the game. (A field added to `Game`
    /// has to be read here too; `GameDecodingTests` fails when one is left out.)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decode(Kind.self, forKey: .kind)
        spaceID = try c.decode(UUID.self, forKey: .spaceID)
        source = try c.decode(Source.self, forKey: .source)
        executablePath = try c.decodeIfPresent(String.self, forKey: .executablePath)
        arguments = try c.decode([String].self, forKey: .arguments)
        graphics = try c.decode(GraphicsBackend.self, forKey: .graphics)
        environment = try c.decode([String: String].self, forKey: .environment)
        coverFile = try c.decodeIfPresent(String.self, forKey: .coverFile)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        secondsPlayed = try c.decode(Double.self, forKey: .secondsPlayed)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
        iconFile = try c.decodeIfPresent(String.self, forKey: .iconFile)
        options = try c.decodeIfPresent(LaunchOptions.self, forKey: .options)
        analysis = try c.decodeIfPresent(GameAnalysis.self, forKey: .analysis)
        autoGraphics = c.value(.autoGraphics, default: nil)
    }

    public var isHidden: Bool { hidden == true }

    /// Only games the user added can be removed. A store game would come back, a launcher is rebuilt, so those are hidden instead.
    public var canRemove: Bool { source == .executable && kind == .game }

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
    public var storeKey: String? { Self.storeKey(for: source) }

    public static func storeKey(for source: Source) -> String? {
        switch source {
        case .executable: nil
        case .steam(let id): "steam:\(id)"
        case .epic(let name, _): "epic:\(name)"
        // Not a store key: the store doesn't list these (`StoreMerge`), Legendary does (`EpicGames.merge`).
        case .legendary: nil
        }
    }
}
