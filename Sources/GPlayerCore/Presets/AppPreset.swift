import Foundation

/// A Windows app G-Player can set up in one click: a store launcher with its own space.
public struct AppPreset: Identifiable, Sendable, Hashable {
    public enum Discovery: String, Sendable { case steam, epic, none }

    public let id: String
    public let name: String
    public let summary: String
    /// SF Symbol shown on its card.
    public let symbol: String
    /// Not yet verified end to end on Apple Silicon.
    public let experimental: Bool
    public let installerURL: URL
    public let installerFileName: String
    public let installerArguments: [String]
    /// Where the launcher may end up, relative to drive_c, most likely first. Installers move between
    /// Program Files and Program Files (x86) across versions.
    public let executables: [String]
    /// The launcher's Chromium helpers, which get wrapped (see `ChromiumHelperWrapper`) unless the engine's recipe says not to.
    public let chromiumHelpers: [String]
    public let launchArguments: [String]
    public let dllOverrides: [String]
    public let environment: [String: String]
    public let discovery: Discovery
    /// Where the launcher's setup differs from the usual one, by engine kind (`helpersToWrap(on:)`, `launcherBackend(on:)`).
    public var engineRecipes: [EngineInfo.Kind: EngineRecipe] = [:]
    /// The launcher doesn't open on Wine Staging: its space is made on G-Player Wine, and one on another engine is offered the move.
    public var needsGPlayerWine = false

    /// What a launcher does differently on one engine kind. The defaults are the usual setup.
    public struct EngineRecipe: Sendable, Hashable {
        /// Its Chromium helpers are wrapped. Off, they stay as the vendor made them.
        public var wrapsHelpers = true
        /// The graphics the launcher itself starts with, whatever its library entry says. Programs it starts inherit them.
        public var backend: GraphicsBackend? = nil
    }

    /// The helpers to wrap before a start on this engine kind.
    public func helpersToWrap(on engine: EngineInfo.Kind) -> [String] {
        engineRecipes[engine]?.wrapsHelpers == false ? [] : chromiumHelpers
    }

    /// The helpers whose wrapper is taken out before a start on this engine kind: those the launcher runs without there.
    public func helpersToUnwrap(on engine: EngineInfo.Kind) -> [String] {
        engineRecipes[engine]?.wrapsHelpers == false ? chromiumHelpers : []
    }

    /// The graphics the launcher is pinned to on this engine kind, or nil when its library entry and the engine decide.
    public func launcherBackend(on engine: EngineInfo.Kind) -> GraphicsBackend? { engineRecipes[engine]?.backend }

    /// The engine for the preset's new space: what any new space gets (`EngineCatalog.engineForNewSpace`), except that a launcher
    /// that needs G-Player Wine gets it also when only Wine Staging is installed (it downloads then).
    public func engineForNewSpace(installed: [EngineInfo]) -> EngineInfo {
        needsGPlayerWine ? EngineCatalog.installedGPlayerWine(in: installed) ?? EngineCatalog.defaultForNewSpaces
                         : EngineCatalog.engineForNewSpace(installed: installed)
    }

    /// The installed launcher, or the most likely place for it.
    public func executableURL(in space: Space) -> URL {
        let urls = executables.map { space.driveC.appendingPathComponent($0) }
        return urls.first { FileManager.default.fileExists(atPath: $0.path) } ?? urls[0]
    }
    public func isInstalled(in space: Space) -> Bool { FileManager.default.fileExists(atPath: executableURL(in: space).path) }
}

public enum AppPresets {
    /// Qt WebEngine launchers that games start from Steam need the same software rendering.
    static let qtWebEngine = [
        "QTWEBENGINE_CHROMIUM_FLAGS": "--disable-gpu --disable-gpu-compositing --in-process-gpu --no-sandbox",
        "QTWEBENGINE_DISABLE_SANDBOX": "1",
    ]

    public static let steam = AppPreset(
        id: "steam", name: "Steam",
        summary: "Valve's store and launcher. Your Steam games show up in the library on their own.",
        symbol: "cloud", experimental: false,
        installerURL: URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!,
        installerFileName: "SteamSetup.exe", installerArguments: ["/S"],
        executables: ["Program Files (x86)/Steam/steam.exe"],
        chromiumHelpers: ["Program Files (x86)/Steam/bin/cef/cef.*/steamwebhelper.exe"],
        launchArguments: ["-no-cef-sandbox"],
        dllOverrides: ["bcrypt=b;ncrypt=b", "gameoverlayrenderer,gameoverlayrenderer64=d"],
        environment: qtWebEngine, discovery: .steam)

    public static let epic = AppPreset(
        id: "epic", name: "Epic Games Launcher",
        summary: "Epic's own launcher. Runs on G-Player Wine; sign in with your Epic account.",
        symbol: "shippingbox", experimental: true,
        installerURL: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!,
        installerFileName: "EpicGamesLauncherInstaller.msi", installerArguments: ["/qn"],
        executables: ["Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
                      "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"],
        chromiumHelpers: ["Program Files/Epic Games/Launcher/Engine/Binaries/Win64/EpicWebHelper.exe",
                          "Program Files (x86)/Epic Games/Launcher/Engine/Binaries/Win64/EpicWebHelper.exe"],
        launchArguments: ["-SkipBuildPatchPrereq"],
        dllOverrides: [], environment: qtWebEngine, discovery: .epic,
        // On G-Player Wine its web helper runs as Epic made it (wrapped, its network service crashes again and again), and
        // its renderer takes the engine's own Direct3D (with DXVK it can't make its swap chain and restarts itself). On Wine
        // Staging nothing changes: it doesn't open there.
        engineRecipes: [.crossover: .init(wrapsHelpers: false, backend: .wined3d)], needsGPlayerWine: true)

    public static let gog = AppPreset(
        id: "gog", name: "GOG Galaxy",
        summary: "GOG's launcher. Games it installs appear under Found programs in its space.",
        symbol: "circle.hexagongrid", experimental: true,
        installerURL: URL(string: "https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe")!,
        installerFileName: "GOG_Galaxy_2.0.exe", installerArguments: [],
        executables: ["Program Files (x86)/GOG Galaxy/GalaxyClient.exe", "Program Files/GOG Galaxy/GalaxyClient.exe"],
        chromiumHelpers: ["Program Files (x86)/GOG Galaxy/GalaxyClient Helper.exe"],
        launchArguments: [], dllOverrides: [], environment: qtWebEngine, discovery: .none)

    public static let ubisoft = AppPreset(
        id: "ubisoft", name: "Ubisoft Connect",
        summary: "Ubisoft's launcher for its own games.",
        symbol: "hurricane", experimental: true,
        installerURL: URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!,
        installerFileName: "UbisoftConnectInstaller.exe", installerArguments: ["/S"],
        executables: ["Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe",
                      "Program Files/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe"],
        chromiumHelpers: [], launchArguments: [], dllOverrides: [], environment: qtWebEngine, discovery: .none)

    public static let all = [steam, epic, gog, ubisoft]
    public static func preset(_ id: String?) -> AppPreset? { all.first { $0.id == id } }
}
