import Foundation

/// Something the user should know about how a game will run.
public struct CompatNote: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case applied, warning, blocker }
    public var id: String { kind.rawValue + ":" + title }
    public let kind: Kind
    public let title: String
    public let detail: String?

    public init(_ kind: Kind, _ title: String, _ detail: String? = nil) {
        self.kind = kind; self.title = title; self.detail = detail
    }
}

/// Everything the layers decided for one launch, before it becomes a command line.
public struct CompatPlan: Sendable, Equatable {
    public var backend: GraphicsBackend
    /// Arguments from the engine defaults and fixes, placed before the user's own.
    public var arguments: [String]
    public var replacements: [ArgumentReplacement]
    public var environment: [String: String]
    public var dllOverrides: [String: DLLOverrideMode]
    public var registry: [RegistryValue]
    /// Runtime components that must be in the space first.
    public var components: [String]
    public var notes: [CompatNote]
    /// Fixes that were applied, by id.
    public var appliedFixIDs: [String]

    public var blockers: [CompatNote] { notes.filter { $0.kind == .blocker } }
    public var warnings: [CompatNote] { notes.filter { $0.kind == .warning } }
}

/// How an anti-cheat system affects running a game under Wine on a Mac. Keyed by the exact rule names of the
/// `[AntiCheat]` section in `steamdb-rules.ini` (what `GameAnalysis.antiCheat` holds, with `_` shown as a space).
/// A test checks that every rule in the file has an entry here, so updating the rules file means deciding for each
/// new one. Decided from what is publicly known about each system; when that isn't clear, it's a warning.
enum AntiCheatPolicy {
    enum Severity: Equatable { case blocker, warning }

    static let severities: [String: Severity] = [
        // Kernel drivers or services with no macOS or Wine support: the game won't start, or can't be played online.
        "AntiCheatExpert": .blocker,            // Tencent ACE, kernel driver
        "BattlEye": .blocker,                   // kernel service; Wine support is for Linux's Proton only
        "BlackCipher": .blocker,                // Nexon, kernel driver (BlackCat64.sys)
        "EasyAntiCheat": .blocker,              // kernel driver; Wine support is for Linux's Proton only
        "EA_AntiCheat": .blocker,               // EA's Javelin, kernel driver
        "NetEase_AntiCheatExperts": .blocker,   // kernel driver (NeacSafe64.sys)
        "nProtect_GameGuard": .blocker,         // kernel driver
        "Ricochet": .blocker,                   // Call of Duty, kernel driver (Randgrid.sys)
        "TenProtect": .blocker,                 // Tencent, kernel driver
        "XIGNCODE3": .blocker,                  // Wellbia, kernel driver
        // Not known to need a kernel driver, or not known to fail under Wine: online play may not work.
        "AnyBrain": .warning,                   // a behaviour-analysis library
        "EQU8": .warning,                       // has a driver, but runs under Wine in some games
        "FredaikisAntiCheat": .warning,         // small indie system
        "HackShield": .warning,                 // old AhnLab system; results differ by game
        "NetEase_Yidun": .warning,              // service-based
        "PunkBuster": .warning,                 // old; runs under Wine in many games
    ]

    /// Rule names use `_` where the analysis shows a space ("EA AntiCheat").
    static func ruleName(_ shown: String) -> String {
        shown.replacingOccurrences(of: " ", with: "_")
    }

    /// An exact match on the rule name, ignoring case. Names the table doesn't know are warnings, never blockers.
    static func severity(of shown: String) -> Severity {
        let key = ruleName(shown).lowercased()
        return severities.first { $0.key.lowercased() == key }?.value ?? .warning
    }
}

/// Merges the compatibility layers. Pure: no files, no Wine.
///
/// Order (later wins): base components → the profile's graphics backend (and Compatible's environment) → engine
/// defaults → known fixes (all but their components skipped in Compatible) → the plain-word switches (Retina, frame rate).
/// `LaunchPlanner` then puts the space's preset recipe underneath and the user's own arguments and environment on top.
public enum CompatResolver {
    /// Components every space gets.
    public static let baseComponents = ["vcrun2022", "d3dcompiler_47"]

    static let chromiumFlags = ["--no-sandbox", "--in-process-gpu", "--disable-gpu-sandbox"]

    /// Wine's per-program Windows version for each winetricks Windows-version verb: what `winetricks <verb>` passes
    /// to `winecfg -v` (winetricks 20260125, `w_set_winver`). `winxp` is `winxp64` because winetricks says so in a
    /// 64-bit space, which is what every space G-Player makes is.
    static let windowsVersions: [String: String] = [
        "win11": "win11", "win10": "win10", "win81": "win81", "win8": "win8", "win7": "win7",
        "win2k8r2": "win2008r2", "win2k8": "win2008", "vista": "vista", "win2k3": "win2003", "winxp": "winxp64",
        "win2k": "win2k", "winme": "winme", "win98": "win98", "win95": "win95",
        "nt40": "nt40", "nt351": "nt351", "win31": "win31", "win30": "win30", "win20": "win20",
    ]

    /// `hidewineexports=enable|disable` (winetricks `load_hidewineexports`): hides Wine's version exports from programs
    /// that refuse to run under Wine. A Wine Staging feature, and one value for the whole space.
    static let hideWineExportsVerbs = ["hidewineexports=enable": true, "hidewineexports=disable": false]
    static let hideWineExportsKey = #"HKCU\Software\Wine"#

    public struct Input: Sendable {
        public var engine: EngineInfo
        public var analysis: GameAnalysis?
        public var fixes: [GameFix]
        public var options: LaunchOptions
        /// The backend chosen under Advanced (used by the Custom profile).
        public var userBackend: GraphicsBackend
        /// Steam and Epic games: the store starts the program itself.
        public var isStoreGame: Bool
        /// File names of the programs the game starts (`Game.exe`), for settings that Wine keeps per program.
        public var programNames: [String]
        /// What was learned about the game's graphics. Counts only for automatic graphics (see `graphicsChoice`).
        public var autoGraphics: AutoGraphics?

        public init(engine: EngineInfo, analysis: GameAnalysis?, fixes: [GameFix], options: LaunchOptions,
                    userBackend: GraphicsBackend = .auto, isStoreGame: Bool = false, programNames: [String] = [],
                    autoGraphics: AutoGraphics? = nil) {
            self.engine = engine; self.analysis = analysis; self.fixes = fixes; self.options = options
            self.userBackend = userBackend; self.isStoreGame = isStoreGame; self.programNames = programNames
            self.autoGraphics = autoGraphics
        }
    }

    /// Why a 32-bit DirectX 10/11 game fails when the engine's MoltenVK is older than 1.4.1 (G-Player updates it in
    /// the Wine Staging it downloads, see `EngineFixes.moltenVK`).
    public static let oldMoltenVK = String(localized: "Its MoltenVK is older than 1.4.1 and refuses the graphics memory Wine sets up for 32-bit programs. Windows components won't help. Move this space to G-Player Wine, which has a newer one.")

    /// The blocker for a game that only Apple's D3DMetal can run here, which the app offers to fix.
    public static let needsDirectX12 = String(localized: "Needs DirectX 12")
    /// Why an Unreal game built for DirectX 12 alone doesn't start on an engine without D3DMetal.
    public static let onlyDirect3D12 = String(localized: "The game is built for DirectX 12 alone, and it stops at start when asked for DirectX 11. Only Apple's D3DMetal gives DirectX 12 on a Mac.")
    static let useCrossOver = String(localized: "Move this space to G-Player Wine and turn on Apple's D3DMetal in Settings › Engines: Steam keeps running there too.")
    static let turnOnD3DMetal = String(localized: "Turn on Apple's D3DMetal in Settings › Engines; G-Player copies it from your own Game Porting Toolkit.")
    static let chooseD3DMetal = String(localized: "This space has D3DMetal: choose the Recommended profile, or D3DMetal under Advanced.")

    public static func resolve(_ input: Input) -> CompatPlan {
        let a = input.analysis ?? GameAnalysis()
        let options = input.options
        // A stored Fast profile counts as Recommended on an engine that has no D3DMetal.
        let profile = options.profile.effective(on: input.engine)
        var plan = CompatPlan(backend: .auto, arguments: [], replacements: [], environment: [:], dllOverrides: [:],
                              registry: [], components: baseComponents, notes: [], appliedFixIDs: [])

        // Blockers first: things no setting can fix.
        for name in a.antiCheat {
            switch AntiCheatPolicy.severity(of: name) {
            case .blocker:
                plan.notes.append(CompatNote(.blocker, String(localized: "Uses \(name)"),
                    String(localized: "Games with \(name) usually refuse to run under Wine on macOS. Single-player modes sometimes work.")))
            case .warning:
                plan.notes.append(CompatNote(.warning, String(localized: "Uses \(name)"),
                    String(localized: "Online play with \(name) may not work under Wine on macOS.")))
            }
        }
        // Runtimes the game's own files use, installed before it first starts.
        let fromFiles = unique(a.neededComponents.map(RuntimeCatalog.canonicalID)
            .filter { RuntimeCatalog.installsByItself($0) && !baseComponents.contains($0) })
        if !fromFiles.isEmpty {
            plan.components += fromFiles
            plan.notes.append(CompatNote(.applied, String(localized: "Adds \(list(fromFiles.map(plainName)))"), String(localized: "The game's files use them.")))
        }
        let fixes = options.useKnownFixes
            ? input.fixes.filter { !options.disabledFixIDs.contains($0.id) } : []
        for fix in input.fixes where fix.macStatus == .broken {
            plan.notes.append(CompatNote(.blocker, String(localized: "Known not to work on a Mac"), fix.notes))
        }

        // Graphics backend per profile. Fast only gets here on an engine with D3DMetal. Automatic (Recommended and Fast)
        // is `graphicsChoice`: what G-Player has always picked, unless it learned something about this game.
        let supportsMetal = supportsD3DMetal(input.engine, a)
        let newest = a.likelyDirect3D
        switch profile {
        case .recommended, .fast:
            plan.backend = graphicsChoice(input).backend
        case .compatible:
            plan.backend = .wined3d
            plan.environment["WINEESYNC"] = "0"
            plan.environment["WINEMSYNC"] = "0"
            plan.notes.append(CompatNote(.applied, String(localized: "Compatible mode"), String(localized: "Wine's own renderer and no extra fixes.")))
        case .custom:
            plan.backend = input.engine.resolve(input.userBackend)
        }
        plan.backend = input.engine.resolve(plan.backend)

        // Engine defaults.
        var window = options.windowMode
        if profile == .compatible && window == .automatic { window = .windowed }
        switch a.engine {
        case .unity:
            if newest == .d3d12 && plan.backend != .d3dmetal {
                plan.arguments.append("-force-d3d11")
                plan.notes.append(CompatNote(.applied, String(localized: "Starts with DirectX 11"), String(localized: "Unity can fall back from DirectX 12.")))
            }
            switch window {
            case .windowed: plan.arguments += ["-screen-fullscreen", "0"]
            case .fullscreen: plan.arguments += ["-screen-fullscreen", "1"]
            case .automatic: break
            }
        case .unreal:
            if newest == .d3d12 && plan.backend != .d3dmetal {
                if a.onlyDirect3D12 {
                    let advice = supportsMetal ? Self.chooseD3DMetal
                        : input.engine.kind == .crossover ? Self.turnOnD3DMetal : Self.useCrossOver
                    plan.notes.append(CompatNote(.blocker, Self.needsDirectX12, Self.onlyDirect3D12 + " " + advice))
                } else {
                    plan.arguments.append("-dx11")
                    plan.notes.append(CompatNote(.applied, String(localized: "Starts with DirectX 11"), String(localized: "Unreal Engine can fall back from DirectX 12.")))
                }
            }
            if window == .windowed { plan.arguments.append("-windowed") }
            if window == .fullscreen { plan.arguments.append("-fullscreen") }
        case .source, .source2:
            if window == .windowed { plan.arguments += ["-windowed", "-noborder"] }
            if window == .fullscreen { plan.arguments.append("-fullscreen") }
        case .godot:
            if window == .windowed { plan.arguments.append("--windowed") }
            if window == .fullscreen { plan.arguments.append("--fullscreen") }
        case .electron, .nwjs, .rpgMaker:
            plan.arguments += chromiumFlags
            plan.notes.append(CompatNote(.applied, String(localized: "Chromium drawing fix"), String(localized: "Draws inside one process so the window isn't black.")))
        case .gameMaker, .renPy, .other, .none:
            break
        }

        // DirectX 12 with no D3DMetal and no engine fallback.
        if newest == .d3d12 && plan.backend != .d3dmetal && a.engine != .unity && a.engine != .unreal {
            // G-Player Wine has DirectX 12 once D3DMetal is turned on; the other engines have none.
            let detail = input.engine.kind == .crossover
                ? String(localized: "DirectX 12 needs Apple's D3DMetal. Turn it on in Settings › Engines, or choose DirectX 11 in the game's own settings.")
                : String(localized: "This space's engine has no DirectX 12. If the game has a DirectX 11 mode, choose it in the game's own settings.")
            plan.notes.append(CompatNote(.warning, String(localized: "Needs DirectX 12"), detail))
        }
        // 32-bit DirectX 10/11 runs through DXVK only: WineD3D can't give DirectX 10 or 11 on Apple's OpenGL 4.1.
        if a.architecture == .x86 && !a.isDotNet, let d3d = newest, d3d >= .d3d10, d3d < .d3d12,
           input.engine.kind != .gptk, plan.backend == .wined3d {
            plan.notes.append(CompatNote(.warning, String(localized: "32-bit DirectX \(d3d == .d3d10 ? "10" : "11") needs DXVK"),
                String(localized: "Wine's own renderer can't give it on Apple's OpenGL, so the game most likely won't start this way. The Recommended profile uses DXVK.")))
        }
        // A store starts and updates its own launchers, so only games added by hand need them in the space.
        if !input.isStoreGame {
            for launcher in a.launchers {
                let how = AppPresets.offered(launcher: launcher) != nil
                    ? String(localized: "The game starts through \(launcher). Install it into the same space from Get Apps.")
                    : String(localized: "The game starts through \(launcher), which G-Player doesn't offer. Install it into the same space with Run Program…")
                plan.notes.append(CompatNote(.warning, String(localized: "Needs \(launcher)"), how))
            }
        }

        // Known fixes.
        var unsupported: [String] = []          // components that can't be installed
        var versionNeedsProgram = false         // a Windows version fix with no program to set it for
        var hideWineExports = false
        var skippedReplacements = false         // store games start the program themselves
        for fix in fixes {
            let parts = sort(fix.components)
            unsupported += parts.unsupported
            if profile == .compatible {
                plan.components += parts.install                 // components are harmless, keep them
                continue
            }
            var applied: [String] = []
            var touched = false
            if !parts.install.isEmpty { plan.components += parts.install; touched = true; applied.append(String(localized: "Installs \(parts.install.joined(separator: ", "))")) }
            if !fix.dllOverrides.isEmpty {
                for (dll, mode) in fix.dllOverrides { plan.dllOverrides[dll.lowercased()] = mode }
                touched = true
                applied.append(String(localized: "Wine DLL settings for \(fix.dllOverrides.keys.sorted().joined(separator: ", "))"))
            }
            if !fix.environment.isEmpty {
                for (k, v) in fix.environment { plan.environment[k] = v }
                touched = true
                applied.append(String(localized: "\(fix.environment.count) environment settings"))
            }
            // umu sometimes puts several flags in one string ("-skipdrivercheck -noHDR").
            let args = fix.arguments.flatMap { $0.split(separator: " ").map(String.init) }
            if !args.isEmpty { plan.arguments += args; touched = true; applied.append(String(localized: "Launch options \(args.joined(separator: " "))")) }
            if !fix.replacements.isEmpty {
                if input.isStoreGame { skippedReplacements = true }
                else { plan.replacements += fix.replacements; touched = true; applied.append(String(localized: "Changes how the program starts")) }
            }
            if !fix.registry.isEmpty {
                plan.registry += fix.registry
                touched = true
                applied.append(String(localized: "\(fix.registry.count) registry settings"))
            }
            if let version = parts.windowsVersion {
                let programs = input.programNames.filter(RegistryFile.isSafeProgramName)
                if programs.isEmpty { versionNeedsProgram = true }
                else {
                    setWindowsVersion(version, for: programs, in: &plan.registry)
                    touched = true
                    applied.append(String(localized: "Windows version \(version)"))
                }
            }
            if parts.hideWineExports == true { hideWineExports = true; touched = true; applied.append(String(localized: "Hides Wine from the game")) }
            if touched {
                plan.appliedFixIDs.append(fix.id)
                let summary = applied.joined(separator: ". ") + "."
                plan.notes.append(CompatNote(.applied, String(localized: "Known fix for \(fix.title ?? String(localized: "this game", comment: "Inside “Known fix for …”"))"),
                                             fix.verifiedOnMac ? summary : summary + " " + String(localized: "From Linux players, not yet checked on a Mac.")))
            }
        }
        if skippedReplacements {
            plan.notes.append(CompatNote(.warning, String(localized: "Some known fixes change how the program starts; they work only for games you add yourself.")))
        }
        if versionNeedsProgram {
            plan.notes.append(CompatNote(.warning, String(localized: "A known fix couldn't be applied"),
                String(localized: "It sets the Windows version for the game's program, and G-Player doesn't know which program that is.")))
        }
        if hideWineExports {
            plan.notes.append(CompatNote(.applied, String(localized: "Hides Wine from the game"),
                String(localized: "Wine Staging setting for the whole space. G-Player sets it again on every launch, like the Retina setting.")))
        }

        // Plain-word switches. Hiding Wine's exports is one value for the whole space, so every launch says which way it goes.
        plan.registry.append(RegistryValue(key: #"HKCU\Software\Wine\Mac Driver"#, name: "RetinaMode",
                                           value: options.retina ? "y" : "n"))
        plan.registry.append(RegistryValue(key: hideWineExportsKey, name: "HideWineExports", value: hideWineExports ? "Y" : "",
                                           delete: hideWineExports ? nil : true))
        if options.showFrameRate { plan.environment["MTL_HUD_ENABLED"] = "1" }

        // What can't be installed is said once, in plain words. (`plan.components` holds only what can: `sort` saw to that.)
        plan.components = unique(plan.components)
        let cannot = unique(unsupported)
        if !cannot.isEmpty {
            plan.notes.append(CompatNote(.warning, String(localized: "Needs \(list(cannot.map(plainName))), which G-Player can't install yet.")))
        }
        return plan
    }

    // MARK: Pieces of resolve

    /// What a fix's `components` hold, sorted. umu's `protontricks` also carries settings, which aren't components.
    struct FixComponents {
        /// Components to install: the stand-ins replaced by what they stand for, each once.
        var install: [String] = []
        /// Ids that look like components but G-Player can't install.
        var unsupported: [String] = []
        /// Wine's `Version` value, when a Windows version verb was listed (the last one wins).
        var windowsVersion: String?
        /// A `hidewineexports` verb, when listed.
        var hideWineExports: Bool?
    }

    static func sort(_ ids: [String]) -> FixComponents {
        var parts = FixComponents()
        for id in ids {
            if let version = windowsVersions[id] { parts.windowsVersion = version }
            else if let hide = hideWineExportsVerbs[id] { parts.hideWineExports = hide }
            else if RuntimeCatalog.isInstallable(id) { parts.install.append(RuntimeCatalog.canonicalID(id)) }
            else { parts.unsupported.append(id) }
        }
        parts.install = unique(parts.install)
        parts.unsupported = unique(parts.unsupported)
        return parts
    }

    /// `HKCU\Software\Wine\AppDefaults\<program>\Version`, once per program (a later version replaces an earlier one).
    static func setWindowsVersion(_ version: String, for programs: [String], in registry: inout [RegistryValue]) {
        for program in programs {
            let key = #"HKCU\Software\Wine\AppDefaults\"# + program
            registry.removeAll { $0.key.caseInsensitiveCompare(key) == .orderedSame && $0.name == "Version" }
            registry.append(RegistryValue(key: key, name: "Version", value: version))
        }
    }

    /// How a note names a component or setting G-Player can't install.
    static func plainName(_ id: String) -> String {
        id.contains("=") ? String(localized: "the \(id) setting", comment: "Inside “Needs …, which G-Player can’t install yet.”") : RuntimeCatalog.plainName(id)
    }

    /// "a", "a and b", "a, b and c".
    public static func list(_ names: [String]) -> String {
        names.count < 2 ? names.joined()
            : String(localized: "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])", comment: "A list of names: “A, B and C”")
    }

    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Applies `replacements` to a finished argument list. `from` is a case-insensitive regular expression,
    /// as in umu-protonfixes' `replace_command` (it also rewrites the program path). An invalid pattern is
    /// treated as plain text.
    public static func apply(_ replacements: [ArgumentReplacement], to arguments: [String]) -> [String] {
        guard !replacements.isEmpty else { return arguments }
        return arguments.map { arg in
            replacements.reduce(arg) { text, r in
                if let re = try? NSRegularExpression(pattern: r.from, options: [.caseInsensitive]) {
                    return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                       withTemplate: NSRegularExpression.escapedTemplate(for: r.to))
                }
                return text.replacingOccurrences(of: r.from, with: r.to, options: .caseInsensitive)
            }
        }
    }
}

/// Writes registry values as a `.reg` file for `wine regedit /S`, which sets many values in one call.
public enum RegistryFile {
    /// REGEDIT4 text for the values. A value that can't be written safely (see `isWritable`) is left out, so one odd
    /// program name never spoils the rest of the file.
    public static func text(_ values: [RegistryValue]) -> String {
        var out = "REGEDIT4\n"
        var byKey: [(String, [RegistryValue])] = []
        for v in values where isWritable(v) {
            if let i = byKey.firstIndex(where: { $0.0.caseInsensitiveCompare(v.key) == .orderedSame }) { byKey[i].1.append(v) }
            else { byKey.append((v.key, [v])) }
        }
        for (key, entries) in byKey {
            out += "\n[\(expand(key))]\n"
            for e in entries {
                let name = e.name.isEmpty ? "@" : "\"\(escape(e.name))\""
                if e.delete == true {
                    out += "\(name)=-\n"
                } else if e.type.uppercased() == "REG_DWORD", let n = UInt32(e.value.hasPrefix("0x") ? String(e.value.dropFirst(2)) : e.value,
                                                                              radix: e.value.hasPrefix("0x") ? 16 : 10) {
                    out += "\(name)=dword:\(String(format: "%08x", n))\n"
                } else {
                    out += "\(name)=\"\(escape(e.value))\"\n"
                }
            }
        }
        return out
    }

    /// False for a value a .reg file can't hold: a key path with `[`, `]` or `"` (they end the `[key]` line early or can't
    /// be escaped there), or a line break or NUL anywhere. Quotes and backslashes in names and data are escaped instead.
    public static func isWritable(_ value: RegistryValue) -> Bool {
        let breaks = CharacterSet(charactersIn: "\r\n\0")
        let brackets = CharacterSet(charactersIn: "[]\"")
        let texts = value.delete == true ? [value.key, value.name] : [value.key, value.name, value.value]
        return !value.key.isEmpty
            && value.key.rangeOfCharacter(from: brackets) == nil
            && texts.allSatisfy { $0.rangeOfCharacter(from: breaks) == nil }
    }

    /// True when `name` can be one part of a key path: a program's file name. `\` would split the key in two.
    public static func isSafeProgramName(_ name: String) -> Bool {
        let bad = CharacterSet(charactersIn: "[]\"\\\r\n\0")
        return !name.isEmpty && name.rangeOfCharacter(from: bad) == nil
    }

    static func expand(_ key: String) -> String {
        let map = ["HKCU\\": "HKEY_CURRENT_USER\\", "HKLM\\": "HKEY_LOCAL_MACHINE\\", "HKCR\\": "HKEY_CLASSES_ROOT\\"]
        for (short, long) in map where key.uppercased().hasPrefix(short) { return long + key.dropFirst(short.count) }
        return key
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Per-program DLL settings, so they also reach games that Steam starts for us. Program names that can't be part
    /// of a key path are skipped.
    public static func appDefaults(exeNames: [String], overrides: [String: DLLOverrideMode]) -> [RegistryValue] {
        exeNames.filter(isSafeProgramName).flatMap { exe in
            overrides.sorted { $0.key < $1.key }.map { dll, mode in
                RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\"# + exe + #"\DllOverrides"#, name: dll, value: mode.registryValue)
            }
        }
    }

    /// Deletions for per-program values (`HKCU\Software\Wine\AppDefaults\…`) that were set before and aren't wanted any
    /// more, so a setting from a fix the user turned off, or a program the game no longer starts, doesn't stay behind
    /// in the space. Other values (the Retina switch…) are written on every launch and never need this.
    public static func removals(previous: [RegistryValue], current: [RegistryValue]) -> [RegistryValue] {
        let wanted = Set(current.map(identity))
        var seen = Set<String>()
        var result: [RegistryValue] = []
        for old in previous where old.delete != true && isAppDefaults(old.key) {
            let id = identity(old)
            guard !wanted.contains(id), seen.insert(id).inserted else { continue }
            result.append(RegistryValue(key: old.key, name: old.name, type: old.type, value: "", delete: true))
        }
        return result
    }

    /// Key and value name, the way Wine compares them: ignoring case, `HKCU` and `HKEY_CURRENT_USER` alike.
    private static func identity(_ v: RegistryValue) -> String {
        expand(v.key).lowercased() + "\u{0}" + v.name.lowercased()
    }

    private static func isAppDefaults(_ key: String) -> Bool {
        expand(key).lowercased().hasPrefix(#"hkey_current_user\software\wine\appdefaults\"#)
    }
}
