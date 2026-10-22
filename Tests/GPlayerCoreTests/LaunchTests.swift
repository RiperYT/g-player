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

    @Test func environmentProfilesAndBackendsNeedAFreshSteam() throws {
        let tmp = TempFolder()
        let s = steamSpace(tmp)
        for profile in [LaunchProfile.compatible, .custom] {
            let plan = try LaunchPlanner.plan(for: steamGame(s, LaunchOptions(profile: profile)), in: s)
            #expect(plan.needsFreshLauncher, "\(profile)")
        }
        // The profile's own environment.
        let compatible = try LaunchPlanner.plan(for: steamGame(s, LaunchOptions(profile: .compatible)), in: s)
        #expect(compatible.backend == .wined3d && compatible.compat?.environment["WINEESYNC"] == "0")
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
        #expect(try LaunchPlanner.plan(for: steamGame(s, LaunchOptions(profile: .fast)), in: s).needsFreshLauncher == true)   // a profile other than Recommended
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
        #expect(byName["Steam"]?.suggestedEngineID == EngineCatalog.wineStaging.id)
        #expect(byName["Celeste"]?.games.first?.executable.path == exe.path)
        #expect(byName["Celeste"]?.suggestedEngineID == EngineCatalog.gptk.id)
        #expect(byName["Lumen"]?.games.first?.executable.path == lumen.path)
        #expect(byName["Lumen"]?.games.first?.title == "Lumen")
        #expect(byName["Lumen"]?.games.first?.arguments.contains("--in-process-gpu") == true)
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

@Suite struct WineProcessesTests {
    let main = Space(name: "Main", path: "/Users/me/Games/G-Player/Spaces/Main", engineID: "x", origin: .managed)
    let second = Space(name: "Main 2", path: "/Users/me/Games/G-Player/Spaces/Main 2", engineID: "x", origin: .managed)

    private let idle = """
    /sbin/launchd
    /usr/libexec/logd
    /Applications/G-Player.app/Contents/MacOS/GPlayer
    /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
    /bin/ps -axo command=
    """

    @Test func anIdleMacMeansAFreeSpace() {
        #expect(!WineProcesses.isRunning(in: main, commandLines: idle))
        #expect(!WineProcesses.isRunning(in: main, commandLines: ""))
        #expect(!WineProcesses.isSteamRunning(in: main, commandLines: idle))
    }

    @Test func aProgramFromTheSpacesDriveMakesItBusy() {
        let ps = idle + "\n/Users/me/Games/G-Player/Engines/wine/bin/wine64-preloader /Users/me/Games/G-Player/Spaces/Main/drive_c/Games/Game.exe -windowed\n"
        #expect(WineProcesses.isRunning(in: main, commandLines: ps))
        #expect(!WineProcesses.isRunning(in: second, commandLines: ps))                     // "Main" is not "Main 2"
        #expect(!WineProcesses.isSteamRunning(in: main, commandLines: ps))
    }

    @Test func theWineprefixVariableCountsToo() {
        let ps = idle + "\nenv WINEPREFIX=/Users/me/Games/G-Player/Spaces/Main wine winecfg\nsh -c WINEPREFIX=/Users/me/Games/G-Player/Spaces/Main 2 wine x\n"
        #expect(WineProcesses.isRunning(in: main, commandLines: ps))
        #expect(WineProcesses.isRunning(in: second, commandLines: ps))
        let only = idle + "\nwinetricks WINEPREFIX=/Users/me/Games/G-Player/Spaces/Main2 vcrun2008"
        #expect(!WineProcesses.isRunning(in: main, commandLines: only))                    // needs the space after the path
    }

    @Test func steamIsToldFromOtherPrograms() {
        let steam = "/Users/me/Games/G-Player/Spaces/Main/drive_c/Program Files (x86)/Steam/steam.exe -silent -applaunch 1"
        #expect(WineProcesses.isSteamRunning(in: main, commandLines: idle + "\n" + steam))
        #expect(WineProcesses.isRunning(in: main, commandLines: idle + "\n" + steam))
        #expect(!WineProcesses.isSteamRunning(in: second, commandLines: idle + "\n" + steam))
        let helper = "/Users/me/Games/G-Player/Spaces/Main/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64/STEAMWEBHELPER.EXE --type=gpu"
        #expect(WineProcesses.isSteamRunning(in: main, commandLines: helper))
        // A game that Steam started is a busy space, but not a running Steam.
        let game = "/Users/me/Games/G-Player/Spaces/Main/drive_c/Program Files (x86)/Steam/steamapps/common/Game/Game.exe"
        #expect(WineProcesses.isRunning(in: main, commandLines: game))
        #expect(!WineProcesses.isSteamRunning(in: main, commandLines: game))
        // Steam in another space doesn't make this one busy.
        let elsewhere = "/Users/me/Games/Other/drive_c/Program Files (x86)/Steam/steam.exe"
        #expect(!WineProcesses.isRunning(in: main, commandLines: elsewhere))
        #expect(!WineProcesses.isSteamRunning(in: main, commandLines: elsewhere))
    }

    @Test func theRealProcessListHasNothingForASpaceThatDoesNotExist() {
        let list = WineProcesses.commandLines()
        #expect(!list.isEmpty)
        #expect(list.contains("ps"))
        let ghost = Space(name: "Ghost", path: "/nonexistent/gplayer-ghost-\(UUID().uuidString)", engineID: "x", origin: .managed)
        #expect(!WineProcesses.isRunning(in: ghost, commandLines: list))
    }
}

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

/// Telling which space a Windows program belongs to when its command line is a plain Windows path.
@Suite struct WineProcessSnapshotTests {
    let steamSpace = Space(name: "Steam", path: "/Users/me/Bottles/Steam", engineID: "x", origin: .external)
    let other = Space(name: "Steam 2", path: "/Users/me/Bottles/Steam 2", engineID: "x", origin: .external)

    private let ps = """
          1 /sbin/launchd
        201 /Users/me/Engines/wine/bin/wineserver
        213 C:\\windows\\system32\\services.exe
        240 C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\steamwebhelper_real.exe --type=renderer
        300 C:\\Program Files (x86)\\Steam\\steamapps\\common\\Cossacks 3\\cossacks.exe
        414 /Users/me/Bottles/Steam/drive_c/Program Files (x86)/Steam/steam.exe -silent -applaunch 1
        500 /Applications/Safari.app/Contents/MacOS/Safari
        """
    private let lsof = """
        p213
        fcwd
        n/Users/me/Bottles/Steam/drive_c/windows/system32
        p240
        fcwd
        n/Users/me/Bottles/Steam/drive_c/Program Files (x86)/Steam
        p300
        fcwd
        n/Users/me/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/Cossacks 3
        p414
        fcwd
        n/Users/me/Bottles/Steam/drive_c/Program Files (x86)/Steam
        """

    private var processes: [WineProcess] {
        let folders = WineProcesses.workingFolders(inLsof: lsof)
        return WineProcesses.windowsPrograms(inProcessList: ps).map { var p = $0; p.directory = folders[p.pid]; return p }
    }

    @Test func onlyWindowsProgramsAreKept() {
        #expect(processes.map(\.pid) == [213, 240, 300, 414])
    }

    @Test func aGameSteamStartedBelongsToSteamsSpace() {
        let names = WineProcesses.programs(in: steamSpace, from: processes).compactMap(\.programName)
        #expect(names == ["services.exe", "steamwebhelper_real.exe", "cossacks.exe", "steam.exe"])
        #expect(WineProcesses.programs(in: other, from: processes).isEmpty)              // "Steam" is not "Steam 2"
        #expect(WineProcesses.isRunning(in: steamSpace, processes: processes))
        #expect(WineProcesses.isSteamRunning(in: steamSpace, processes: processes))
        #expect(!WineProcesses.isSteamRunning(in: other, processes: processes))
    }

    @Test func wineServicesAloneDontMakeASpaceBusy() {
        let services = processes.filter { $0.pid == 213 }
        #expect(services.first?.isWineService == true)
        #expect(!WineProcesses.isRunning(in: steamSpace, processes: services))
    }

    @Test func theProgramNameIsTheExeWithoutItsFolder() {
        #expect(WineProcess(pid: 1, command: #"C:\Games\My Game\Game.EXE -windowed"#).programName == "game.exe")
        #expect(WineProcess(pid: 1, command: "/x/drive_c/Steam/steam.exe -silent").programName == "steam.exe")
        #expect(WineProcess(pid: 1, command: "/usr/bin/true").programName == nil)
    }

    @Test func theRealSnapshotRuns() {
        // Whatever runs on this Mac: the call must come back and only list programs it could read.
        let all = WineProcesses.snapshot()
        #expect(all.allSatisfy { $0.pid > 0 && !$0.command.isEmpty })
    }
}
