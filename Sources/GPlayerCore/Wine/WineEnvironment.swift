import Foundation

/// Extra settings one launch needs beyond the engine and backend (Steam, launchers, user tweaks).
public struct LaunchTweaks: Sendable, Hashable {
    public var dllOverrides: [String] = []
    public var environment: [String: String] = [:]
    public var verboseLogs = false
    /// The space has .NET (Wine Mono or Microsoft's), so Wine may load it. Off keeps Wine from offering to download Mono.
    public var dotNetAvailable: Bool = false
    public init(dllOverrides: [String] = [], environment: [String: String] = [:], verboseLogs: Bool = false,
                dotNetAvailable: Bool = false) {
        self.dllOverrides = dllOverrides; self.environment = environment; self.verboseLogs = verboseLogs
        self.dotNetAvailable = dotNetAvailable
    }
}

/// Builds the exact environment Wine gets. Kept pure so it can be tested without Wine.
public enum WineEnvironment {
    /// Variables passed through from the app's own environment.
    static let inherited = ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "LC_ALL"]

    public static func make(engine: Engine, space: Space, backend requested: GraphicsBackend,
                            tweaks: LaunchTweaks = LaunchTweaks(),
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [:]
        for key in inherited { if let v = base[key] { env[key] = v } }
        env["PATH"] = engine.wineRoot.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        env["WINEPREFIX"] = space.path
        // Missing-DLL errors stay on so a failed launch can say what's missing (LogDiagnosis); the rest is quiet.
        env["WINEDEBUG"] = tweaks.verboseLogs ? "err+all,warn+module" : "-all,err+module"
        env["WINEESYNC"] = "1"
        env["WINEMSYNC"] = "1"
        env["ROSETTA_ADVERTISE_AVX"] = "1"

        // No Wine Mono or Gecko downloads popping up; programs that need .NET get it from their installer. Once the space
        // has .NET, `mscoree` must stay loadable, or .NET programs would never find it.
        var overrides = [tweaks.dotNetAvailable ? "mshtml=" : "mscoree,mshtml=", "winemenubuilder.exe=d"]
        let backend = engine.info.resolve(requested)
        switch backend {
        case .dxvk:
            overrides.append("d3d11,d3d10core=n,b")
            env["DXVK_ASYNC"] = "1"
            env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        case .d3dmetal:
            overrides.append("d3d9,d3d10core,d3d11,d3d12,d3d12core,dxgi=b")
            env["DYLD_FALLBACK_LIBRARY_PATH"] = engine.externalLibraries.path + ":/usr/lib"
            env["D3DM_SUPPORT_DXR"] = "1"
        case .wined3d, .auto:
            break
        }
        overrides += tweaks.dllOverrides
        env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")
        for (k, v) in tweaks.environment { env[k] = v }
        return env
    }
}
