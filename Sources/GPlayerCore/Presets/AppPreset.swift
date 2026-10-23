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
    /// Chromium helpers to wrap (see `ChromiumHelperWrapper`).
    public let chromiumHelpers: [String]
    public let launchArguments: [String]
    public let dllOverrides: [String]
    public let environment: [String: String]
    public let discovery: Discovery

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
        summary: "Epic's own launcher. Installs and starts, but under Wine it currently stops at its loading screen. The recommended Epic Games card installs your games without it.",
        symbol: "shippingbox", experimental: true,
        installerURL: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!,
        installerFileName: "EpicGamesLauncherInstaller.msi", installerArguments: ["/qn"],
        executables: ["Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
                      "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"],
        chromiumHelpers: ["Program Files/Epic Games/Launcher/Engine/Binaries/Win64/EpicWebHelper.exe",
                          "Program Files (x86)/Epic Games/Launcher/Engine/Binaries/Win64/EpicWebHelper.exe"],
        launchArguments: ["-SkipBuildPatchPrereq"],
        dllOverrides: [], environment: qtWebEngine, discovery: .epic)

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
