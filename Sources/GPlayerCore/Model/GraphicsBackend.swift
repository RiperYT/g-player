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
        case .auto: "Automatic"
        case .dxvk: "DXVK"
        case .wined3d: "WineD3D"
        case .d3dmetal: "D3DMetal"
        case .dxmt: "DXMT"
        }
    }

    public var summary: String {
        switch self {
        case .auto: "Picks the best option for this engine."
        case .dxvk: "DirectX 10 and 11 through Vulkan and MoltenVK."
        case .wined3d: "Wine's OpenGL renderer. Good for older DirectX 9 games."
        case .d3dmetal: "Apple's translator for DirectX 11 and 12, from your own Game Porting Toolkit."
        case .dxmt: "DirectX 10 and 11 straight to Metal. Needs the G-Player Wine engine."
        }
    }
}
