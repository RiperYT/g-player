import Foundation

/// How Direct3D calls become Metal.
public enum GraphicsBackend: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The engine's best default: DXVK on Wine Staging; D3DMetal on Apple's toolkit and, once D3DMetal is copied in,
    /// on G-Player Wine (DXVK there without it, and for 32-bit programs, which D3DMetal doesn't run).
    case auto
    /// DirectX 10/11 to Vulkan, then MoltenVK to Metal. Open source.
    case dxvk
    /// Wine's own translation to OpenGL. Slowest, most compatible with old DirectX 9 games.
    case wined3d
    /// Apple's DirectX 11/12 to Metal translator from the Game Porting Toolkit.
    case d3dmetal
    /// DirectX 10/11 straight to Metal (3Shain's DXMT). Open source; needs G-Player Wine.
    case dxmt

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: String(localized: "Automatic")
        case .dxvk: "DXVK"
        case .wined3d: "WineD3D"
        case .d3dmetal: "D3DMetal"
        case .dxmt: "DXMT"
        }
    }

    public var summary: String {
        switch self {
        case .auto: String(localized: "G-Player picks the graphics and, if the game doesn't start, tries the next ones by itself.")
        case .dxvk: String(localized: "DirectX 10 and 11 through Vulkan and MoltenVK.")
        case .wined3d: String(localized: "Wine's OpenGL renderer. Good for older DirectX 9 games.")
        case .d3dmetal: String(localized: "Apple's translator for DirectX 11 and 12, from your own Game Porting Toolkit.")
        case .dxmt: String(localized: "DirectX 10 and 11 straight to Metal. Needs the G-Player Wine engine.")
        }
    }
}

extension EngineInfo {
    /// The line under a graphics picker. Automatic is the same under every engine: it isn't named after what it picks
    /// first, as that changes. With the Custom profile it means this engine's usual graphics, which nothing switches.
    public func graphicsHint(for choice: GraphicsBackend, profile: LaunchProfile) -> String {
        let shown = backends.contains(choice) ? choice : .auto
        guard shown == .auto, profile == .custom else { return shown.summary }
        return String(localized: "Uses \(defaultBackend.displayName), this engine's usual graphics. G-Player never switches it.")
    }
}
