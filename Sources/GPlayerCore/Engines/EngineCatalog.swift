import Foundation

/// A downloadable file, pinned by SHA-256.
public struct PinnedDownload: Sendable, Hashable {
    /// What the archive is for: the engine itself, DXVK, or (G-Player Wine) the runtime libraries from Gcenx's
    /// build that Wine loads, which G-Player's own archive leaves out.
    public enum Role: Sendable, Hashable { case engine, dxvk, runtimeLibraries }

    public let url: URL
    public let fileName: String
    public let sha256: String
    public let approximateBytes: Int64
    public var role: Role = .engine
}

/// A Wine build G-Player knows how to use.
public struct EngineInfo: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable { case wineStaging, crossover, gptk }

    public let id: String
    public let name: String
    public let version: String
    public let kind: Kind
    public let summary: String
    /// Graphics backends this engine can run. The first one is what `.auto` means.
    public let backends: [GraphicsBackend]
    /// Files to download. Empty when G-Player never downloads the engine (Apple's toolkit).
    public let downloads: [PinnedDownload]

    public var defaultBackend: GraphicsBackend { backends.first ?? .wined3d }
    /// What installing needs to download, leaving out the runtime libraries when an installed Wine Staging has them.
    public func downloadBytes(wineStagingInstalled: Bool) -> Int64 {
        downloads.filter { !(wineStagingInstalled && $0.role == .runtimeLibraries) }.reduce(0) { $0 + $1.approximateBytes }
    }
    /// This engine with only the backends in `ready` (`Engine.readyBackends`), for decisions about what can run now.
    public func limited(to ready: [GraphicsBackend]) -> EngineInfo {
        EngineInfo(id: id, name: name, version: version, kind: kind, summary: summary,
                   backends: backends.filter(ready.contains), downloads: downloads)
    }
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
                approximateBytes: 3_900_000,
                role: .dxvk),
        ])

    /// G-Player Wine: Wine 11 built by G-Player from CodeWeavers' CrossOver 26.3 source (scripts/build-engine-cx.sh,
    /// tools/wine-patches/cx-*.patch), with DXMT and MoltenVK 1.4.2, plus Gcenx's runtime libraries and DXVK.
    /// CrossOver's tree has the hooks Apple's D3DMetal needs, so with D3DMetal copied from the user's own Game Porting
    /// Toolkit (`D3DMetalStore`) DirectX 12 games run in the same space as Steam. Without D3DMetal it still runs
    /// DXVK, DXMT and WineD3D. "CrossOver" is CodeWeavers' trademark; it only says where the source comes from.
    public static let crossover = EngineInfo(
        id: "wine-cx-26.3.0-1",
        name: "G-Player Wine",
        version: "11.0",
        kind: .crossover,
        summary: "Wine 11 built from CodeWeavers' CrossOver source. Runs Steam, DirectX 10/11 through DXVK or DXMT, and DirectX 11/12 through Apple's D3DMetal when you add it from your own toolkit.",
        // DXVK is what Steam and games without a better choice run with; 64-bit DirectX 10–12 games take D3DMetal once
        // it is copied in (`CompatResolver`).
        backends: [.dxvk, .d3dmetal, .dxmt, .wined3d],
        downloads: [
            PinnedDownload(
                url: URL(string: "https://github.com/RiperYT/g-player/releases/download/engine-cx26.3.0-1/g-player-engine-cx26.3.0-1.tar.xz")!,
                fileName: "g-player-engine-cx26.3.0-1.tar.xz",
                sha256: CrossOverEnginePin.sha256,
                approximateBytes: CrossOverEnginePin.bytes),
            // Its own file name: Wine Staging may be downloading the same archive at the same time.
            PinnedDownload(
                url: wineStaging.downloads[0].url, fileName: "runtime-" + wineStaging.downloads[0].fileName,
                sha256: wineStaging.downloads[0].sha256, approximateBytes: wineStaging.downloads[0].approximateBytes,
                role: .runtimeLibraries),
            PinnedDownload(
                url: URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz")!,
                fileName: "dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz",
                sha256: "acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477",
                approximateBytes: 3_900_000,
                role: .dxvk),
        ])

    /// Apple's Game Porting Toolkit (wine 7.7 + D3DMetal), only when the user installed it themselves.
    /// G-Player never ships, downloads or installs Apple's files: Apple's license allows the toolkit for
    /// developing, testing and evaluating games, and distribution only for non-commercial purposes.
    /// Off by default; turned on in Settings › Engines. The 2026 Steam client doesn't start on wine 7.7.
    public static let gptk = EngineInfo(
        id: "gptk",
        name: "Game Porting Toolkit",
        version: "installed by you",
        kind: .gptk,
        summary: "Apple's D3DMetal for DirectX 11 and 12 games, from a toolkit you installed yourself.",
        backends: [.d3dmetal, .wined3d],
        downloads: [])

    public static let all = [wineStaging, crossover, gptk]
    public static func info(_ id: String) -> EngineInfo? { all.first { $0.id == id } }

    /// Apple's page about the toolkit and its license.
    public static let gptkInfoURL = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
}

/// The CrossOver engine archive G-Player publishes (scripts/build-engine-cx.sh, attached to the release
/// engine-cx26.3.0-1 together with CodeWeavers' source tarball it was built from).
enum CrossOverEnginePin {
    static let sha256 = "c10b3dff14429944f99ce660ff294c11d58dff3c39df9a0b91bdfd114e223686"
    static let bytes: Int64 = 283981528
}

