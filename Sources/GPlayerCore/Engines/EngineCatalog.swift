import Foundation

/// A downloadable file, pinned by SHA-256.
public struct PinnedDownload: Sendable, Hashable {
    public let url: URL
    public let fileName: String
    public let sha256: String
    public let approximateBytes: Int64
}

/// A Wine build G-Player knows how to use.
public struct EngineInfo: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable { case wineStaging, gptk }

    public let id: String
    public let name: String
    public let version: String
    public let kind: Kind
    public let summary: String
    /// Graphics backends this engine can run. The first one is what `.auto` means.
    public let backends: [GraphicsBackend]
    /// Files to download. Empty when the engine is installed some other way (Homebrew).
    public let downloads: [PinnedDownload]

    public var defaultBackend: GraphicsBackend { backends.first ?? .wined3d }
    public func resolve(_ backend: GraphicsBackend) -> GraphicsBackend {
        backend == .auto || !backends.contains(backend) ? defaultBackend : backend
    }
}

public enum EngineCatalog {
    /// WineHQ Wine Staging built for macOS by Gcenx, plus Gcenx's DXVK for macOS.
    /// Same pins as MaPC's open-source engine (github.com/abduzeedo/mapc-engine, Apache-2.0).
    public static let wineStaging = EngineInfo(
        id: "wine-staging-11.18",
        name: "Wine Staging",
        version: "11.18",
        kind: .wineStaging,
        summary: "Open-source Wine with DXVK. Runs Steam and most DirectX 9–11 games.",
        backends: [.dxvk, .wined3d],
        downloads: [
            PinnedDownload(
                url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-staging-11.18-osx64.tar.xz")!,
                fileName: "wine-staging-11.18-osx64.tar.xz",
                sha256: "b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127",
                approximateBytes: 193_105_336),
            PinnedDownload(
                url: URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz")!,
                fileName: "dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz",
                sha256: "acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477",
                approximateBytes: 3_900_000),
        ])

    /// Apple's Game Porting Toolkit as packaged by Gcenx's Homebrew cask (wine 7.7 + D3DMetal).
    /// Best DirectX 11/12 speed, but the 2026 Steam client no longer starts on wine 7.7.
    public static let gptk = EngineInfo(
        id: "gptk",
        name: "Game Porting Toolkit",
        version: "Homebrew cask",
        kind: .gptk,
        summary: "Apple's D3DMetal for DirectX 11 and 12 games. Install with Homebrew.",
        backends: [.d3dmetal, .wined3d],
        downloads: [])

    public static let all = [wineStaging, gptk]
    public static func info(_ id: String) -> EngineInfo? { all.first { $0.id == id } }

    public static let gptkHomebrewCommand =
        #"brew install --cask --no-quarantine gcenx/wine/game-porting-toolkit"#
}
