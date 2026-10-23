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
    /// What the launcher needs .NET for, when it runs managed code: Epic's launcher installs Epic Online Services with an installer
    /// whose custom actions are .NET, and without Wine Mono that fails with "Epic Online Services is not installed" (error
    /// II-E1007). Its programs run with Wine Mono in place (`WineMono`), on an engine that has one to go with it. Nil: it needs none.
    public var dotNetReason: String? = nil
    public var needsDotNet: Bool { dotNetReason != nil }

    /// What a launcher does differently on one engine kind. The defaults are the usual setup.
    public struct EngineRecipe: Sendable, Hashable {
        /// Its Chromium helpers are wrapped. Off, they stay as the vendor made them.
        public var wrapsHelpers = true
        /// The graphics the launcher itself starts with, whatever its library entry says, best first: the first one the engine has
        /// ready (`AppPreset.launcherBackend(on:ready:)`). Programs it starts inherit them. Empty: the entry and the engine decide.
        public var backends: [GraphicsBackend] = []
    }

    /// A start of the launcher on this engine kind is replaced by the offer to move its space to G-Player Wine: elsewhere it
    /// never gets past its loading screen.
    public func offersMoveBeforeStart(on engine: EngineInfo.Kind) -> Bool { needsGPlayerWine && engine != .crossover }

    /// The Wine Mono this launcher's programs need on `engine`, or nil when it doesn't need .NET or the engine has no Mono of its own.
    public func wineMono(on engine: EngineInfo) -> WineMonoPackage? { needsDotNet ? engine.mono : nil }

    /// The helpers to wrap before a start on this engine kind.
    public func helpersToWrap(on engine: EngineInfo.Kind) -> [String] {
        engineRecipes[engine]?.wrapsHelpers == false ? [] : chromiumHelpers
    }

    /// The helpers whose wrapper is taken out before a start on this engine kind: those the launcher runs without there.
    public func helpersToUnwrap(on engine: EngineInfo.Kind) -> [String] {
        engineRecipes[engine]?.wrapsHelpers == false ? chromiumHelpers : []
    }

    /// The graphics the launcher is pinned to on this engine kind, or nil when its library entry and the engine decide. `ready` is
    /// what the engine can run now (`Engine.readyBackends`, with D3DMetal only while Apple's toolkit is on): the best of the
    /// recipe's backends that is in it, else its last one (the engine then runs what it has instead).
    public func launcherBackend(on engine: EngineInfo.Kind, ready: [GraphicsBackend]) -> GraphicsBackend? {
        guard let wanted = engineRecipes[engine]?.backends, let last = wanted.last else { return nil }
        return wanted.first { ready.contains($0) } ?? last
    }

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
        summary: "Epic's own launcher. Runs on G-Player Wine; sign in with your Epic account. Its first start adds Wine Mono (.NET) for "
            + "Epic Online Services: a \(WineMono.sizeLabel(EngineCatalog.wineMono10_4_1)) download, about \(WineMono.installedSizeLabel(EngineCatalog.wineMono10_4_1)) on disk.",
        symbol: "shippingbox", experimental: false,
        installerURL: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!,
        installerFileName: "EpicGamesLauncherInstaller.msi", installerArguments: ["/qn"],
        executables: ["Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
                      "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"],
        chromiumHelpers: ["Program Files/Epic Games/Launcher/Engine/Binaries/Win64/EpicWebHelper.exe",
                          "Program Files (x86)/Epic Games/Launcher/Engine/Binaries/Win64/EpicWebHelper.exe"],
        launchArguments: ["-SkipBuildPatchPrereq"],
        dllOverrides: [], environment: qtWebEngine, discovery: .epic,
        // On G-Player Wine its web helper runs as Epic made it (wrapped, its network service crashes again and again), and its
        // renderer runs on DXMT, also when D3DMetal is added: on DXVK it can't make its swap chain and restarts itself, on WineD3D
        // (OpenGL 4.1) it falls back to software rendering and crashes, and on D3DMetal its web view's GPU process can't start
        // (ANGLE's Direct3D 11 path fails: "Passthrough is not supported, GL is disabled"), so it renders in software and idles
        // at about 34% CPU where DXMT idles at about 11%. On Wine Staging nothing changes: it doesn't open there.
        engineRecipes: [.crossover: .init(wrapsHelpers: false, backends: [.dxmt])], needsGPlayerWine: true,
        // Its Epic Online Services installer has .NET custom actions, which need Wine Mono.
        dotNetReason: "Epic Online Services")

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
