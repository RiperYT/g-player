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
    /// What the build is made from, when its own number says too little: G-Player Wine's "11.0" next to Wine
    /// Staging's "11.18" would look older than it is.
    public var basedOn: String? = nil

    /// The name with its version, for rows and pickers: "Wine Staging 11.18", "G-Player Wine (Wine 11 from CrossOver 26.3)".
    public var displayName: String { basedOn.map { "\(name) (\($0))" } ?? "\(name) \(version)" }
    public var defaultBackend: GraphicsBackend { backends.first ?? .wined3d }
    /// What installing needs to download, leaving out the runtime libraries when an installed Wine Staging has them.
    public func downloadBytes(wineStagingInstalled: Bool) -> Int64 {
        downloads.filter { !(wineStagingInstalled && $0.role == .runtimeLibraries) }.reduce(0) { $0 + $1.approximateBytes }
    }
    /// This engine with only the backends in `ready` (`Engine.readyBackends`), for decisions about what can run now.
    public func limited(to ready: [GraphicsBackend]) -> EngineInfo {
        EngineInfo(id: id, name: name, version: version, kind: kind, summary: summary,
                   backends: backends.filter(ready.contains), downloads: downloads, basedOn: basedOn)
    }
    public func resolve(_ backend: GraphicsBackend) -> GraphicsBackend {
        backend == .auto || !backends.contains(backend) ? defaultBackend : backend
    }
    /// The engine G-Player recommends for new spaces (`EngineCatalog.defaultForNewSpaces`), which Settings and the pickers mark.
    public var isRecommended: Bool { id == EngineCatalog.defaultForNewSpaces.id }
    /// The name for a picker or a line with little room: "G-Player Wine", "Wine Staging 11.18", "Game Porting Toolkit (D3DMetal)".
    public var shortName: String {
        switch kind {
        case .crossover: name
        case .wineStaging: "\(name) \(version)"
        case .gptk: "\(name) (D3DMetal)"
        }
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
        summary: "Wine 11 built from CodeWeavers' CrossOver source. Runs Steam and DirectX 9–11 games like Wine Staging, with DXVK or DXMT, and DirectX 12 through Apple's D3DMetal when you add it from your own toolkit.",
        // DXVK is what Steam and games without a better choice run with; 64-bit DirectX 10–12 games take D3DMetal once
        // it is copied in (`CompatResolver`).
        backends: [.dxvk, .d3dmetal, .dxmt, .wined3d],
        downloads: [
            PinnedDownload(
                url: URL(string: "https://github.com/RiperYT/g-player/releases/download/engine-cx26.3.0-1/g-player-engine-cx26.3.0-1.tar.xz")!,
                fileName: "g-player-engine-cx26.3.0-1.tar.xz",
                sha256: CrossOverEnginePin.sha256,
                approximateBytes: CrossOverEnginePin.bytes),
            PinnedDownload(
                url: wineStaging.downloads[0].url, fileName: wineStaging.downloads[0].fileName,
                sha256: wineStaging.downloads[0].sha256, approximateBytes: wineStaging.downloads[0].approximateBytes,
                role: .runtimeLibraries),
            PinnedDownload(
                url: URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz")!,
                fileName: "dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz",
                sha256: "acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477",
                approximateBytes: 3_900_000,
                role: .dxvk),
        ],
        basedOn: "Wine 11 from CrossOver 26.3")

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

    /// Recommended first: pickers and Settings list engines in this order.
    public static let all = [crossover, wineStaging, gptk]
    /// Callers read a space whose engine id isn't here as `wineStaging` (`info(id) ?? .wineStaging`).
    public static func info(_ id: String) -> EngineInfo? { all.first { $0.id == id } }

    /// The engine G-Player recommends for new spaces, and what a bottle found on the Mac gets. G-Player Wine runs
    /// Steam too, has the fixes for 32-bit games and audio, and takes D3DMetal when the user adds it. Spaces made
    /// earlier keep the engine they have. What a new space gets right now is `engineForNewSpace`.
    public static let defaultForNewSpaces = crossover

    /// The engine for a new space made without a choice (Main, store presets, Add Game, the New Space sheet's first
    /// pick): G-Player Wine when it is installed, else Wine Staging when that is, so the space needs no download
    /// (offline, say). Only with neither installed is it G-Player Wine, which then downloads.
    public static func engineForNewSpace(installed: [EngineInfo]) -> EngineInfo {
        let has = { (info: EngineInfo) in installed.contains { $0.id == info.id } }
        return has(defaultForNewSpaces) || !has(wineStaging) ? defaultForNewSpaces : wineStaging
    }

    /// What the first run installs, in order. Wine Staging goes first so G-Player Wine copies its runtime libraries
    /// instead of downloading the same archive again; Staging stays as the alternative engine.
    public static let firstRunInstalls = [wineStaging, crossover]

    /// The engine for the spaces the first run creates: G-Player Wine, or Wine Staging when G-Player Wine couldn't
    /// be installed, so there is always an engine. Nil with neither installed: those spaces wait for an engine.
    public static func firstRunEngine(installed: [EngineInfo]) -> EngineInfo? {
        installed.contains { $0.id == crossover.id || $0.id == wineStaging.id } ? engineForNewSpace(installed: installed) : nil
    }

    /// What the first run still has to download, in bytes: the engines of `firstRunInstalls` that aren't installed,
    /// leaving out G-Player Wine's runtime libraries once Wine Staging is (or by then will be) there.
    public static func firstRunBytes(installed: [EngineInfo]) -> Int64 {
        var have = Set(installed.map(\.id))
        var total: Int64 = 0
        for info in firstRunInstalls where !have.contains(info.id) {
            total += info.downloadBytes(wineStagingInstalled: have.contains(wineStaging.id))
            have.insert(info.id)
        }
        return total
    }

    /// A download size in whole megabytes, rounded: both first-run engines are 484,886,864 bytes, which is "485". Cutting
    /// the fraction off said 484 for both, and 287 for G-Player Wine alone.
    public static func megabytes(_ bytes: Int64) -> Int { Int((Double(bytes) / 1_000_000).rounded()) }

    /// Apple's page about the toolkit and its license.
    public static let gptkInfoURL = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
}

/// The CrossOver engine archive G-Player publishes (scripts/build-engine-cx.sh, attached to the release
/// engine-cx26.3.0-1 together with CodeWeavers' source tarball it was built from).
enum CrossOverEnginePin {
    static let sha256 = "c10b3dff14429944f99ce660ff294c11d58dff3c39df9a0b91bdfd114e223686"
    static let bytes: Int64 = 283981528
}

