import Foundation

// Shared types for the compatibility layers (see docs/COMPATIBILITY.md):
//   1. Runtime components installed into a space (Visual C++, d3dcompiler…)      → Runtime*.swift
//   2. What a game is: engine, anti-cheat, DirectX, bitness                         → GameAnalyzer.swift
//   3. Known fixes for single games (seeded from umu-protonfixes, BSD-2-Clause)     → GameFixDatabase.swift
//   4. Launch profiles and the resolver that merges 1–3 with the user's choices     → CompatResolver.swift
//   5. Reading a failed launch's log and saying what went wrong                     → LogDiagnosis.swift

/// How Wine should load one DLL (`WINEDLLOVERRIDES` / `AppDefaults\…\DllOverrides`).
public enum DLLOverrideMode: String, Codable, Sendable, Hashable, CaseIterable {
    case native = "n"
    case builtin = "b"
    case nativeThenBuiltin = "n,b"
    case builtinThenNative = "b,n"
    case disabled = ""

    /// The value Wine's registry expects (`native,builtin`, empty string for disabled).
    public var registryValue: String {
        switch self {
        case .native: "native"
        case .builtin: "builtin"
        case .nativeThenBuiltin: "native,builtin"
        case .builtinThenNative: "builtin,native"
        case .disabled: ""
        }
    }
}

/// One registry value a fix sets. `key` is a full Wine path such as `HKCU\Software\Wine\Direct3D`.
public struct RegistryValue: Codable, Sendable, Hashable {
    public var key: String
    public var name: String
    /// `REG_SZ` or `REG_DWORD`.
    public var type: String
    public var value: String
    /// True removes the value (`"name"=-` in a .reg file); `type` and `value` are then ignored. Nil means set it.
    public var delete: Bool?
    public init(key: String, name: String, type: String = "REG_SZ", value: String, delete: Bool? = nil) {
        self.key = key; self.name = name; self.type = type; self.value = value; self.delete = delete
    }
}

/// Replace part of a game's command line (umu's `replace_command`).
public struct ArgumentReplacement: Codable, Sendable, Hashable {
    public var from: String
    public var to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

/// How a game does on a Mac, as far as anyone has checked.
public enum MacStatus: String, Codable, Sendable, Hashable {
    /// Starts and plays.
    case works
    /// Plays with problems (noted in `notes`).
    case issues
    /// Doesn't start or isn't playable.
    case broken
}

/// A known fix for one game.
public struct GameFix: Codable, Sendable, Hashable, Identifiable {
    /// Stable id, e.g. `steam-292030` or `gplayer-overcooked`.
    public var id: String
    public var title: String?
    public var steamAppIDs: [String]
    /// Lower-cased .exe file names this fix applies to (used for games not from Steam).
    public var exeNames: [String]
    /// Runtime component ids to install into the space (see `RuntimeComponent.id`), e.g. `vcrun2022`.
    public var components: [String]
    public var dllOverrides: [String: DLLOverrideMode]
    public var environment: [String: String]
    public var arguments: [String]
    public var replacements: [ArgumentReplacement]
    public var registry: [RegistryValue]
    public var notes: String?
    /// Where it came from, e.g. `umu-protonfixes@f494092` or `g-player`.
    public var source: String
    /// Someone confirmed it on a Mac. Fixes imported from Linux/Proton start as false.
    public var verifiedOnMac: Bool
    /// Known result on a Mac, if anyone checked.
    public var macStatus: MacStatus?

    public init(id: String, title: String? = nil, steamAppIDs: [String] = [], exeNames: [String] = [],
                components: [String] = [], dllOverrides: [String: DLLOverrideMode] = [:],
                environment: [String: String] = [:], arguments: [String] = [], replacements: [ArgumentReplacement] = [],
                registry: [RegistryValue] = [], notes: String? = nil, source: String, verifiedOnMac: Bool = false,
                macStatus: MacStatus? = nil) {
        self.id = id; self.title = title; self.steamAppIDs = steamAppIDs; self.exeNames = exeNames
        self.components = components; self.dllOverrides = dllOverrides; self.environment = environment
        self.arguments = arguments; self.replacements = replacements; self.registry = registry
        self.notes = notes; self.source = source; self.verifiedOnMac = verifiedOnMac; self.macStatus = macStatus
    }
}

/// Graphics and platform APIs a program uses, from its PE imports and files.
public enum GraphicsAPI: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case d3d8, d3d9, d3d10, d3d11, d3d12, opengl, vulkan
    public static func < (a: GraphicsAPI, b: GraphicsAPI) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
    public var displayName: String {
        switch self {
        case .d3d8: "DirectX 8"
        case .d3d9: "DirectX 9"
        case .d3d10: "DirectX 10"
        case .d3d11: "DirectX 11"
        case .d3d12: "DirectX 12"
        case .opengl: "OpenGL"
        case .vulkan: "Vulkan"
        }
    }
}

/// Engines G-Player has defaults for. Others still get a name from the detection rules.
public enum KnownEngine: String, Codable, Sendable, Hashable, CaseIterable {
    case unity, unreal, godot, gameMaker, rpgMaker, renPy, electron, nwjs, source, source2, other
}

/// What a game is, worked out from its files. Cached on the game; recomputed when its program changes.
public struct GameAnalysis: Codable, Sendable, Hashable {
    /// Bumped when the analyzer learns something new, so older cached results are worked out again.
    public static let currentVersion = 3

    /// Engine name as the detection rules call it ("Unity", "Unreal", "Godot"…), if any.
    public var engineName: String?
    public var engine: KnownEngine?
    /// Anti-cheat systems found ("EasyAntiCheat", "BattlEye"…). Kernel anti-cheat doesn't run under Wine.
    public var antiCheat: [String]
    /// Third-party launchers found ("Ubisoft", "EA", "Rockstar"…).
    public var launchers: [String]
    public var graphics: [GraphicsAPI]
    public var architecture: PEArchitecture?
    public var isDotNet: Bool
    /// Absolute path of the .exe that was analysed. A different program means the result is stale.
    public var programPath: String?
    /// `currentVersion` when this result was made. Nil for results made before versions existed.
    public var version: Int?
    /// Runtime components the game's files use (from their import tables) and don't bring along themselves.
    public var neededComponents: [String]

    public init(engineName: String? = nil, engine: KnownEngine? = nil, antiCheat: [String] = [], launchers: [String] = [],
                graphics: [GraphicsAPI] = [], architecture: PEArchitecture? = nil, isDotNet: Bool = false,
                programPath: String? = nil, version: Int? = nil, neededComponents: [String] = []) {
        self.engineName = engineName; self.engine = engine; self.antiCheat = antiCheat; self.launchers = launchers
        self.graphics = graphics; self.architecture = architecture; self.isDotNet = isDotNet
        self.programPath = programPath; self.version = version; self.neededComponents = neededComponents
    }

    /// Every field is optional on disk, so a library written by an older or newer G-Player still opens.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engineName = c.value(.engineName, default: nil)
        engine = c.value(.engine, default: nil)
        antiCheat = c.value(.antiCheat, default: [])
        launchers = c.value(.launchers, default: [])
        graphics = c.value(.graphics, default: [])
        architecture = c.value(.architecture, default: nil)
        isDotNet = c.value(.isDotNet, default: false)
        programPath = c.value(.programPath, default: nil)
        version = c.value(.version, default: nil)
        neededComponents = c.value(.neededComponents, default: [])
    }

    /// The newest Direct3D the program imports, if any.
    public var newestDirect3D: GraphicsAPI? { graphics.filter { $0 <= .d3d12 && $0 != .opengl }.max() }

    /// The Direct3D the game most likely uses. Unity and Unreal load Direct3D at run time, so their imports
    /// show none (often only OpenGL); their Windows default is DirectX 11 unless a DirectX 12 runtime ships.
    public var likelyDirect3D: GraphicsAPI? {
        newestDirect3D ?? ((engine == .unity || engine == .unreal) ? .d3d11 : nil)
    }

    /// The graphics to name in the UI: the likely Direct3D, else whatever else it uses.
    public var graphicsLabel: String? { likelyDirect3D?.displayName ?? graphics.max()?.displayName }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it is missing or can't be read (a field added or changed by
    /// another version must never stop a whole library file from loading).
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T {
        if let value = try? decodeIfPresent(T.self, forKey: key) { return value }
        return fallback()
    }
}

/// Files that ship inside GPlayerCore/Resources: in the app bundle, or next to the sources in development.
public enum CoreResources {
    public static func url(_ name: String) -> URL? {
        let fm = FileManager.default
        #if DEBUG
        // Lets development builds read resources from a working copy. Release builds ignore the variable,
        // so nothing in the environment can swap the files the app trusts (the shims run during installs).
        if let dir = ProcessInfo.processInfo.environment["GPLAYER_RESOURCES"] {
            let u = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { return u }
        }
        #endif
        if let base = Bundle.main.resourceURL?.appendingPathComponent(name), fm.fileExists(atPath: base.path) { return base }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent(name)
        return fm.fileExists(atPath: source.path) ? source : nil
    }
}
