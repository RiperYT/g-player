import Foundation
import Testing
@testable import GPlayerCore

/// Epic's own launcher. On G-Player Wine it runs with the web helper Epic made (its network service crashes in a loop behind
/// G-Player's wrapper) and on D3DMetal, or DXMT without it (on DXVK its renderer can't make a swap chain, on WineD3D it
/// crashes); on Wine Staging nothing changes. Both decisions are functions of the preset and the engine's kind.
@Suite struct EpicLauncherTests {
    let staging = EngineCatalog.wineStaging
    let gplayerWine = EngineCatalog.crossover
    let epic = AppPresets.epic
    let kinds: [EngineInfo.Kind] = [.wineStaging, .crossover, .gptk]
    let withMetal: [GraphicsBackend] = [.dxvk, .d3dmetal, .dxmt, .wined3d]
    let withoutMetal: [GraphicsBackend] = [.dxvk, .dxmt, .wined3d]
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
                #expect(preset.launcherBackend(on: kind, ready: withMetal) == nil)
                #expect(!preset.needsGPlayerWine)
            }
        }
    }

    @Test func epicsLauncherIsPinnedToD3DMetalOrDXMTOnGPlayerWineAndNeverToWineD3D() {
        // D3DMetal when the engine has it ready (it runs DirectX 12 games the launcher starts too), DXMT otherwise.
        #expect(epic.launcherBackend(on: .crossover, ready: withMetal) == .d3dmetal)
        #expect(epic.launcherBackend(on: .crossover, ready: withoutMetal) == .dxmt)
        // Whatever is ready, in every combination: never WineD3D or DXVK, which don't open the 2026 launcher. Without either of
        // the two the last choice stands, and the engine runs what it has.
        for mask in 0..<16 {
            let ready = withMetal.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            #expect(epic.launcherBackend(on: .crossover, ready: ready) == (ready.contains(.d3dmetal) ? .d3dmetal : .dxmt))
        }
        // G-Player Wine only.
        for kind in [EngineInfo.Kind.wineStaging, .gptk] {
            #expect(epic.launcherBackend(on: kind, ready: withMetal) == nil)
        }
    }

    // MARK: What a launch gets

    private func plan(_ s: Space, graphics: GraphicsBackend = .auto, ready: [GraphicsBackend]? = nil) throws -> LaunchPlan {
        try LaunchPlanner.plan(for: launcher(in: s, graphics: graphics), in: s, ready: ready)
    }

    @Test func theLauncherOnGPlayerWineStartsOnD3DMetalOrDXMTWhateverIsChosen() throws {
        let tmp = TempFolder()
        let s = epicSpace(tmp, on: gplayerWine)
        for chosen in [GraphicsBackend.auto, .dxvk, .wined3d, .d3dmetal, .dxmt] {
            #expect(try plan(s, graphics: chosen, ready: withMetal).backend == .d3dmetal)
            #expect(try plan(s, graphics: chosen, ready: withoutMetal).backend == .dxmt)
            #expect(try plan(s, graphics: chosen).backend == .d3dmetal)              // nothing known of the engine yet: the first choice
        }
        let launch = try plan(s)
        #expect(launch.arguments.contains("-SkipBuildPatchPrereq"))
        #expect(launch.chromiumHelpers.isEmpty && launch.unwrapHelpers == epic.chromiumHelpers)
    }

    @Test func withoutD3DMetalTheLauncherGetsDXMTsDLLsAndNotDXVKs() throws {
        let tmp = TempFolder()
        let s = epicSpace(tmp, on: gplayerWine)
        let launch = try plan(s, ready: withoutMetal)
        let root = URL(fileURLWithPath: "/tmp/engine/wine")
        let engine = Engine(info: gplayerWine.limited(to: withoutMetal), wineRoot: root, wine: root.appendingPathComponent("bin/wine"),
                            dxvk: URL(fileURLWithPath: "/tmp/engine/dxvk"), dxmt: URL(fileURLWithPath: "/tmp/engine/dxmt"))
        let env = WineEnvironment.make(engine: engine, space: s, backend: launch.backend, tweaks: launch.tweaks, base: [:])
        #expect(env["WINEDLLOVERRIDES"]?.contains(";dxgi,d3d11,d3d10core=n,b") == true)    // its DLLs go into the space as native ones
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
                        graphics: .dxvk)
        game.options = LaunchOptions(profile: .custom)                 // graphics chosen by hand count only with Custom
        let started = try LaunchPlanner.plan(for: game, in: s, ready: withMetal)
        #expect(started.backend == .dxvk)
        #expect(started.chromiumHelpers.isEmpty && started.unwrapHelpers == epic.chromiumHelpers)   // the helper is Epic's own here too
        // And a program the user added to the space gets what it asked for, the pin being the launcher's alone.
        var mine = Game(title: "P", spaceID: s.id, executablePath: "drive_c/Games/p.exe", graphics: .dxvk)
        mine.options = LaunchOptions(profile: .custom)
        tmp.file("Epic/drive_c/Games/p.exe")
        #expect(try LaunchPlanner.plan(for: mine, in: s, ready: withMetal).backend == .dxvk)
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

    @Test func aLauncherOnGPlayerWineAsksForConsentOnlyForDXMTsFiles() throws {
        let tmp = TempFolder()
        var s = epicSpace(tmp, on: gplayerWine)
        // D3DMetal and the unwrap write nothing the owner of another app's bottle has to allow; DXMT's DLLs and the wrapper do.
        #expect(!(try plan(s, ready: withMetal)).writesToSpace(engine: gplayerWine.limited(to: withMetal)))
        #expect(try plan(s, ready: withoutMetal).writesToSpace(engine: gplayerWine.limited(to: withoutMetal)))
        s.engineID = staging.id
        #expect(try plan(s).writesToSpace(engine: staging))                         // the wrapper, as before
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

    // MARK: Words

    @Test func theLauncherIsTheRecommendedWayAndSaysItRunsOnGPlayerWine() {
        #expect(epic.summary == "Epic's own launcher. Runs on G-Player Wine; sign in with your Epic account.")
        #expect(!epic.experimental)                                                // one badge: Recommended
        #expect(!epic.summary.contains("loading screen"))
        #expect(EpicWay.allCases == [.launcher, .legendary])
        #expect(EpicWay.launcher.title == "Epic Games Launcher" && EpicWay.launcher.badge == "Recommended")
        #expect(EpicWay.launcher.detail == epic.summary)
        #expect(EpicWay.legendary.title == "Without the launcher" && EpicWay.legendary.badge == "Alternative")
        #expect(EpicWay.legendary.detail.hasPrefix("Faster, through Legendary, an open-source Epic client not made by Epic"))
    }
}
