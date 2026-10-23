import Foundation
import Testing
@testable import GPlayerCore

@Suite struct WineEnvironmentTests {
    let s = Space(name: "Main", path: "/tmp/Main", engineID: "x", origin: .managed)

    @Test func dxvkIsTheStagingDefault() {
        let env = WineEnvironment.make(engine: fakeEngine(), space: s, backend: .auto, base: [:])
        #expect(env["WINEPREFIX"] == "/tmp/Main")
        #expect(env["WINEDLLOVERRIDES"]?.contains("d3d11,d3d10core=n,b") == true)
        #expect(env["DXVK_ASYNC"] == "1")
        #expect(env["PATH"]?.hasPrefix("/tmp/engine/wine/bin") == true)
    }

    @Test func d3dmetalOnlyOnTheToolkit() {
        let staging = WineEnvironment.make(engine: fakeEngine(), space: s, backend: .d3dmetal, base: [:])
        #expect(staging["DYLD_FALLBACK_LIBRARY_PATH"] == nil)          // falls back to DXVK
        let gptk = WineEnvironment.make(engine: fakeEngine(EngineCatalog.gptk), space: s, backend: .auto, base: [:])
        #expect(gptk["DYLD_FALLBACK_LIBRARY_PATH"] == "/tmp/engine/wine/lib/external:/usr/lib")
        #expect(gptk["WINEDLLOVERRIDES"]?.contains("dxgi=b") == true)
    }

    @Test func dotNetStaysDisabledUntilTheSpaceHasIt() {
        let without = WineEnvironment.make(engine: fakeEngine(), space: s, backend: .wined3d, base: [:])
        #expect(without["WINEDLLOVERRIDES"]?.hasPrefix("mscoree,mshtml=;winemenubuilder.exe=d") == true)
        #expect(LaunchTweaks().dotNetAvailable == false)

        let tweaks = LaunchTweaks(dotNetAvailable: true)
        let with = WineEnvironment.make(engine: fakeEngine(), space: s, backend: .wined3d, tweaks: tweaks, base: [:])
        #expect(with["WINEDLLOVERRIDES"] == "mshtml=;winemenubuilder.exe=d")
        #expect(with["WINEDLLOVERRIDES"]?.contains("mscoree") == false)
        // Gecko stays off, and everything else keeps working next to it.
        let dxvk = WineEnvironment.make(engine: fakeEngine(), space: s, backend: .dxvk,
                                        tweaks: LaunchTweaks(dllOverrides: ["bcrypt=b"], dotNetAvailable: true), base: [:])
        #expect(dxvk["WINEDLLOVERRIDES"] == "mshtml=;winemenubuilder.exe=d;d3d11,d3d10core=n,b;bcrypt=b")
    }

    @Test func tweaksAreAppendedAndUserEnvironmentWins() {
        let t = LaunchTweaks(dllOverrides: ["bcrypt=b"], environment: ["DXVK_ASYNC": "0"])
        let env = WineEnvironment.make(engine: fakeEngine(), space: s, backend: .dxvk, tweaks: t, base: ["HOME": "/h", "SECRET": "x"])
        #expect(env["WINEDLLOVERRIDES"]?.hasSuffix(";bcrypt=b") == true)
        #expect(env["DXVK_ASYNC"] == "0")
        #expect(env["HOME"] == "/h")
        #expect(env["SECRET"] == nil)
    }
}

@Suite struct LaunchPlannerTests {
    @Test func steamGamesGoThroughSteam() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Steam"), preset: "steam")
        tmp.file("Steam/drive_c/Program Files (x86)/Steam/steam.exe")
        let g = Game(title: "Overcooked", spaceID: s.id, source: .steam(appID: "448510"))
        let plan = try LaunchPlanner.plan(for: g, in: s)
        #expect(plan.arguments.suffix(2) == ["-applaunch", "448510"])
        #expect(plan.arguments.contains("-no-cef-sandbox"))
        #expect(!plan.arguments.contains("-noverifyfiles"))            // client not downloaded yet
        #expect(plan.tweaks.dllOverrides.contains("bcrypt=b;ncrypt=b"))
        #expect(plan.chromiumHelpers == AppPresets.steam.chromiumHelpers)
    }

    @Test func aReadySteamSkipsVerification() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Steam"), preset: "steam")
        tmp.file("Steam/drive_c/Program Files (x86)/Steam/steam.exe")
        tmp.file("Steam/drive_c/Program Files (x86)/Steam/steamclient64.dll")
        tmp.dir("Steam/drive_c/Program Files (x86)/Steam/clientui")
        tmp.file("Steam/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper.exe")
        let launcher = Game(title: "Steam", kind: .app, spaceID: s.id,
                            executablePath: "drive_c/Program Files (x86)/Steam/steam.exe")
        #expect(try LaunchPlanner.plan(for: launcher, in: s).arguments.contains("-noverifyfiles"))
    }

    // MARK: Steam games

    /// A space with Steam, and Steam game 1 installed with a program in its folder.
    private func steamSpace(_ tmp: TempFolder, engine: String = EngineCatalog.wineStaging.id) -> Space {
        var s = space(at: tmp.prefix("Steam"), preset: "steam")
        s.engineID = engine
        let steam = "Steam/drive_c/Program Files (x86)/Steam"
        tmp.file("\(steam)/steam.exe")
        tmp.file("\(steam)/steamapps/appmanifest_1.acf", contents: Data("""
            "AppState" { "appid" "1" "name" "Test Game" "StateFlags" "4" "installdir" "TestGame" }
            """.utf8))
        tmp.file("\(steam)/steamapps/common/TestGame/TestGame.exe")
        return s
    }

    private func steamGame(_ s: Space, _ options: LaunchOptions? = nil, environment: [String: String] = [:]) -> Game {
        var g = Game(title: "Test Game", spaceID: s.id, source: .steam(appID: "1"), environment: environment)
        g.options = options
        return g
    }

    private let overrideFix = GameFix(id: "steam-1", steamAppIDs: ["1"], dllOverrides: ["xaudio2_7": .native], source: "t")

    @Test func programNamesFromTheCallerReplaceTheFolderSearch() throws {
        let tmp = TempFolder()
        let s = steamSpace(tmp)
        let scanned = try LaunchPlanner.plan(for: steamGame(s), in: s, fixes: [overrideFix])
        #expect(scanned.registry.contains { $0.key == #"HKCU\Software\Wine\AppDefaults\TestGame.exe\DllOverrides"# && $0.name == "xaudio2_7" })

        let given = try LaunchPlanner.plan(for: steamGame(s), in: s, fixes: [overrideFix], programNames: ["Given.exe", "Other.exe"])
        let keys = Set(given.registry.filter { $0.key.contains("AppDefaults") }.map(\.key))
        #expect(keys == [#"HKCU\Software\Wine\AppDefaults\Given.exe\DllOverrides"#, #"HKCU\Software\Wine\AppDefaults\Other.exe\DllOverrides"#])

        // An empty list is an answer too: nothing to write for, and no search.
        let none = try LaunchPlanner.plan(for: steamGame(s), in: s, fixes: [overrideFix], programNames: [])
        #expect(!none.registry.contains { $0.key.contains("AppDefaults") })
    }

    @Test func aWindowsVersionFixGoesToTheProgramNamesTheCallerGave() throws {
        let tmp = TempFolder()
        let s = steamSpace(tmp)
        let fix = GameFix(id: "steam-1", steamAppIDs: ["1"], components: ["win7"], source: "t")
        let plan = try LaunchPlanner.plan(for: steamGame(s), in: s, fixes: [fix], programNames: ["Given.exe"])
        #expect(plan.registry.contains(RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\Given.exe"#, name: "Version", value: "win7")))
        #expect(!plan.components.contains("win7"))
        // A program the user added is its own program name.
        let exe = tmp.file("Steam/drive_c/Games/My Game.exe")
        let mine = Game(title: "Mine", spaceID: s.id, executablePath: Game.storedPath(for: exe, in: s))
        let own = try LaunchPlanner.plan(for: mine, in: s, fixes: [fix])
        #expect(own.registry.contains(RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\My Game.exe"#, name: "Version", value: "win7")))
    }

    @Test func aPlainSteamGameDoesNotNeedAFreshSteam() throws {
        let tmp = TempFolder()
        let s = steamSpace(tmp)
        let plan = try LaunchPlanner.plan(for: steamGame(s), in: s)
        #expect(plan.needsFreshLauncher == false)
        #expect(plan.compat?.environment.isEmpty == true)
        // Arguments and DLL settings reach a running Steam without a restart (`-applaunch`, and the registry).
        var withArguments = steamGame(s)
        withArguments.arguments = ["-windowed"]
        #expect(try LaunchPlanner.plan(for: withArguments, in: s, fixes: [overrideFix]).needsFreshLauncher == false)
        // A stored Fast profile on an engine without D3DMetal is Recommended.
        #expect(try LaunchPlanner.plan(for: steamGame(s, LaunchOptions(profile: .fast)), in: s).needsFreshLauncher == false)
        // A switch that only changes the registry doesn't need it either.
        #expect(try LaunchPlanner.plan(for: steamGame(s, LaunchOptions(windowMode: .windowed, retina: true)), in: s).needsFreshLauncher == false)
    }

    @Test func environmentAndBackendsNeedAFreshSteam() throws {
        let tmp = TempFolder()
        let s = steamSpace(tmp)
        // The profile's own environment and backend.
        let compatible = try LaunchPlanner.plan(for: steamGame(s, LaunchOptions(profile: .compatible)), in: s)
        #expect(compatible.needsFreshLauncher)
        #expect(compatible.backend == .wined3d && compatible.compat?.environment["WINEESYNC"] == "0")
        // A profile is no difference by itself: Custom with nothing chosen starts Steam the way it already is.
        #expect(try LaunchPlanner.plan(for: steamGame(s, LaunchOptions(profile: .custom)), in: s).needsFreshLauncher == false)
        var chosen = steamGame(s, LaunchOptions(profile: .custom))
        chosen.graphics = .wined3d
        #expect(try LaunchPlanner.plan(for: chosen, in: s).needsFreshLauncher)
        // A fix's environment, the frame rate overlay, and the game's own variables.
        let env = GameFix(id: "steam-1", steamAppIDs: ["1"], environment: ["DXVK_HUD": "0"], source: "t")
        #expect(try LaunchPlanner.plan(for: steamGame(s), in: s, fixes: [env]).needsFreshLauncher)
        #expect(try LaunchPlanner.plan(for: steamGame(s, LaunchOptions(showFrameRate: true)), in: s).needsFreshLauncher)
        #expect(try LaunchPlanner.plan(for: steamGame(s, environment: ["WINEDEBUG": "+all"]), in: s).needsFreshLauncher)
        // Fixes switched off don't count.
        #expect(try LaunchPlanner.plan(for: steamGame(s, LaunchOptions(useKnownFixes: false)), in: s, fixes: [env]).needsFreshLauncher == false)
    }

    @Test func theToolkitsDefaultBackendIsNotADifference() throws {
        let tmp = TempFolder()
        let s = steamSpace(tmp, engine: EngineCatalog.gptk.id)
        let plan = try LaunchPlanner.plan(for: steamGame(s), in: s)
        #expect(plan.backend == .d3dmetal)
        #expect(plan.needsFreshLauncher == false)
        // Fast is D3DMetal here too: the same Steam serves it.
        #expect(try LaunchPlanner.plan(for: steamGame(s, LaunchOptions(profile: .fast)), in: s).needsFreshLauncher == false)
    }

    // MARK: What a running Steam was started with

    /// A 32-bit Unity game, as the Compatible profile gets it: Wine's own renderer and no esync or msync.
    private func compatibleUnityGame(_ s: Space) -> Game {
        var g = steamGame(s, LaunchOptions(profile: .compatible))
        g.analysis = GameAnalysis(engine: .unity, graphics: [.d3d11], architecture: .x86)
        return g
    }

    @Test func aSteamStartedForTheGameDoesNotNeedRestartingForIt() throws {
        let tmp = TempFolder()
        let s = steamSpace(tmp)
        let g = compatibleUnityGame(s)
        let plan = try LaunchPlanner.plan(for: g, in: s)
        let settings = try #require(plan.launcherSettings)
        #expect(plan.needsFreshLauncher)                                       // a Steam that is plain
        #expect(settings.backend == .wined3d && settings.environment == ["WINEESYNC": "0", "WINEMSYNC": "0"])
        // The Steam that G-Player started for this very game runs with exactly these settings.
        #expect(try LaunchPlanner.plan(for: g, in: s, launcher: settings).needsFreshLauncher == false)
        // A Steam that is not known (started outside G-Player) is taken for a plain one.
        #expect(try LaunchPlanner.plan(for: g, in: s, launcher: nil).needsFreshLauncher)
        // One setting off is enough to start it again.
        #expect(try LaunchPlanner.plan(for: g, in: s, launcher: LauncherSettings(backend: .wined3d)).needsFreshLauncher)
        #expect(try LaunchPlanner.plan(for: g, in: s, launcher: LauncherSettings(backend: .dxvk, environment: settings.environment)).needsFreshLauncher)
    }

    @Test func aRecommendedGameFitsAPlainSteam() throws {
        let tmp = TempFolder()
        let s = steamSpace(tmp)
        let plan = try LaunchPlanner.plan(for: steamGame(s), in: s)
        #expect(plan.needsFreshLauncher == false)
        #expect(plan.launcherSettings == LauncherSettings(backend: .dxvk))
        let plain = LauncherSettings(backend: .dxvk, environment: [:])
        #expect(try LaunchPlanner.plan(for: steamGame(s), in: s, launcher: plain).needsFreshLauncher == false)
        // The game's own variables count, the preset's own do not.
        let own = try LaunchPlanner.plan(for: steamGame(s, environment: ["WINEDEBUG": "+all"]), in: s)
        #expect(own.launcherSettings?.environment == ["WINEDEBUG": "+all"])
        #expect(own.tweaks.environment["WINEDEBUG"] == "+all")
    }

    @Test func steamItselfCarriesItsOwnSettings() throws {
        let tmp = TempFolder()
        let s = steamSpace(tmp)
        let path = "drive_c/Program Files (x86)/Steam/steam.exe"
        var steam = Game(title: "Steam", kind: .app, spaceID: s.id, executablePath: path, environment: ["WINEDEBUG": "+all"])
        let withEnvironment = try LaunchPlanner.plan(for: steam, in: s)
        #expect(withEnvironment.launcherSettings == LauncherSettings(backend: .dxvk, environment: ["WINEDEBUG": "+all"]))
        // A game with the same variables needs nothing more from the Steam the user opened by hand.
        #expect(try LaunchPlanner.plan(for: steamGame(s, environment: ["WINEDEBUG": "+all"]), in: s,
                                       launcher: withEnvironment.launcherSettings).needsFreshLauncher == false)
        steam.environment = [:]
        #expect(try LaunchPlanner.plan(for: steam, in: s).launcherSettings == LauncherSettings(backend: .dxvk))
        // On G-Player Wine it runs with D3DMetal, which is what a plain Steam is there.
        var crossover = s
        crossover.engineID = EngineCatalog.crossover.id
        let ready: [GraphicsBackend] = [.dxvk, .d3dmetal, .dxmt, .wined3d]
        #expect(try LaunchPlanner.plan(for: steam, in: crossover, ready: ready).launcherSettings == LauncherSettings(backend: .d3dmetal))
        // Programs that aren't Steam start nothing.
        let exe = tmp.file("Steam/drive_c/Games/g.exe")
        let other = Game(title: "G", spaceID: s.id, executablePath: Game.storedPath(for: exe, in: s))
        #expect(try LaunchPlanner.plan(for: other, in: s).launcherSettings == nil)
    }

    @Test func onlySteamGamesAskForAFreshLauncher() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Main"))
        let exe = tmp.file("Main/drive_c/Games/g.exe")
        var g = Game(title: "G", spaceID: s.id, executablePath: Game.storedPath(for: exe, in: s))
        g.options = LaunchOptions(profile: .compatible, showFrameRate: true)
        #expect(try LaunchPlanner.plan(for: g, in: s).needsFreshLauncher == false)
    }

    // MARK: .NET

    @Test func dotNetIsAvailableWhenTheSpaceHasMonoOrTheRuntimeOrAComponent() throws {
        func plan(_ prepare: (TempFolder) -> Void) throws -> LaunchPlan {
            let tmp = TempFolder()
            let s = space(at: tmp.prefix("Main"))
            let exe = tmp.file("Main/drive_c/Games/g.exe")
            prepare(tmp)
            return try LaunchPlanner.plan(for: Game(title: "G", spaceID: s.id, executablePath: Game.storedPath(for: exe, in: s)), in: s)
        }
        let none = try plan { _ in }
        #expect(none.tweaks.dotNetAvailable == false)
        #expect(WineEnvironment.make(engine: fakeEngine(), space: space(at: URL(fileURLWithPath: "/tmp/M")), backend: .auto,
                                     tweaks: none.tweaks, base: [:])["WINEDLLOVERRIDES"]?.contains("mscoree") == true)

        let mono = try plan { $0.dir("Main/drive_c/windows/mono/mono-2.0") }
        #expect(mono.tweaks.dotNetAvailable)
        let runtime = try plan { $0.file("Main/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll") }
        #expect(runtime.tweaks.dotNetAvailable)
        let component = try plan { $0.file("Main/.gplayer-components.json", contents: Data(#"{"installed": {"dotnet48": "2026-01-01T00:00:00Z"}}"#.utf8)) }
        #expect(component.tweaks.dotNetAvailable)
        let other = try plan { $0.file("Main/.gplayer-components.json", contents: Data(#"{"installed": {"d3dx9": "2026-01-01T00:00:00Z"}}"#.utf8)) }
        #expect(other.tweaks.dotNetAvailable == false)
        // Only a space that failed to install .NET doesn't have it.
        let failed = try plan { $0.file("Main/.gplayer-components.json", contents: Data(#"{"failed": {"dotnet48": "2026-01-01T00:00:00Z"}}"#.utf8)) }
        #expect(failed.tweaks.dotNetAvailable == false)
        // The older framework folder without clr.dll isn't .NET 4.
        let empty = try plan { $0.dir("Main/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319") }
        #expect(empty.tweaks.dotNetAvailable == false)
    }

    @Test func steamAndEpicLaunchesKnowAboutDotNetToo() throws {
        let tmp = TempFolder()
        let s = steamSpace(tmp)
        tmp.dir("Steam/drive_c/windows/mono")
        #expect(try LaunchPlanner.plan(for: steamGame(s), in: s).tweaks.dotNetAvailable)
        let epic = space(at: tmp.prefix("Epic"), preset: "epic")
        tmp.file("Epic/drive_c/Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe")
        let game = Game(title: "F", spaceID: epic.id, source: .epic(appName: "x", launchURI: "u"))
        #expect(try LaunchPlanner.plan(for: game, in: epic).tweaks.dotNetAvailable == false)
        tmp.dir("Epic/drive_c/windows/mono")
        #expect(try LaunchPlanner.plan(for: game, in: epic).tweaks.dotNetAvailable)
    }

    @Test func missingExecutableIsAClearError() {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Main"))
        let g = Game(title: "Ghost", spaceID: s.id, executablePath: "drive_c/Games/none.exe")
        #expect(throws: LaunchPlanner.PlanError.self) { try LaunchPlanner.plan(for: g, in: s) }
    }

    @Test func installersOpenThroughMsiexec() {
        #expect(WineLauncher.arguments(toOpen: URL(fileURLWithPath: "/d/a.msi")) == ["msiexec", "/i", "/d/a.msi"])
        #expect(WineLauncher.arguments(toOpen: URL(fileURLWithPath: "/d/a.exe"), extra: ["/S"]) == ["/d/a.exe", "/S"])
    }
}

@Suite struct EnvironmentFinderTests {
    @Test func findsPrefixesAndTheirScriptedGames() throws {
        let tmp = TempFolder()
        let home = tmp.url
        _ = tmp.prefix("Games/Celeste")
        let exe = tmp.file("Downloads/Celeste/Celeste.exe")
        tmp.file("Games/play-celeste.sh", contents: Data("""
        export WINEPREFIX="$HOME/Games/Celeste"
        GPTK="/Applications/Game Porting Toolkit.app/Contents/Resources/wine"
        GAME="\(exe.path)"
        exec arch -x86_64 /opt/homebrew/bin/wine64 "$GAME" "$@"
        """.utf8))
        _ = tmp.prefix("Games/Lumen")
        let lumen = tmp.file("Games/Lumen-game/Lumen/Game.exe")
        tmp.dir("Games/Lumen-game/Lumen/resources/app")
        tmp.file("Games/play-lumen.sh", contents: Data("""
        GAME="$HOME/Games/Lumen-game/Lumen/Game.exe"
        exec "$HOME/Games/wine-run.sh" Lumen "$GAME" --no-sandbox "$@"
        """.utf8))
        _ = tmp.prefix("Library/Application Support/CrossOver/Bottles/Steam")
        tmp.file("Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steam.exe")

        let found = EnvironmentFinder.find(home: home, gptkInstalled: true)
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
        #expect(byName["Steam"]?.presetID == "steam")
        #expect(byName["Steam"]?.suggestedEngineID == EngineCatalog.defaultForNewSpaces.id)     // a CrossOver bottle
        #expect(byName["Celeste"]?.games.first?.executable.path == exe.path)
        #expect(byName["Celeste"]?.suggestedEngineID == EngineCatalog.crossover.id)       // its script ran on Apple's toolkit: no engine now
        #expect(byName["Lumen"]?.games.first?.executable.path == lumen.path)
        #expect(byName["Lumen"]?.games.first?.title == "Lumen")
        #expect(byName["Lumen"]?.games.first?.arguments.contains("--in-process-gpu") == true)
    }

    @Test func bottlesGetGPlayerWineAndOtherPrefixesKeepTheirEngine() {
        let tmp = TempFolder()
        _ = tmp.prefix("Library/Application Support/CrossOver/Bottles/Bottle")
        _ = tmp.prefix("Library/Containers/com.isaacmarovitz.Whisky/Bottles/Old")
        _ = tmp.prefix("Games/Plain")
        _ = tmp.prefix("Games/Scripted")
        tmp.file("Games/play-scripted.sh", contents: Data("""
        export WINEPREFIX="$HOME/Games/Scripted"
        exec "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine64" "$@"
        """.utf8))
        let gplayerWine = EngineCatalog.crossover.id, staging = EngineCatalog.wineStaging.id
        for toolkit in [false, true] {
            let byName = Dictionary(uniqueKeysWithValues: EnvironmentFinder.find(home: tmp.url, gptkInstalled: toolkit).map { ($0.name, $0) })
            #expect(byName["Bottle"]?.suggestedEngineID == gplayerWine)
            #expect(byName["Old"]?.suggestedEngineID == gplayerWine)
            // A plain prefix may have been opened by Wine Staging 11.18: it isn't moved to an older Wine unasked. With Apple's
            // toolkit on this Mac it is taken as the toolkit's (wine 7.7, which is no engine any more): G-Player Wine is newer.
            #expect(byName["Plain"]?.suggestedEngineID == (toolkit ? gplayerWine : staging))
            #expect(byName["Scripted"]?.suggestedEngineID == staging)
        }
    }

    @Test func bottlesGetTheG_PlayerWineThatIsInstalledSoTheyWorkOffline() {
        let tmp = TempFolder()
        _ = tmp.prefix("Library/Application Support/CrossOver/Bottles/Bottle")
        _ = tmp.prefix("Library/Containers/com.isaacmarovitz.Whisky/Bottles/Old")
        let revision1 = EngineCatalog.crossoverRevision1, gplayerWine = EngineCatalog.crossover, staging = EngineCatalog.wineStaging
        func engines(_ installed: [EngineInfo]) -> [String] {
            EnvironmentFinder.find(home: tmp.url, gptkInstalled: false, installed: installed).map(\.suggestedEngineID)
        }
        // Only the earlier revision is there (with Wine Staging or not): the bottles get it, and the migration moves them later.
        #expect(engines([revision1, staging]) == [revision1.id, revision1.id])
        #expect(engines([revision1]) == [revision1.id, revision1.id])
        #expect(engines([gplayerWine, revision1]) == [gplayerWine.id, gplayerWine.id])
        // No G-Player Wine installed: the current one, which downloads; never Wine Staging.
        #expect(engines([]) == [gplayerWine.id, gplayerWine.id])
        #expect(engines([staging]) == [gplayerWine.id, gplayerWine.id])
    }

    @Test func aLauncherScriptsEngineWinsAlsoForSteamPrefixes() {
        let tmp = TempFolder()
        let steam = "drive_c/Program Files (x86)/Steam/steam.exe"
        for name in ["Plain", "ByScript", "ByToolkitScript"] {
            _ = tmp.prefix("Games/\(name)")
            tmp.file("Games/\(name)/\(steam)")
        }
        tmp.file("Games/play-byscript.sh", contents: Data("""
        export WINEPREFIX="$HOME/Games/ByScript"
        exec "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine64" "$@"
        """.utf8))
        tmp.file("Games/play-bytoolkit.sh", contents: Data("""
        export WINEPREFIX="$HOME/Games/ByToolkitScript"
        GPTK="/Applications/Game Porting Toolkit.app/Contents/Resources/wine"
        """.utf8))
        let byName = Dictionary(uniqueKeysWithValues: EnvironmentFinder.find(home: tmp.url, gptkInstalled: true).map { ($0.name, $0) })
        // Steam doesn't start on Apple's wine 7.7, so a script naming it doesn't decide for a Steam prefix.
        for name in ["Plain", "ByScript", "ByToolkitScript"] {
            #expect(byName[name]?.presetID == "steam")
            #expect(byName[name]?.suggestedEngineID == EngineCatalog.wineStaging.id)
        }
    }

    @Test func skipsTheLibraryItself() {
        let tmp = TempFolder()
        _ = tmp.prefix("Games/G-Player/Spaces/Main")
        let found = EnvironmentFinder.find(home: tmp.url, excluding: [tmp.url.appendingPathComponent("Games/G-Player")],
                                           gptkInstalled: false)
        #expect(found.isEmpty)
    }
}

@Suite struct LibraryStoreTests {
    @Test func roundTrips() throws {
        let tmp = TempFolder()
        let store = LibraryStore(paths: LibraryPaths(root: tmp.url))
        var state = LibraryState()
        let s = Space(name: "Main", path: "/x", engineID: "e", origin: .managed)
        state.spaces = [s]
        state.games = [Game(title: "A", spaceID: s.id, source: .steam(appID: "1"))]
        state.hiddenStoreKeys = ["steam:2"]
        try store.save(state)
        let loaded = try store.load()
        #expect(loaded.spaces.map(\.id) == state.spaces.map(\.id))
        #expect(loaded.games.first?.source == .steam(appID: "1"))
        #expect(loaded.hiddenStoreKeys == ["steam:2"])
        #expect(abs(loaded.games[0].addedAt.timeIntervalSince(state.games[0].addedAt)) < 0.001)
    }
}

@Suite struct PresetTests {
    @Test func epicIsFoundInEitherProgramFiles() {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Epic"), preset: "epic")
        #expect(!AppPresets.epic.isInstalled(in: s))
        tmp.file("Epic/drive_c/Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe")
        #expect(AppPresets.epic.isInstalled(in: s))
        #expect(AppPresets.epic.executableURL(in: s).path.contains("/Program Files/Epic Games/"))
    }

    @Test func epicGamesLaunchThroughTheLauncherURI() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Epic"), preset: "epic")
        tmp.file("Epic/drive_c/Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe")
        let g = Game(title: "Fall Guys", spaceID: s.id, source: .epic(appName: "0a2d9f", launchURI: "com.epicgames.launcher://apps/x?action=launch"))
        let plan = try LaunchPlanner.plan(for: g, in: s)
        #expect(plan.arguments.last == "com.epicgames.launcher://apps/x?action=launch")
        #expect(plan.chromiumHelpers.count == 2)
    }
}


// MARK: Busy spaces

/// Whether a launch writes into its space decides when an external space needs the user's consent.
@Suite struct WritesToSpaceTests {
    private func plan(_ backend: GraphicsBackend, components: [String] = [], registry: [RegistryValue] = [],
                      helpers: [String] = []) -> LaunchPlan {
        LaunchPlan(arguments: [], workingDirectory: nil, backend: backend, tweaks: LaunchTweaks(),
                   chromiumHelpers: helpers, components: components, registry: registry)
    }

    @Test func plainWineD3DAndD3DMetalLeaveTheSpaceAlone() {
        #expect(!plan(.wined3d).writesToSpace(engine: EngineCatalog.wineStaging))
        #expect(!plan(.auto).writesToSpace(engine: EngineCatalog.gptk))
    }

    @Test func dxvkCopiesItsFiles() {
        #expect(plan(.auto).writesToSpace(engine: EngineCatalog.wineStaging))        // DXVK is the Staging default
        #expect(plan(.dxvk).writesToSpace(engine: EngineCatalog.wineStaging))
    }

    @Test func componentsSettingsAndTheSteamWrapperWrite() {
        let staging = EngineCatalog.wineStaging
        #expect(plan(.wined3d, components: ["vcrun2022"]).writesToSpace(engine: staging))
        #expect(plan(.wined3d, registry: [RegistryValue(key: #"HKCU\Software\Wine"#, name: "n", value: "v")]).writesToSpace(engine: staging))
        #expect(plan(.wined3d, helpers: ["Program Files (x86)/Steam/bin/cef/*/steamwebhelper.exe"]).writesToSpace(engine: staging))
    }
}
