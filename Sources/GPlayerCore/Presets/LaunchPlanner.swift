import Foundation

/// What a running Steam passes on to the games it starts: the backend's DLL settings and the environment. Everything
/// else a game needs reaches it per launch (arguments through `-applaunch`, DLL overrides also through the registry).
public struct LauncherSettings: Sendable, Hashable {
    /// What the engine runs (never `.auto`), so a default and the same backend chosen by hand are equal.
    public var backend: GraphicsBackend
    /// The profile's, a fix's and the game's own variables; not the preset's, which every Steam start has.
    public var environment: [String: String]

    public init(backend: GraphicsBackend, environment: [String: String] = [:]) {
        self.backend = backend
        self.environment = environment
    }
}

/// What G-Player knows about the settings of a Steam it started, and how long to believe it. A look at the process table
/// may be older than the record, or miss Steam for a moment while it starts, so one look never erases a fresh record.
public struct KnownLauncher: Sendable, Equatable {
    public var settings: LauncherSettings
    public var startedAt: Date
    /// Looks in a row that found no Steam.
    public private(set) var goneLooks = 0

    public init(settings: LauncherSettings, startedAt: Date = Date()) {
        self.settings = settings; self.startedAt = startedAt
    }

    /// Takes in a look at the process table made at `time`. False when the record should be dropped: Steam was gone on two
    /// looks in a row, or on one when the record is older than ten seconds. A look made before the record says nothing.
    public mutating func look(steamRunning: Bool, at time: Date) -> Bool {
        guard time >= startedAt else { return true }
        if steamRunning { goneLooks = 0; return true }
        goneLooks += 1
        return goneLooks < 2 && time.timeIntervalSince(startedAt) <= 10
    }
}

/// Everything one launch needs, decided without touching Wine (so it can be tested).
public struct LaunchPlan: Sendable, Equatable {
    public var arguments: [String]
    public var workingDirectory: URL?
    public var backend: GraphicsBackend
    public var tweaks: LaunchTweaks
    /// Helpers to wrap right before starting.
    public var chromiumHelpers: [String]
    /// Runtime components the space must have first.
    public var components: [String] = []
    /// Registry values to set first (one `regedit /S` call).
    public var registry: [RegistryValue] = []
    /// What the compatibility layers decided, for the UI.
    public var compat: CompatPlan? = nil
    /// Steam games only: the plan carries something that reaches the game only when Steam is started for this launch,
    /// because a Steam that is already running starts games with the settings it got when it started. That is a
    /// graphics backend or environment variables that differ from the running Steam's. If Steam is already running,
    /// it has to be restarted first.
    public var needsFreshLauncher: Bool = false
    /// What Steam runs with when this plan starts it: set for a Steam game and for Steam itself, nil for other programs.
    public var launcherSettings: LauncherSettings? = nil
}

extension LaunchPlan {
    /// True when carrying out the plan writes into the space: components, registry values, Steam's helper wrapper,
    /// or DXVK's or DXMT's DLLs (copied over Wine's own when the backend is one of them). An external space needs the
    /// user's consent for any of these.
    public func writesToSpace(engine: EngineInfo) -> Bool {
        let resolved = engine.resolve(backend)
        return !components.isEmpty || !registry.isEmpty || !chromiumHelpers.isEmpty || resolved == .dxvk || resolved == .dxmt
    }
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

    /// - Parameters:
    ///   - fixes: known fixes that match the game (from `GameFixDatabase`).
    ///   - programNames: the file names of the programs the game starts, when the caller has them (the app keeps them
    ///     for Steam games). Nil: a Steam game's are looked for in its folder, a program the user added is its own .exe.
    ///   - screen: the screen size for a Unity game that saved 0×0 (see `UnityScreen`); the main display's when nil.
    ///   - ready: the backends the installed engine can run now (`Engine.readyBackends`); all of them when nil.
    ///   - launcher: the settings the running Steam was started with, when G-Player knows; a plain start (the engine's
    ///     default backend, no variables) otherwise. A Steam game whose settings differ needs Steam restarted.
    public static func plan(for game: Game, in space: Space, fixes: [GameFix] = [], verboseLogs: Bool = false,
                            programNames: [String]? = nil, screen: CGSize? = nil,
                            ready: [GraphicsBackend]? = nil, launcher: LauncherSettings? = nil) throws -> LaunchPlan {
        let preset = AppPresets.preset(space.presetID)
        let catalogued = EngineCatalog.info(space.engineID) ?? EngineCatalog.wineStaging
        let engine = ready.map { catalogued.limited(to: $0) } ?? catalogued
        let isLauncher = game.kind == .app
        let names = isLauncher ? [] : self.programNames(of: game, in: space, fixes: fixes, given: programNames)
        // Launchers (Steam itself) run with their preset's recipe only; games get the compatibility layers.
        let compat: CompatPlan? = isLauncher ? nil : CompatResolver.resolve(.init(
            engine: engine, analysis: game.analysis, fixes: fixes, options: game.launchOptions,
            userBackend: game.graphics, isStoreGame: game.storeKey != nil, programNames: names,
            autoGraphics: game.autoGraphics))
        let dotNet = hasDotNet(space)

        var environment = preset?.environment ?? [:]
        for (k, v) in compat?.environment ?? [:] { environment[k] = v }
        for (k, v) in game.environment { environment[k] = v }                        // the user's own settings win
        var overrides = preset?.dllOverrides ?? []
        overrides += (compat?.dllOverrides ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" }
        let tweaks = LaunchTweaks(dllOverrides: overrides, environment: environment, verboseLogs: verboseLogs,
                                  dotNetAvailable: dotNet)
        let helpers = preset?.chromiumHelpers ?? []
        let backend = compat?.backend ?? (isLauncher ? Self.launcherBackend(on: engine, chosen: game.graphics) : game.graphics)
        var registry = compat?.registry ?? []

        /// Engine/fix arguments first, then the user's, without the options the user sets themselves.
        func gameArguments() -> [String] {
            let ours = (compat?.arguments ?? []) + unityScreenArguments()
            return Self.dropping(ours, setIn: game.arguments) + game.arguments
        }
        /// A screen size for a Unity game that saved 0×0.
        func unityScreenArguments() -> [String] {
            guard !isLauncher, game.analysis?.engine == .unity else { return [] }
            // A program the user added is found from the space (the library may have moved since the analysis).
            let program: URL? = switch game.source {
            case .executable: game.executableURL(in: space)
            case .steam, .epic: game.analysis?.programPath.map { URL(fileURLWithPath: $0) }
            }
            guard let program else { return [] }
            let all = (compat?.arguments ?? []) + game.arguments
            let fullscreen = all.lastIndex(of: "-screen-fullscreen").flatMap { all.indices.contains($0 + 1) ? all[$0 + 1] : nil }
            return UnityScreen.repairArguments(program: program, space: space, windowed: fullscreen.map { $0 == "0" },
                                               retina: game.launchOptions.retina, screen: screen)
        }

        switch game.source {
        case .executable:
            guard let exe = game.executableURL(in: space), FileManager.default.fileExists(atPath: exe.path) else {
                throw PlanError.missingExecutable(game.title)
            }
            var args: [String]
            var launcherSettings: LauncherSettings?
            if let preset, exe.standardizedFileURL.path == preset.executableURL(in: space).standardizedFileURL.path {
                // The launcher of a preset space: Steam needs its own flags (and -noverifyfiles once it is ready).
                args = WineLauncher.arguments(toOpen: exe, extra: game.arguments) + steamReadyFlags(preset, space) + preset.launchArguments
                if isLauncher && preset.id == AppPresets.steam.id {
                    launcherSettings = LauncherSettings(backend: engine.resolve(backend), environment: game.environment)
                }
            } else {
                args = WineLauncher.arguments(toOpen: exe, extra: gameArguments())
            }
            args = CompatResolver.apply(compat?.replacements ?? [], to: args)
            return LaunchPlan(arguments: args, workingDirectory: exe.deletingLastPathComponent(), backend: backend,
                              tweaks: tweaks, chromiumHelpers: helpers, components: compat?.components ?? [],
                              registry: registry, compat: compat, launcherSettings: launcherSettings)

        case .steam(let appID):
            let steam = AppPresets.steam
            guard steam.isInstalled(in: space) else { throw PlanError.launcherMissing("Steam") }
            let exe = steam.executableURL(in: space)
            // A running Steam starts the game with its own environment, so DLL settings also go into the
            // registry per program, which reaches the game however it starts.
            if let overrides = compat?.dllOverrides, !overrides.isEmpty {
                registry += RegistryFile.appDefaults(exeNames: names, overrides: overrides)
            }
            let args = [exe.path, "-silent"] + steamReadyFlags(steam, space) + steam.launchArguments
                + ["-applaunch", appID] + CompatResolver.apply(compat?.replacements ?? [], to: gameArguments())
            // A profile reaches Steam only through the backend and the environment, so those are all that is compared.
            var launcherEnvironment = compat?.environment ?? [:]
            for (k, v) in game.environment { launcherEnvironment[k] = v }
            let settings = LauncherSettings(backend: engine.resolve(backend), environment: launcherEnvironment)
            let running = launcher ?? LauncherSettings(backend: engine.resolve(Self.launcherBackend(on: engine, chosen: .auto)))
            return LaunchPlan(arguments: args, workingDirectory: exe.deletingLastPathComponent(), backend: backend,
                              tweaks: LaunchTweaks(dllOverrides: steam.dllOverrides + overrides.filter { !steam.dllOverrides.contains($0) },
                                                   environment: environment, verboseLogs: verboseLogs, dotNetAvailable: dotNet),
                              chromiumHelpers: steam.chromiumHelpers, components: compat?.components ?? [],
                              registry: registry, compat: compat, needsFreshLauncher: settings != running,
                              launcherSettings: settings)

        case .epic(_, let uri):
            let epic = AppPresets.epic
            guard epic.isInstalled(in: space) else { throw PlanError.launcherMissing("Epic Games Launcher") }
            let exe = epic.executableURL(in: space)
            return LaunchPlan(arguments: [exe.path] + epic.launchArguments + [uri],
                              workingDirectory: exe.deletingLastPathComponent(), backend: backend,
                              tweaks: tweaks, chromiumHelpers: epic.chromiumHelpers, components: compat?.components ?? [],
                              registry: registry, compat: compat)
        }
    }

    /// `arguments` without the options `user` already has. An option is a `-flag` or `+command` with the values that
    /// follow it (`-screen-fullscreen 0`), so a value is never left behind without its flag.
    static func dropping(_ arguments: [String], setIn user: [String]) -> [String] {
        var groups: [[String]] = []
        for arg in arguments {
            if arg.hasPrefix("-") || arg.hasPrefix("+") || groups.isEmpty { groups.append([arg]) }
            else { groups[groups.count - 1].append(arg) }
        }
        return groups.filter { !user.contains($0[0]) }.flatMap { $0 }
    }

    /// What a store launcher runs with when the user chose nothing: on G-Player Wine with D3DMetal, D3DMetal, which
    /// most games it starts take (64-bit DirectX 10–12), so they don't need it restarted; the engine's default otherwise.
    static func launcherBackend(on engine: EngineInfo, chosen: GraphicsBackend) -> GraphicsBackend {
        chosen == .auto && engine.kind == .crossover && engine.backends.contains(.d3dmetal) ? .d3dmetal : chosen
    }

    /// The programs a game starts, for settings Wine keeps per program. Searching a Steam game's folder is slow, so it only
    /// happens when there are known fixes that may need the names.
    static func programNames(of game: Game, in space: Space, fixes: [GameFix], given: [String]?) -> [String] {
        if let given { return given }
        switch game.source {
        case .executable: return game.executableURL(in: space).map { [$0.lastPathComponent] } ?? []
        case .steam(let appID): return fixes.isEmpty ? [] : SteamLibrary.programNames(appID: appID, in: space)
        case .epic: return []
        }
    }

    /// True when the space has .NET, so Wine must be allowed to load it: Wine Mono, Microsoft's .NET 4 runtime, or a
    /// `dotnet…` component G-Player installed.
    static func hasDotNet(_ space: Space) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: space.driveC.appendingPathComponent("windows/mono").path)
            || fm.fileExists(atPath: space.driveC.appendingPathComponent("windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll").path)
            || RuntimeInstaller.recorded(in: space).contains { $0.hasPrefix("dotnet") }
    }

    /// `-noverifyfiles` keeps Steam from restoring its helper; only safe once the client is fully downloaded.
    static func steamReadyFlags(_ preset: AppPreset, _ space: Space) -> [String] {
        preset.id == "steam" && SteamLibrary.isClientReady(in: space) ? ["-noverifyfiles"] : []
    }
}
