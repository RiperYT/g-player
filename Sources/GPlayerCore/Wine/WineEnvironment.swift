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

/// Builds the exact environment Wine gets. Decided without running Wine, so it can be tested; it only looks at which
/// of the engine's backends are there.
public enum WineEnvironment {
    /// The Visual C++ 2015–2022 runtime's DLLs (`vcrun2022`).
    static let visualCppRuntime = ["msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait", "msvcp140_codecvt_ids",
                                   "vcruntime140", "vcruntime140_1", "vcruntime140_threads", "concrt140", "vcomp140"]
        .joined(separator: ",")

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
        let backend = engine.resolve(requested)
        switch backend {
        case .dxvk where engine.info.kind == .crossover && D3DMetalStore.linkedVersion(in: engine) != nil:
            // Wine's builtin dxgi is Apple's there, and DXVK can't make a swap chain with it; Wine's own copy goes into
            // the space (`SpaceManager.prepareGraphics`).
            overrides.append("d3d11,d3d10core,dxgi=n,b")
            env["DXVK_ASYNC"] = "1"
            env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        case .dxvk:
            overrides.append("d3d11,d3d10core=n,b")
            env["DXVK_ASYNC"] = "1"
            env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        case .d3dmetal where engine.info.kind == .crossover:
            // CrossOver's Wine loads Apple's bridge from this path; D3DMetal's DLLs are the engine's builtins.
            if let d3dshared = engine.d3dMetalLibrary { env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = d3dshared.path }
            env["CX_ACTIVE_GRAPHICS_BACKEND"] = "d3dmetal"   // DirectX 12 games then hear about GPU scheduling
            env["D3DM_SUPPORT_DXR"] = "1"
        case .d3dmetal:
            overrides.append("d3d9,d3d10core,d3d11,d3d12,d3d12core,dxgi=b")
            env["DYLD_FALLBACK_LIBRARY_PATH"] = engine.externalLibraries.path + ":/usr/lib"
            env["D3DM_SUPPORT_DXR"] = "1"
        case .dxmt:
            overrides.append("dxgi,d3d11,d3d10core=n,b")
        case .wined3d, .auto:
            break
        }
        if engine.info.kind == .crossover {
            // CrossOver's Wine 11.0 takes its builtin over Microsoft's runtime in system32, where Wine Staging 11.18
            // loads Microsoft's copy (its load order looks at the DLL's version resource). A game's prerequisite check
            // then sees Wine's older version and asks for Visual C++ again (Unreal Engine 5.7's bootstrapper does).
            // Microsoft's own copies win when the space has them; otherwise Wine's builtins load as before.
            overrides.append(Self.visualCppRuntime + "=n,b")
        }
        if let plugins = engine.gstreamerPlugins {
            // G-Player Wine's own GStreamer, for game videos, and never one the user installed: its universal scanner would
            // run arm64 against these x86_64 plugins, and the scanner isn't shipped, so plugins are read in this process.
            env["GST_PLUGIN_SYSTEM_PATH_1_0"] = plugins.path
            env["GST_REGISTRY_1_0"] = engine.gstreamerRegistry.path
            env["GST_REGISTRY_FORK"] = "no"
        }
        overrides += tweaks.dllOverrides
        env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")
        for (k, v) in tweaks.environment { env[k] = v }
        return env
    }
}
