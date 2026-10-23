import Foundation
import Testing
@testable import GPlayerCore

/// Epic's own launcher. On G-Player Wine it runs with the web helper Epic made and the engine's own Direct3D (its network
/// service crashes in a loop behind G-Player's wrapper, and its renderer can't make a swap chain on DXVK); on Wine Staging
/// nothing changes. Which engine decides is a function of the preset and the engine's kind.
@Suite struct EpicLauncherTests {
    let staging = EngineCatalog.wineStaging
    let gplayerWine = EngineCatalog.crossover
    let epic = AppPresets.epic
    let kinds: [EngineInfo.Kind] = [.wineStaging, .crossover, .gptk]
    let launcherPath = "Epic/drive_c/Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"

    private func epicSpace(_ tmp: TempFolder, on engine: EngineInfo, origin: Space.Origin = .managed) -> Space {
        var s = space(at: tmp.prefix("Epic"), preset: "epic")
        s.engineID = engine.id
        s.origin = origin
        tmp.file(launcherPath)
        return s
    }

    private func launcher(in s: Space, graphics: GraphicsBackend = .auto) -> Game {
        Game(title: "Epic Games Launcher", kind: .app, spaceID: s.id,
             executablePath: "drive_c/Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
             graphics: graphics)
    }

    // MARK: Which helpers, which graphics

    @Test func epicWrapsItsWebHelperOnWineStagingAndNotOnGPlayerWine() {
        let all = epic.chromiumHelpers
        #expect(all.count == 2 && all.allSatisfy { $0.hasSuffix("EpicWebHelper.exe") })
        // Wine Staging (and Apple's toolkit) keep today's behaviour.
        for kind in [EngineInfo.Kind.wineStaging, .gptk] {
            #expect(epic.helpersToWrap(on: kind) == all)
            #expect(epic.helpersToUnwrap(on: kind).isEmpty)
        }
        #expect(epic.helpersToWrap(on: .crossover).isEmpty)
        #expect(epic.helpersToUnwrap(on: .crossover) == all)
    }

    @Test func theOtherLaunchersAreSetUpTheSameOnEveryEngine() {
        for preset in AppPresets.all where preset.id != epic.id {
            for kind in kinds {
                #expect(preset.helpersToWrap(on: kind) == preset.chromiumHelpers)
                #expect(preset.helpersToUnwrap(on: kind).isEmpty)
                #expect(preset.launcherBackend(on: kind) == nil)
                #expect(!preset.needsGPlayerWine)
            }
        }
    }

    @Test func epicsLauncherIsPinnedToTheEnginesOwnDirect3DOnGPlayerWineOnly() {
        #expect(epic.launcherBackend(on: .crossover) == .wined3d)
        #expect(epic.launcherBackend(on: .wineStaging) == nil)
        #expect(epic.launcherBackend(on: .gptk) == nil)
    }

    // MARK: What a launch gets

    @Test func theLauncherOnGPlayerWineStartsOnWineD3DWhateverIsChosen() throws {
        let tmp = TempFolder()
        let s = epicSpace(tmp, on: gplayerWine)
        for chosen in [GraphicsBackend.auto, .dxvk, .d3dmetal, .dxmt] {
            let plan = try LaunchPlanner.plan(for: launcher(in: s, graphics: chosen), in: s)
            #expect(plan.backend == .wined3d)
        }
        let plan = try LaunchPlanner.plan(for: launcher(in: s), in: s)
        #expect(plan.arguments.contains("-SkipBuildPatchPrereq"))
        #expect(plan.chromiumHelpers.isEmpty && plan.unwrapHelpers == epic.chromiumHelpers)
        // The engine's builtin d3d11, d3d10core and dxgi: no override for them, nothing of DXVK's.
        let env = WineEnvironment.make(engine: fakeEngine(gplayerWine), space: s, backend: plan.backend, tweaks: plan.tweaks, base: [:])
        let overrides = env["WINEDLLOVERRIDES"] ?? ""
        #expect(!overrides.contains("d3d11") && !overrides.contains("d3d10core") && !overrides.contains("dxgi"))
        #expect(env["DXVK_ASYNC"] == nil)
    }

    @Test func theLauncherOnWineStagingStaysAsItWas() throws {
        let tmp = TempFolder()
        let s = epicSpace(tmp, on: staging)
        let plan = try LaunchPlanner.plan(for: launcher(in: s), in: s)
        #expect(plan.backend == .auto)                                  // the engine's own default, as before
        #expect(plan.chromiumHelpers == epic.chromiumHelpers && plan.unwrapHelpers.isEmpty)
        // A choice made by hand there still counts.
        #expect(try LaunchPlanner.plan(for: launcher(in: s, graphics: .wined3d), in: s).backend == .wined3d)
        #expect(try LaunchPlanner.plan(for: launcher(in: s, graphics: .dxvk), in: s).backend == .dxvk)
    }

    @Test func gamesStartedThroughTheLauncherKeepTheirOwnGraphics() throws {
        let tmp = TempFolder()
        let s = epicSpace(tmp, on: gplayerWine)
        // Epic's launcher hands the game to its own process, which inherits the launcher's environment: what G-Player
        // decides for the game itself (its backend here) is not replaced by the launcher's pin.
        var game = Game(title: "G", spaceID: s.id, source: .epic(appName: "x", launchURI: "com.epicgames.launcher://apps/x?action=launch"),
                        graphics: .dxmt)
        game.options = LaunchOptions(profile: .custom)                 // graphics chosen by hand count only with Custom
        let plan = try LaunchPlanner.plan(for: game, in: s)
        #expect(plan.backend == .dxmt)
        #expect(plan.chromiumHelpers.isEmpty && plan.unwrapHelpers == epic.chromiumHelpers)   // the helper is Epic's own here too
        // And a program the user added to the space gets what it asked for, the pin being the launcher's alone.
        var mine = Game(title: "P", spaceID: s.id, executablePath: "drive_c/Games/p.exe", graphics: .dxvk)
        mine.options = LaunchOptions(profile: .custom)
        tmp.file("Epic/drive_c/Games/p.exe")
        #expect(try LaunchPlanner.plan(for: mine, in: s).backend == .dxvk)
    }

    @Test func steamIsPlannedExactlyAsBefore() throws {
        let tmp = TempFolder()
        var s = space(at: tmp.prefix("Steam"), preset: "steam")
        s.engineID = gplayerWine.id
        tmp.file("Steam/drive_c/Program Files (x86)/Steam/steam.exe")
        let steamLauncher = Game(title: "Steam", kind: .app, spaceID: s.id,
                                 executablePath: "drive_c/Program Files (x86)/Steam/steam.exe")
        let plan = try LaunchPlanner.plan(for: steamLauncher, in: s)
        #expect(plan.chromiumHelpers == AppPresets.steam.chromiumHelpers && plan.unwrapHelpers.isEmpty)
        #expect(plan.backend == .d3dmetal)                              // what a store launcher gets on G-Player Wine
        let game = Game(title: "S", spaceID: s.id, source: .steam(appID: "1"))
        let steamGame = try LaunchPlanner.plan(for: game, in: s)
        #expect(steamGame.chromiumHelpers == AppPresets.steam.chromiumHelpers && steamGame.unwrapHelpers.isEmpty)
    }

    @Test func aLauncherOnGPlayerWineAsksForNoConsentToStart() throws {
        let tmp = TempFolder()
        var s = epicSpace(tmp, on: gplayerWine)
        #expect(!(try LaunchPlanner.plan(for: launcher(in: s), in: s)).writesToSpace(engine: gplayerWine))
        s.engineID = staging.id
        #expect(try LaunchPlanner.plan(for: launcher(in: s), in: s).writesToSpace(engine: staging))      // the wrapper, as before
    }

    // MARK: Taking the wrapper out

    let wrapper = Data("MZ wrapper macade-chromium-wrapper/2 end".utf8)
    let vendor = Data(repeating: 7, count: 2000)

    private func helperFolder(_ s: Space) -> URL {
        s.driveC.appendingPathComponent("Program Files/Epic Games/Launcher/Engine/Binaries/Win64")
    }

    private func wrapped(_ tmp: TempFolder, on engine: EngineInfo, origin: Space.Origin = .managed) throws -> Space {
        var s = epicSpace(tmp, on: staging, origin: origin)
        tmp.file("Epic/drive_c/Program Files/Epic Games/Launcher/Engine/Binaries/Win64/EpicWebHelper.exe", contents: vendor)
        // Wrapped the way the app did it on Wine Staging, then moved.
        try ChromiumHelperWrapper.apply(helpers: epic.helpersToWrap(on: .wineStaging), in: s, wrapper: wrapper)
        s.engineID = engine.id
        return s
    }

    @Test func unwrappingPutsEpicsOwnHelperBackAndKeepsTheCopy() throws {
        let tmp = TempFolder()
        let s = try wrapped(tmp, on: gplayerWine)
        let helper = helperFolder(s).appendingPathComponent("EpicWebHelper.exe")
        let real = helperFolder(s).appendingPathComponent("EpicWebHelper_real.exe")
        #expect(FileManager.default.contents(atPath: helper.path) == wrapper)
        let changed = try ChromiumHelperWrapper.unwrap(helpers: epic.helpersToUnwrap(on: .crossover), in: s, wrapper: wrapper)
        #expect(changed.map(\.lastPathComponent) == ["EpicWebHelper.exe"])
        #expect(FileManager.default.contents(atPath: helper.path) == vendor)
        #expect(FileManager.default.contents(atPath: real.path) == vendor)              // nothing is deleted
        // Done once: the second time finds Epic's own helper and leaves it.
        #expect(try ChromiumHelperWrapper.unwrap(helpers: epic.chromiumHelpers, in: s, wrapper: wrapper).isEmpty)
    }

    @Test func aMoveToGPlayerWineUnwrapsBeforeTheNextStartAndNothingWrapsItAgain() throws {
        let tmp = TempFolder()
        var s = epicSpace(tmp, on: staging)
        tmp.file("Epic/drive_c/Program Files/Epic Games/Launcher/Engine/Binaries/Win64/EpicWebHelper.exe", contents: vendor)
        let helper = helperFolder(s).appendingPathComponent("EpicWebHelper.exe")
        // A start on Wine Staging wraps it, as the plan says.
        var plan = try LaunchPlanner.plan(for: launcher(in: s), in: s)
        try ChromiumHelperWrapper.apply(helpers: plan.chromiumHelpers, in: s, wrapper: wrapper)
        #expect(FileManager.default.contents(atPath: helper.path) == wrapper)
        // The space moves; the next start's plan has nothing to wrap, and unwraps.
        s.engineID = gplayerWine.id
        plan = try LaunchPlanner.plan(for: launcher(in: s), in: s)
        #expect(plan.chromiumHelpers.isEmpty)
        try ChromiumHelperWrapper.apply(helpers: plan.chromiumHelpers, in: s, wrapper: wrapper)       // what the start does: nothing
        try ChromiumHelperWrapper.unwrap(helpers: plan.unwrapHelpers, in: s, wrapper: wrapper)
        #expect(FileManager.default.contents(atPath: helper.path) == vendor)
        // While the launcher runs, the app's guard asks for the helpers to wrap: none on this engine.
        #expect(epic.helpersToWrap(on: .crossover).isEmpty)
        // Moving back to Wine Staging wraps it again.
        s.engineID = staging.id
        let back = try LaunchPlanner.plan(for: launcher(in: s), in: s)
        try ChromiumHelperWrapper.apply(helpers: back.chromiumHelpers, in: s, wrapper: wrapper)
        #expect(FileManager.default.contents(atPath: helper.path) == wrapper)
    }

    @Test func onlyExactlyGPlayersWrapperIsTakenOut() throws {
        let tmp = TempFolder()
        let s = try wrapped(tmp, on: gplayerWine)
        let helper = helperFolder(s).appendingPathComponent("EpicWebHelper.exe")
        let real = helperFolder(s).appendingPathComponent("EpicWebHelper_real.exe")
        func unwrap() throws -> [URL] { try ChromiumHelperWrapper.unwrap(helpers: epic.chromiumHelpers, in: s, wrapper: wrapper) }
        // Another tool's wrapper (it carries the same marker) is left alone.
        let other = Data("MZ somebody else's macade-chromium-wrapper/2 build".utf8)
        try other.write(to: helper)
        #expect(try unwrap().isEmpty)
        #expect(FileManager.default.contents(atPath: helper.path) == other)
        // So is a helper the launcher updated itself, with its newer copy.
        let updated = Data(repeating: 9, count: 3000)
        try updated.write(to: helper)
        #expect(try unwrap().isEmpty)
        #expect(FileManager.default.contents(atPath: helper.path) == updated)
        #expect(FileManager.default.contents(atPath: real.path) == vendor)
    }

    @Test func theWrapperStaysWhenThereIsNoVendorHelperToPutBack() throws {
        let tmp = TempFolder()
        let s = try wrapped(tmp, on: gplayerWine)
        let helper = helperFolder(s).appendingPathComponent("EpicWebHelper.exe")
        let real = helperFolder(s).appendingPathComponent("EpicWebHelper_real.exe")
        // The vendor copy is gone: the wrapper would be replaced by nothing, so it stays.
        let saved = try Data(contentsOf: real)
        try FileManager.default.removeItem(at: real)
        #expect(try ChromiumHelperWrapper.unwrap(helpers: epic.chromiumHelpers, in: s, wrapper: wrapper).isEmpty)
        #expect(FileManager.default.contents(atPath: helper.path) == wrapper)
        // The same for an empty copy, and for a "vendor" copy that is a wrapper itself.
        try Data().write(to: real)
        #expect(try ChromiumHelperWrapper.unwrap(helpers: epic.chromiumHelpers, in: s, wrapper: wrapper).isEmpty)
        try wrapper.write(to: real)
        #expect(try ChromiumHelperWrapper.unwrap(helpers: epic.chromiumHelpers, in: s, wrapper: wrapper).isEmpty)
        #expect(FileManager.default.contents(atPath: helper.path) == wrapper)
        try saved.write(to: real)
        #expect(try ChromiumHelperWrapper.unwrap(helpers: epic.chromiumHelpers, in: s, wrapper: wrapper).count == 1)
    }

    @Test func unwrappingTouchesNothingButTheHelpers() throws {
        let tmp = TempFolder()
        let s = try wrapped(tmp, on: gplayerWine)
        let neighbour = tmp.file("Epic/drive_c/Program Files/Epic Games/Launcher/Engine/Binaries/Win64/libcef.dll", contents: Data(repeating: 3, count: 500))
        let user = tmp.file("Epic/drive_c/users/me/Documents/save.dat", contents: Data(repeating: 4, count: 100))
        try ChromiumHelperWrapper.unwrap(helpers: epic.chromiumHelpers, in: s, wrapper: wrapper)
        #expect(FileManager.default.contents(atPath: neighbour.path) == Data(repeating: 3, count: 500))
        #expect(FileManager.default.contents(atPath: user.path) == Data(repeating: 4, count: 100))
        // A space with no Epic in it has nothing to look at.
        let empty = space(at: tmp.prefix("Empty"))
        #expect(try ChromiumHelperWrapper.unwrap(helpers: epic.chromiumHelpers, in: empty, wrapper: wrapper).isEmpty)
        // And a wrapper that isn't one is refused, as for wrapping.
        #expect(throws: (any Error).self) { try ChromiumHelperWrapper.unwrap(helpers: ["x.exe"], in: s, wrapper: Data("nope".utf8)) }
    }

    @Test func aSpaceOfAnotherAppIsOnlyChangedWithItsOwnersYes() throws {
        let tmp = TempFolder()
        var s = try wrapped(tmp, on: gplayerWine, origin: .external)
        let helper = helperFolder(s).appendingPathComponent("EpicWebHelper.exe")
        #expect(!s.mayChange)
        #expect(try ChromiumHelperWrapper.unwrap(helpers: epic.chromiumHelpers, in: s, wrapper: wrapper).isEmpty)
        s.allowsChanges = false
        #expect(try ChromiumHelperWrapper.unwrap(helpers: epic.chromiumHelpers, in: s, wrapper: wrapper).isEmpty)
        #expect(FileManager.default.contents(atPath: helper.path) == wrapper)
        s.allowsChanges = true
        #expect(try ChromiumHelperWrapper.unwrap(helpers: epic.chromiumHelpers, in: s, wrapper: wrapper).count == 1)
        #expect(FileManager.default.contents(atPath: helper.path) == vendor)
    }

    // MARK: Its space

    @Test func aNewLauncherSpaceIsMadeOnGPlayerWineEvenWhenOnlyWineStagingIsInstalled() {
        let revision1 = EngineCatalog.crossoverRevision1
        #expect(epic.needsGPlayerWine)
        #expect(epic.engineForNewSpace(installed: [staging]).id == gplayerWine.id)              // downloads
        #expect(epic.engineForNewSpace(installed: []).id == gplayerWine.id)
        #expect(epic.engineForNewSpace(installed: [staging, gplayerWine]).id == gplayerWine.id)
        #expect(epic.engineForNewSpace(installed: [revision1, staging]).id == revision1.id)     // works offline, moves later
        // The other launchers follow what any new space gets.
        for preset in AppPresets.all where preset.id != epic.id {
            #expect(preset.engineForNewSpace(installed: [staging]).id == staging.id)
            #expect(preset.engineForNewSpace(installed: [staging, gplayerWine]).id == gplayerWine.id)
        }
    }

    @Test func anEpicSpaceOnAnotherEngineIsOfferedTheMoveWhetherOrNotTheMenusAreOn() {
        func needs(_ preset: String?, _ engine: EngineInfo) -> Bool { EngineSwitch.launcherNeedsMove(presetID: preset, engineID: engine.id) }
        #expect(needs("epic", staging) && needs("epic", EngineCatalog.gptk))
        #expect(!needs("epic", gplayerWine) && !needs("epic", EngineCatalog.crossoverRevision1))
        #expect(!needs("steam", staging) && !needs(nil, staging) && !needs(EpicGames.presetID, staging))
        // The page's own offer for Wine Staging is the move, so the Epic note shows in the same place.
        #expect(EngineSwitch.pageOffer(engineID: staging.id, choosingEngines: false) == .move)
        #expect(EngineSwitch.launcherMoveDetail(presetID: "epic") == "Epic Games Launcher opens only on G-Player Wine. Moving asks first.")
        #expect(EngineSwitch.launcherMoveDetail(presetID: "steam") == nil && EngineSwitch.launcherMoveDetail(presetID: nil) == nil)
    }
}
