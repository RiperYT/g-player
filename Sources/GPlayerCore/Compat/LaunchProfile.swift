import Foundation

/// The ready-made ways to start a game. People pick one of these instead of editing Wine settings.
public enum LaunchProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Everything G-Player knows: engine defaults, known fixes, the best graphics for the space.
    case recommended
    /// For games that don't start: Wine's own renderer, a window, no tricks.
    case compatible
    /// The quickest graphics path in this space (D3DMetal where available, else DXVK).
    case fast
    /// The graphics and arguments set by hand under Advanced.
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recommended: "Recommended"
        case .compatible: "Compatible"
        case .fast: "Fast"
        case .custom: "Custom"
        }
    }

    public var summary: String {
        switch self {
        case .recommended: "Known fixes for this game and the best graphics for its engine."
        case .compatible: "Slower, but starts more games. Try it when a game won't open."
        case .fast: "The quickest graphics this space has."
        case .custom: "Graphics you choose under Advanced."
        }
    }

    /// The profiles worth offering for a space's engine. Fast needs D3DMetal; on an engine without it, Fast
    /// would do exactly what Recommended does, so it isn't offered.
    public static func available(for engine: EngineInfo) -> [LaunchProfile] {
        allCases.filter { $0 != .fast || engine.backends.contains(.d3dmetal) }
    }

    /// The profile a launch really uses: a stored Fast profile counts as Recommended on an engine without D3DMetal
    /// (the space's engine may have changed since it was chosen).
    public func effective(on engine: EngineInfo) -> LaunchProfile {
        self == .fast && !engine.backends.contains(.d3dmetal) ? .recommended : self
    }

    public var symbol: String {
        switch self {
        case .recommended: "sparkles"
        case .compatible: "lifepreserver"
        case .fast: "hare"
        case .custom: "slider.horizontal.3"
        }
    }
}

/// Fullscreen or a window, said once for every engine.
public enum WindowMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic, fullscreen, windowed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "As the game decides"
        case .fullscreen: "Fullscreen"
        case .windowed: "In a window"
        }
    }
}

/// Per-game choices in plain words. Stored on the game.
public struct LaunchOptions: Codable, Sendable, Hashable {
    public var profile: LaunchProfile
    public var windowMode: WindowMode
    /// Render at the Mac's full Retina resolution (sharper, slower).
    public var retina: Bool
    /// Apple's Metal performance overlay with the frame rate.
    public var showFrameRate: Bool
    public var useKnownFixes: Bool
    public var disabledFixIDs: [String]

    public init(profile: LaunchProfile = .recommended, windowMode: WindowMode = .automatic, retina: Bool = false,
                showFrameRate: Bool = false, useKnownFixes: Bool = true, disabledFixIDs: [String] = []) {
        self.profile = profile; self.windowMode = windowMode; self.retina = retina
        self.showFrameRate = showFrameRate; self.useKnownFixes = useKnownFixes; self.disabledFixIDs = disabledFixIDs
    }

    /// Every field is optional on disk, so a library written by an older or newer G-Player still opens.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = c.value(.profile, default: .recommended)
        windowMode = c.value(.windowMode, default: .automatic)
        retina = c.value(.retina, default: false)
        showFrameRate = c.value(.showFrameRate, default: false)
        useKnownFixes = c.value(.useKnownFixes, default: true)
        disabledFixIDs = c.value(.disabledFixIDs, default: [])
    }

    public static let `default` = LaunchOptions()
}
