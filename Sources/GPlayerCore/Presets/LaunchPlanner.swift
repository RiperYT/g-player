import Foundation

/// Everything one launch needs, decided without touching Wine (so it can be tested).
public struct LaunchPlan: Sendable, Equatable {
    public var arguments: [String]
    public var workingDirectory: URL?
    public var backend: GraphicsBackend
    public var tweaks: LaunchTweaks
    /// Helpers to wrap right before starting.
    public var chromiumHelpers: [String]
}

public enum LaunchPlanner {
    public enum PlanError: LocalizedError {
        case missingExecutable(String), launcherMissing(String)
        public var errorDescription: String? {
            switch self {
            case .missingExecutable(let t): "\(t) has no program to start. Choose one in its settings."
            case .launcherMissing(let n): "\(n) isn't installed in this space yet."
            }
        }
    }

    public static func plan(for game: Game, in space: Space, verboseLogs: Bool = false) throws -> LaunchPlan {
        let preset = AppPresets.preset(space.presetID)
        var tweaks = LaunchTweaks(dllOverrides: preset?.dllOverrides ?? [],
                                  environment: (preset?.environment ?? [:]).merging(game.environment) { _, user in user },
                                  verboseLogs: verboseLogs)
        let helpers = preset?.chromiumHelpers ?? []

        switch game.source {
        case .executable:
            guard let exe = game.executableURL(in: space), FileManager.default.fileExists(atPath: exe.path) else {
                throw PlanError.missingExecutable(game.title)
            }
            var args = WineLauncher.arguments(toOpen: exe, extra: game.arguments)
            // The launcher of a preset space: Steam needs its own flags (and -noverifyfiles once it is ready).
            if let preset, exe.standardizedFileURL.path == preset.executableURL(in: space).standardizedFileURL.path {
                args += steamReadyFlags(preset, space) + preset.launchArguments
            }
            return LaunchPlan(arguments: args, workingDirectory: exe.deletingLastPathComponent(),
                              backend: game.graphics, tweaks: tweaks, chromiumHelpers: helpers)

        case .steam(let appID):
            let steam = AppPresets.steam
            guard steam.isInstalled(in: space) else { throw PlanError.launcherMissing("Steam") }
            tweaks.dllOverrides = steam.dllOverrides
            let exe = steam.executableURL(in: space)
            return LaunchPlan(arguments: [exe.path, "-silent"] + steamReadyFlags(steam, space) + steam.launchArguments
                                + ["-applaunch", appID] + game.arguments,
                              workingDirectory: exe.deletingLastPathComponent(), backend: game.graphics,
                              tweaks: tweaks, chromiumHelpers: steam.chromiumHelpers)

        case .epic(_, let uri):
            let epic = AppPresets.epic
            guard epic.isInstalled(in: space) else { throw PlanError.launcherMissing("Epic Games Launcher") }
            let exe = epic.executableURL(in: space)
            return LaunchPlan(arguments: [exe.path] + epic.launchArguments + [uri],
                              workingDirectory: exe.deletingLastPathComponent(), backend: game.graphics,
                              tweaks: tweaks, chromiumHelpers: epic.chromiumHelpers)
        }
    }

    /// `-noverifyfiles` keeps Steam from restoring its helper; only safe once the client is fully downloaded.
    static func steamReadyFlags(_ preset: AppPreset, _ space: Space) -> [String] {
        preset.id == "steam" && SteamLibrary.isClientReady(in: space) ? ["-noverifyfiles"] : []
    }
}
