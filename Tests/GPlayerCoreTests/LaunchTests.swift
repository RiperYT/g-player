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
