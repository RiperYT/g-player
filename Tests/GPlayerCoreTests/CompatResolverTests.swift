import Foundation
import Testing
@testable import GPlayerCore

@Suite struct CompatResolverTests {
    let staging = EngineCatalog.wineStaging
    let gptk = EngineCatalog.gptk

    func resolve(_ analysis: GameAnalysis?, fixes: [GameFix] = [], options: LaunchOptions = .default,
                 engine: EngineInfo = EngineCatalog.wineStaging, user: GraphicsBackend = .auto) -> CompatPlan {
        CompatResolver.resolve(.init(engine: engine, analysis: analysis, fixes: fixes, options: options, userBackend: user))
    }

    @Test func baseComponentsAlwaysComeFirst() {
        let plan = resolve(nil)
        #expect(plan.components.prefix(2) == ["vcrun2022", "d3dcompiler_47"])
        #expect(plan.backend == .dxvk)
    }

    @Test func dx12UnityFallsBackToDX11OnStaging() {
        let plan = resolve(GameAnalysis(engine: .unity, graphics: [.d3d11, .d3d12], architecture: .x64))
        #expect(plan.arguments.contains("-force-d3d11"))
        #expect(plan.backend == .dxvk)
    }

    @Test func anUnrealGameBuiltForDX12AloneIsNotForcedToDX11() {
        let only12 = GameAnalysis(engine: .unreal, graphics: [.d3d11, .d3d12], architecture: .x64, onlyDirect3D12: true)
        let staging = resolve(only12)
        #expect(!staging.arguments.contains("-dx11"))
        #expect(staging.blockers.contains { $0.title == "Needs DirectX 12" })
        let metal = resolve(only12, engine: gptk)
        #expect(metal.backend == .d3dmetal && metal.blockers.isEmpty && !metal.arguments.contains("-dx11"))
        // One that has DirectX 11 shaders too still falls back.
        #expect(resolve(GameAnalysis(engine: .unreal, graphics: [.d3d12], architecture: .x64)).arguments.contains("-dx11"))
    }

    @Test func dx12UsesD3DMetalWhereAvailable() {
        let plan = resolve(GameAnalysis(engine: .unreal, graphics: [.d3d12], architecture: .x64), engine: gptk)
        #expect(plan.backend == .d3dmetal)
        #expect(!plan.arguments.contains("-dx11"))
    }

    @Test func windowModeSpeaksEachEnginesLanguage() {
        let w = LaunchOptions(windowMode: .windowed)
        #expect(resolve(GameAnalysis(engine: .unity), options: w).arguments.suffix(2) == ["-screen-fullscreen", "0"])
        #expect(resolve(GameAnalysis(engine: .unreal), options: w).arguments.contains("-windowed"))
        #expect(resolve(GameAnalysis(engine: .godot), options: w).arguments.contains("--windowed"))
    }

    @Test func compatibleProfileIsPlainWine() {
        let fix = GameFix(id: "steam-1", components: ["d3dx9"], environment: ["FOO": "1"], source: "test")
        let plan = resolve(GameAnalysis(engine: .unity), fixes: [fix], options: LaunchOptions(profile: .compatible))
        #expect(plan.backend == .wined3d)
        #expect(plan.environment["FOO"] == nil)
        #expect(plan.environment["WINEESYNC"] == "0")
        #expect(plan.components.contains("d3dx9"))                         // components are kept
        #expect(plan.arguments.suffix(2) == ["-screen-fullscreen", "0"])   // compatible opens a window
    }

    @Test func knownFixesApplyAndCanBeTurnedOff() {
        let fix = GameFix(id: "steam-2", title: "Game", components: ["xact"], dllOverrides: ["xaudio2_7": .native],
                          environment: ["DXVK_HUD": "0"], arguments: ["-nolauncher"], source: "test")
        let on = resolve(nil, fixes: [fix])
        #expect(on.appliedFixIDs == ["steam-2"])
        #expect(on.dllOverrides["xaudio2_7"] == .native)
        #expect(on.arguments.contains("-nolauncher"))
        #expect(on.components.contains("xact"))
        let off = resolve(nil, fixes: [fix], options: LaunchOptions(useKnownFixes: false))
        #expect(off.appliedFixIDs.isEmpty)
        let disabled = resolve(nil, fixes: [fix], options: LaunchOptions(disabledFixIDs: ["steam-2"]))
        #expect(disabled.appliedFixIDs.isEmpty)
    }

    @Test func blockersForAntiCheatAndKnownBrokenGames() {
        let plan = resolve(GameAnalysis(antiCheat: ["EasyAntiCheat"]),
                           fixes: [GameFix(id: "g", source: "g-player", verifiedOnMac: true, macStatus: .broken)])
        #expect(plan.blockers.count == 2)
    }

    @Test func thirtyTwoBitDirectX11RunsThroughDXVK() {
        // MoltenVK 1.4.2 (EngineFixes.moltenVK) gives 32-bit programs their Vulkan memory, so DXVK runs them.
        let plan = resolve(GameAnalysis(graphics: [.d3d11], architecture: .x86))
        #expect(plan.backend == .dxvk)
        #expect(plan.blockers.isEmpty && !plan.warnings.contains { $0.title.contains("32-bit") })
        // Unity, 32-bit, only opengl32 in its imports (Overcooked and others): DirectX 11 in 32 bits.
        let unity = resolve(GameAnalysis(engineName: "Unity", engine: .unity, graphics: [.opengl], architecture: .x86))
        #expect(unity.blockers.isEmpty && unity.backend == .dxvk)
        #expect(!unity.arguments.contains("-force-d3d11"))
    }

    @Test func thirtyTwoBitDirectX11NeedsDXVKNotWineD3D() {
        let compatible = resolve(GameAnalysis(graphics: [.d3d11], architecture: .x86), options: LaunchOptions(profile: .compatible))
        #expect(compatible.warnings.contains { $0.title == "32-bit DirectX 11 needs DXVK" })
        let custom = resolve(GameAnalysis(engine: .unity, graphics: [.d3d10], architecture: .x86),
                             options: LaunchOptions(profile: .custom), user: .wined3d)
        #expect(custom.warnings.contains { $0.title == "32-bit DirectX 10 needs DXVK" })
        let dotnet = resolve(GameAnalysis(graphics: [.d3d11], architecture: .x86, isDotNet: true), options: LaunchOptions(profile: .compatible))
        #expect(!dotnet.warnings.contains { $0.title.contains("32-bit") })
        let modern = resolve(GameAnalysis(graphics: [.d3d11], architecture: .x64), options: LaunchOptions(profile: .compatible))
        #expect(!modern.warnings.contains { $0.title.contains("32-bit") })
    }

    @Test func anOldMoltenVKSaysItWontHelpToInstallAnything() {
        let dxvkLog = "[mvk-error] VK_ERROR_FEATURE_NOT_PRESENT: vkCreateBuffer(): Only external memory handle type VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER_BIT_EXT and VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT are supported.\nerr:   D3D11CoreCreateDevice: Failed to create D3D11 device"
        let found = LogDiagnosis.diagnose(log: dxvkLog, exitStatus: 1, seconds: 4, profile: .recommended)
        #expect(found.first?.title == "This engine can't run 32-bit DirectX 11" && found.first?.remedy == Diagnosis.Remedy.none)
        let unityLog = "d3d11: failed to create device and context (80004005).\nFailed to initialize graphics.\nInitializeEngineGraphics failed"
        let other = LogDiagnosis.diagnose(log: unityLog, exitStatus: 1, seconds: 4, profile: .recommended)
        #expect(other.first?.title == "Graphics didn't start" && other.first?.remedy == .useProfile(.compatible))
        // MoltenVK 1.4.2 still has a vkAllocateMemory message much like it ("handle types"), about something else.
        let newer = "[mvk-error] VK_ERROR_INITIALIZATION_FAILED: vkAllocateMemory(): Only external memory handle types VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER_BIT_EXT, VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLTEXTURE_BIT_EXT or VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT are supported.\nerr:   D3D11CoreCreateDevice: Failed to create D3D11 device"
        #expect(LogDiagnosis.diagnose(log: newer, exitStatus: 1, seconds: 4, profile: .recommended).first?.title == "Graphics didn't start")
        let image = "vkCreateImage(): Only external memory handle type VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLTEXTURE_BIT_EXT and VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT are supported.\nFailed to create D3D11 device"
        #expect(LogDiagnosis.diagnose(log: image, exitStatus: 1, seconds: 4, profile: .recommended).first?.title == "This engine can't run 32-bit DirectX 11")
    }

    @Test func togglesBecomeRegistryAndEnvironment() {
        let plan = resolve(nil, options: LaunchOptions(retina: true, showFrameRate: true))
        #expect(plan.registry.contains(RegistryValue(key: #"HKCU\Software\Wine\Mac Driver"#, name: "RetinaMode", value: "y")))
        #expect(plan.environment["MTL_HUD_ENABLED"] == "1")
    }

    @Test func customProfileUsesTheUsersBackend() {
        #expect(resolve(nil, options: LaunchOptions(profile: .custom), user: .wined3d).backend == .wined3d)
        #expect(resolve(nil, options: LaunchOptions(profile: .custom), user: .d3dmetal).backend == .dxvk)  // not on staging
    }

    @Test func chromiumGamesGetTheDrawingFix() {
        #expect(resolve(GameAnalysis(engine: .electron)).arguments.contains("--in-process-gpu"))
    }

    @Test func replacementsRewriteArguments() {
        let out = CompatResolver.apply([ArgumentReplacement(from: "launcher\\.exe", to: "game.exe")],
                                       to: ["C:/x/Launcher.EXE", "-a"])
        #expect(out == ["C:/x/game.exe", "-a"])
        #expect(CompatResolver.apply([ArgumentReplacement(from: "(", to: "x")], to: ["a(b"]) == ["axb"])   // bad regex
    }

    @Test func multiFlagArgumentsAreSplit() {
        let fix = GameFix(id: "steam-9", arguments: ["-skipdrivercheck -noHDR"], source: "test")
        #expect(resolve(nil, fixes: [fix]).arguments.suffix(2) == ["-skipdrivercheck", "-noHDR"])
    }

    // MARK: Anti-cheat

    @Test func everyAntiCheatRuleInTheRulesFileIsClassified() throws {
        let url = try #require(CoreResources.url("steamdb-rules.ini"))
        var section = "", names = Set<String>()
        for raw in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
            guard section == "AntiCheat", !line.isEmpty, !line.hasPrefix(";"), let equals = line.firstIndex(of: "=") else { continue }
            names.insert(line[..<equals].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "[]", with: ""))
        }
        #expect(names.count >= 16)
        for name in names { #expect(AntiCheatPolicy.severities[name] != nil, "\(name) is not classified in AntiCheatPolicy") }
        for name in AntiCheatPolicy.severities.keys { #expect(names.contains(name), "\(name) is not a rule in steamdb-rules.ini") }
    }

    @Test func kernelAntiCheatBlocksAndTheRestWarns() {
        let blockers = ["EasyAntiCheat", "BattlEye", "EA AntiCheat", "nProtect GameGuard", "XIGNCODE3", "Ricochet", "BlackCipher",
                        "TenProtect", "AntiCheatExpert", "NetEase AntiCheatExperts"]
        for name in blockers {
            let plan = resolve(GameAnalysis(antiCheat: [name]))
            #expect(plan.blockers.map(\.title) == ["Uses \(name)"], "\(name)")
            #expect(plan.warnings.isEmpty)
        }
        for name in ["PunkBuster", "EQU8", "HackShield", "AnyBrain", "FredaikisAntiCheat", "NetEase Yidun"] {
            let plan = resolve(GameAnalysis(antiCheat: [name]))
            #expect(plan.blockers.isEmpty, "\(name)")
            #expect(plan.warnings.map(\.title) == ["Uses \(name)"], "\(name)")
        }
    }

    @Test func namesAreMatchedExactlyNotBySubstring() {
        // "ace" and "riot" used to match inside other words.
        for name in ["Interface Tools", "Patriot Games Guard", "BattlEye Compatible Mod", "Vanguard Wars", "something new"] {
            let plan = resolve(GameAnalysis(antiCheat: [name]))
            #expect(plan.blockers.isEmpty, "\(name)")
        }
        #expect(AntiCheatPolicy.severity(of: "easyanticheat") == .blocker)             // case doesn't matter
        #expect(AntiCheatPolicy.severity(of: "EA_AntiCheat") == .blocker)               // nor does _ or space
        #expect(AntiCheatPolicy.severity(of: "A New System") == .warning)               // unknown: never a blocker
    }

    // MARK: Store games

    private let restart = GameFix(id: "steam-5", title: "Game", replacements: [ArgumentReplacement(from: "launcher", to: "game")], source: "t")

    @Test func storeGamesKeepTheirProgramBecauseTheStoreStartsIt() {
        let fix = GameFix(id: "steam-6", title: "Game", environment: ["A": "1"], replacements: [ArgumentReplacement(from: "x", to: "y")], source: "t")
        let plan = CompatResolver.resolve(.init(engine: staging, analysis: nil, fixes: [fix, restart], options: .default, isStoreGame: true))
        #expect(plan.replacements.isEmpty)
        #expect(plan.environment["A"] == "1")                                            // the rest of the fix still applies
        #expect(plan.appliedFixIDs == ["steam-6"])                                       // replacements alone aren't a fix
        let notes = plan.warnings.filter { $0.title == "Some known fixes change how the program starts; they work only for games you add yourself." }
        #expect(notes.count == 1)
    }

    @Test func gamesAddedByHandGetTheirReplacements() {
        let plan = CompatResolver.resolve(.init(engine: staging, analysis: nil, fixes: [restart], options: .default, isStoreGame: false))
        #expect(plan.replacements == restart.replacements)
        #expect(plan.appliedFixIDs == ["steam-5"])
        #expect(!plan.warnings.contains { $0.title.contains("how the program starts") })
    }

    @Test func storeGamesDoNotNeedLaunchersInTheSpace() {
        let analysis = GameAnalysis(launchers: ["Ubisoft", "EA App"])
        let store = CompatResolver.resolve(.init(engine: staging, analysis: analysis, fixes: [], options: .default, isStoreGame: true))
        #expect(!store.warnings.contains { $0.title.hasPrefix("Needs ") })
        let manual = CompatResolver.resolve(.init(engine: staging, analysis: analysis, fixes: [], options: .default, isStoreGame: false))
        #expect(manual.warnings.map(\.title) == ["Needs Ubisoft", "Needs EA App"])
    }

    @Test func aLauncherGetAppsDoesntOfferIsInstalledByHand() {
        // Get Apps offers Steam and Epic only: for another launcher it can't be where the note sends people.
        func detail(of launcher: String) -> String? {
            let input = CompatResolver.Input(engine: staging, analysis: GameAnalysis(launchers: [launcher]), fixes: [],
                                             options: .default, isStoreGame: false)
            return CompatResolver.resolve(input).warnings.first { $0.title == "Needs \(launcher)" }?.detail
        }
        for launcher in ["Ubisoft", "EA App", "Rockstar", "Paradox_Launcher"] {
            let text = detail(of: launcher) ?? ""
            #expect(text.contains("Run Program…") && !text.contains("Get Apps"), "\(text)")
        }
        #expect(detail(of: "Epic")?.contains("from Get Apps") == true)
        #expect(AppPresets.offered(launcher: "Ubisoft") == nil && AppPresets.offered(launcher: "Epic")?.id == "epic")
    }

    // MARK: Profiles

    @Test func fastIsOnlyOfferedWhereD3DMetalIs() {
        #expect(LaunchProfile.available(for: staging) == [.recommended, .compatible, .custom])
        #expect(LaunchProfile.available(for: gptk) == [.recommended, .compatible, .fast, .custom])
        #expect(LaunchProfile.allCases.contains(.fast))
    }

    @Test func aStoredFastProfileOnStagingIsRecommended() {
        let analysis = GameAnalysis(engine: .unity, graphics: [.d3d11, .d3d12], architecture: .x64)
        let fast = resolve(analysis, options: LaunchOptions(profile: .fast))
        let recommended = resolve(analysis)
        #expect(fast == recommended)
        #expect(fast.backend == .dxvk)
        // On the toolkit it still means D3DMetal, even for a DirectX 11 game.
        let dx11 = GameAnalysis(graphics: [.d3d11], architecture: .x64)
        #expect(resolve(dx11, options: LaunchOptions(profile: .fast), engine: gptk).backend == .d3dmetal)
    }

    @Test func profileSummariesSayWhatTheyDo() {
        #expect(LaunchProfile.custom.summary == "Graphics you choose under Advanced. G-Player never switches them.")
        for profile in LaunchProfile.allCases { #expect(!profile.summary.isEmpty && !profile.title.isEmpty) }
    }
}

@Suite struct RegistryFileTests {
    @Test func writesREGEDIT4WithGroupedKeys() {
        let text = RegistryFile.text([
            RegistryValue(key: #"HKCU\Software\Wine\Mac Driver"#, name: "RetinaMode", value: "y"),
            RegistryValue(key: #"HKCU\Software\Wine\Direct3D"#, name: "VideoMemorySize", type: "REG_DWORD", value: "4096"),
            RegistryValue(key: #"HKCU\Software\Wine\Mac Driver"#, name: "Path", value: #"C:\a "b""#),
        ])
        #expect(text == """
        REGEDIT4

        [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
        "RetinaMode"="y"
        "Path"="C:\\\\a \\"b\\""

        [HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
        "VideoMemorySize"=dword:00001000

        """)
    }

    @Test func appDefaultsTargetEachProgram() {
        let values = RegistryFile.appDefaults(exeNames: ["Game.exe"], overrides: ["d3dx9_43": .nativeThenBuiltin])
        #expect(values == [RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\Game.exe\DllOverrides"#,
                                         name: "d3dx9_43", value: "native,builtin")])
    }

    // MARK: Keys that can't be written, deletions

    private func app(_ exe: String, _ name: String = "Version", _ value: String = "win7") -> RegistryValue {
        RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\"# + exe, name: name, value: value)
    }

    @Test func oneBadKeyNeverSpoilsTheRestOfTheFile() {
        let bad = ["Game].exe", "Ga[me.exe", "Ga\"me.exe", "Game\n[HKEY_LOCAL_MACHINE\\Software\\Evil].exe", "Game\r.exe", "Ga\0me.exe"]
        let good = app("Fine.exe")
        let text = RegistryFile.text(bad.map { app($0) } + [good, RegistryValue(key: #"HKCU\Software\Wine\Mac Driver"#, name: "RetinaMode", value: "y")])
        #expect(text == """
        REGEDIT4

        [HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\Fine.exe]
        "Version"="win7"

        [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
        "RetinaMode"="y"

        """)
        for name in bad { #expect(!RegistryFile.isWritable(app(name)), "\(name.debugDescription)") }
        #expect(RegistryFile.isWritable(good))
    }

    @Test func namesAndDataWithQuotesAndBackslashesAreEscapedButLineBreaksAreRefused() {
        let tricky = RegistryValue(key: #"HKCU\Software\Wine"#, name: #"a"b\c"#, value: #"x"y\z"#)
        #expect(RegistryFile.text([tricky]).contains(#""a\"b\\c"="x\"y\\z""#))
        #expect(!RegistryFile.isWritable(RegistryValue(key: #"HKCU\Software\Wine"#, name: "n", value: "two\nlines")))
        #expect(!RegistryFile.isWritable(RegistryValue(key: #"HKCU\Software\Wine"#, name: "n\r", value: "v")))
        #expect(!RegistryFile.isWritable(RegistryValue(key: "", name: "n", value: "v")))
        // A deletion has no data to be wrong.
        #expect(RegistryFile.isWritable(RegistryValue(key: #"HKCU\Software\Wine"#, name: "n", value: "two\nlines", delete: true)))
        #expect(RegistryFile.isWritable(RegistryValue(key: #"HKCU\Software\Wine"#, name: "n", value: "ok", delete: true)))
    }

    @Test func unsafeProgramNamesAreLeftOutOfAppDefaults() {
        let values = RegistryFile.appDefaults(exeNames: ["Good.exe", "Bad[1].exe", "a\\b.exe", ""], overrides: ["d3dx9_43": .native])
        #expect(values.map(\.key) == [#"HKCU\Software\Wine\AppDefaults\Good.exe\DllOverrides"#])
    }

    @Test func aDeletionIsWrittenWithADash() {
        let text = RegistryFile.text([
            RegistryValue(key: #"HKCU\Software\Wine"#, name: "HideWineExports", value: "", delete: true),
            RegistryValue(key: #"HKCU\Software\Wine"#, name: "", value: "", delete: true),
            RegistryValue(key: #"HKCU\Software\Wine"#, name: "Keep", value: "1", delete: false),
        ])
        #expect(text == """
        REGEDIT4

        [HKEY_CURRENT_USER\\Software\\Wine]
        "HideWineExports"=-
        @=-
        "Keep"="1"

        """)
        #expect(RegistryValue(key: "k", name: "n", value: "v").delete == nil)
    }

    @Test func deleteSurvivesTheFixDataAndTheLibraryFile() throws {
        // Older files have no `delete` at all.
        let old = try JSONDecoder().decode(RegistryValue.self, from: Data(#"{"key": "HKCU\\X", "name": "n", "type": "REG_SZ", "value": "v"}"#.utf8))
        #expect(old.delete == nil)
        let deletion = RegistryValue(key: "HKCU\\X", name: "n", value: "", delete: true)
        #expect(try JSONDecoder().decode(RegistryValue.self, from: JSONEncoder().encode(deletion)) == deletion)
    }

    @Test func removalsCoverWhatWasSetBeforeAndIsNotWantedNow() {
        let before = [app("Old.exe"), app("Kept.exe"), app("Kept.exe", "DllOverrides", "native"), app("Changed.exe", "Version", "win7"),
                      RegistryValue(key: #"HKCU\Software\Wine\Mac Driver"#, name: "RetinaMode", value: "y"),
                      RegistryValue(key: #"HKCU\Software\Wine"#, name: "HideWineExports", value: "Y")]
        let now = [app("Kept.exe"), app("Changed.exe", "Version", "win10"), app("New.exe"),
                   RegistryValue(key: #"HKEY_CURRENT_USER\Software\Wine\AppDefaults\KEPT.EXE"#, name: "dllOverrides", value: "native")]
        let removals = RegistryFile.removals(previous: before, current: now)
        // Kept's two values are still wanted and Changed is only changed; Old is gone.
        #expect(removals == [RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\Old.exe"#, name: "Version", value: "", delete: true)])
        let onlyOld = RegistryFile.removals(previous: before, current: [app("Kept.exe"), app("Changed.exe")])
        #expect(onlyOld == [RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\Old.exe"#, name: "Version", value: "", delete: true),
                            RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\Kept.exe"#, name: "DllOverrides", value: "", delete: true)])
        let text = RegistryFile.text(onlyOld)
        #expect(text.contains("[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\Old.exe]\n\"Version\"=-\n"))
    }

    @Test func removalsIgnoreEverythingButAppDefaultsAndRepeats() {
        let other = RegistryValue(key: #"HKCU\Software\Wine\Mac Driver"#, name: "RetinaMode", value: "y")
        #expect(RegistryFile.removals(previous: [other, app("A.exe", "Version"), app("a.exe", "VERSION")], current: [other])
                == [RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\A.exe"#, name: "Version", value: "", delete: true)])
        #expect(RegistryFile.removals(previous: [], current: [app("A.exe")]).isEmpty)
        #expect(RegistryFile.removals(previous: [app("A.exe")], current: [app("A.exe")]).isEmpty)
        // A value that was only ever a deletion is nothing to remove, and a deletion in `current` covers it.
        let deletion = RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\A.exe"#, name: "Version", value: "", delete: true)
        #expect(RegistryFile.removals(previous: [deletion], current: []).isEmpty)
        #expect(RegistryFile.removals(previous: [app("A.exe")], current: [deletion]).isEmpty)
        let hkey = RegistryValue(key: #"HKEY_CURRENT_USER\Software\Wine\AppDefaults\B.exe"#, name: "Version", value: "win7")
        #expect(RegistryFile.removals(previous: [hkey], current: []).count == 1)
    }
}

@Suite struct LogDiagnosisTests {
    @Test func missingVisualCPlusPlusSuggestsTheComponent() {
        let log = #"0128:err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\Games\\X\\x.exe") not found"#
        let d = LogDiagnosis.diagnose(log: log, exitStatus: 1, seconds: 2, profile: .recommended)
        #expect(d.first?.remedy == .installComponents(["vcrun2022"]))
    }

    @Test func graphicsFailureSuggestsCompatible() {
        let d = LogDiagnosis.diagnose(log: "d3d11: failed to create D3D11 device (0x80004005)", exitStatus: 0,
                                      seconds: 40, profile: .recommended)
        #expect(d.map(\.kind) == [.graphics])
        #expect(d.first?.remedy == .useProfile(.compatible))
        let again = LogDiagnosis.diagnose(log: "d3d11: failed to create D3D11 device", exitStatus: 0, seconds: 40, profile: .compatible)
        #expect(again.first?.remedy == Diagnosis.Remedy.none)
    }

    @Test func quickSilentExitAndCleanRuns() {
        #expect(LogDiagnosis.diagnose(log: "", exitStatus: 3, seconds: 4, profile: .recommended).first?.kind == .closedRightAway)
        #expect(LogDiagnosis.diagnose(log: "", exitStatus: 0, seconds: 1800, profile: .recommended).isEmpty)
    }

    // MARK: G-Player's own header

    private func launchLog(command: String, output: String) -> String {
        "G-Player launch\nengine: Wine Staging 11.18\nspace: /Users/me/Spaces/Main\nbackend: DXVK\ncommand: \(command)\n"
            + "WINEDLLOVERRIDES=mscoree,mshtml=\n\n" + output
    }

    @Test func aPathOrTitleInTheHeaderIsNotAnAntiCheatFailure() {
        let log = launchLog(command: #"/Users/me/Games/BattlEye Tester/EasyAntiCheat Demo/vanguard.exe"#, output: "fixme:ntdll:something\n")
        #expect(LogDiagnosis.diagnose(log: log, exitStatus: 0, seconds: 5, profile: .recommended).isEmpty)
        // …and not a graphics or a DLL failure either.
        let words = launchLog(command: "d3d11createdevice failed import_dll Library x.dll not found", output: "")
        #expect(LogDiagnosis.diagnose(log: words, exitStatus: 0, seconds: 500, profile: .recommended).isEmpty)
    }

    @Test func theGamesOwnOutputStillCounts() {
        let log = launchLog(command: "/g/game.exe", output: "[EasyAntiCheat] Failed to initialize\nBattlEye launcher: error\n")
        let found = LogDiagnosis.diagnose(log: log, exitStatus: 1, seconds: 12, profile: .recommended)
        #expect(found.map(\.kind) == [.antiCheat])
        // Text without the header (the tail of a long log) is read as it is, empty lines and all.
        let tail = "line one\n\nnext: battleye service stopped\n"
        #expect(LogDiagnosis.diagnose(log: tail, exitStatus: 1, seconds: 12, profile: .recommended).map(\.kind) == [.antiCheat])
        #expect(LogDiagnosis.diagnose(log: "battleye", exitStatus: 1, seconds: 12, profile: .recommended).map(\.kind) == [.antiCheat])
    }

    @Test func onlyTheFirstEmptyLineEndsTheHeader() {
        let log = launchLog(command: "/g/game.exe", output: "ok\n\nbattleye: kicked\n")
        #expect(LogDiagnosis.withoutHeader(log) == "ok\n\nbattleye: kicked\n")
        #expect(LogDiagnosis.withoutHeader("G-Player launch\ncommand: battleye\n") == "")           // header and nothing else
        #expect(LogDiagnosis.withoutHeader("G-Player launch\ncommand: battleye") == "")
        #expect(LogDiagnosis.withoutHeader("") == "")
        #expect(LogDiagnosis.withoutHeader("G-Player launch\r\n\r\nrest") == "rest")
    }

    @Test func aHeaderIsRecognisedByItsLinesNotOnlyByItsFirst() {
        // A log cut at the top still has the header's later lines; text that merely has an empty line is not a header.
        let cut = "space: /Users/me/battleye\ncommand: /Users/me/battleye/game.exe\nWINEDLLOVERRIDES=mscoree,mshtml=\n\nfine\n"
        #expect(LogDiagnosis.withoutHeader(cut) == "fine\n")
        #expect(LogDiagnosis.diagnose(log: cut, exitStatus: 0, seconds: 5, profile: .recommended).isEmpty)
        let plain = "starting up\n\nbattleye service stopped\n"
        #expect(LogDiagnosis.withoutHeader(plain) == plain[...])
        let startsLikeOne = "command: not really\nbattleye failed\nmore\n"                      // no empty line after it
        #expect(LogDiagnosis.withoutHeader(startsLikeOne) == startsLikeOne[...])
    }

    @Test func unknownMissingDLLHasNoComponent() {
        let log = #"err:module:import_dll Library steam_api64.dll (which is needed by L"C:\\x.exe") not found"#
        let d = LogDiagnosis.diagnose(log: log, exitStatus: 1, seconds: 1, profile: .recommended)
        #expect(d.first?.remedy == Diagnosis.Remedy.none)
        #expect(d.first?.detail.contains("steam_api64.dll") == true)
    }
}
