import Foundation
import Testing
@testable import GPlayerCore

/// "Share What Worked": what the report says about a game, and what it must never say.
@Suite struct WorkedReportTests {
    let machine = WorkedReport.Machine(appVersion: "0.4.3", macOSVersion: "15.4", chip: "Apple M2 Pro")
    let redaction = WorkedReport.Redaction(homeFolder: "/Users/jane", names: ["jane", "Jane Doe"])
    let crossover = EngineCatalog.crossover.limited(to: [.dxvk, .dxmt, .wined3d])

    func report(_ game: Game, engine: EngineInfo? = nil, planned: GraphicsBackend = .dxvk, components: [String] = [],
                machine: WorkedReport.Machine? = nil, steamID: Bool = false) -> WorkedReport {
        WorkedReport(game: game, engine: engine ?? crossover, planned: planned, components: components,
                     machine: machine ?? self.machine, redaction: redaction, includesSteamAppID: steamID)
    }

    /// An added program with nothing set by hand.
    func plain() -> Game { Game(title: "Sample Game", spaceID: UUID(), executablePath: "drive_c/Games/Sample/Sample.exe") }

    // MARK: What it says

    @Test func aTypicalGameReportsTheMacTheEngineTheGraphicsTheSettingsAndWhatTheGameIs() {
        var game = Game(title: "Sample Game", spaceID: UUID(), source: .steam(appID: "424242"), arguments: ["-windowed", "-dx11"],
                        environment: ["DXVK_HUD": "fps", "WINEESYNC": "0"])
        game.options = LaunchOptions(windowMode: .windowed, retina: true)
        game.analysis = GameAnalysis(engineName: "Unity", engine: .unity, graphics: [.d3d11], architecture: .x64)
        game.autoGraphics = AutoGraphics(engineID: crossover.id, worked: .dxmt)
        let text = report(game, components: ["xact", "d3dx9"]).text
        #expect(text == """
            G-Player: 0.4.3
            macOS: 15.4
            Mac: Apple M2 Pro
            Engine: G-Player Wine (Wine 11 from CrossOver 26.3)
            Engine ID: wine-cx-26.3.0-2
            Graphics backend: DXMT
            Profile: Recommended
            Options: windowed, Retina
            Arguments: -windowed -dx11
            Environment: DXVK_HUD=fps, WINEESYNC=0
            Windows components: d3dx9, xact
            Game engine: Unity
            Game graphics: DirectX 11
            Game program: 64-bit
            Store: Steam
            """)
    }

    @Test func aGameWithNothingSetAndNothingKnownReportsOnlyWhatIsTrueOfEveryGame() {
        let text = report(plain(), machine: WorkedReport.Machine(appVersion: "0.4.3", macOSVersion: "15.4")).text
        #expect(text == """
            G-Player: 0.4.3
            macOS: 15.4
            Engine: G-Player Wine (Wine 11 from CrossOver 26.3)
            Engine ID: wine-cx-26.3.0-2
            Graphics backend: DXVK
            Profile: Recommended
            Store: Added .exe
            """)
    }

    @Test func theBackendThatWorkedIsNeverAutomaticAndAutomaticsRecordWinsOnItsOwnEngine() {
        var game = plain()
        // Nothing learned: what a launch uses now, resolved on the engine. A backend the engine can't run falls back.
        #expect(WorkedReport.workedBackend(of: game, on: crossover, planned: .auto) == .dxvk)
        #expect(WorkedReport.workedBackend(of: game, on: crossover, planned: .d3dmetal) == .dxvk)
        #expect(WorkedReport.workedBackend(of: game, on: crossover, planned: .dxmt) == .dxmt)
        // Learned on this engine: that one, over what the profile picks now.
        game.autoGraphics = AutoGraphics(engineID: crossover.id, worked: .wined3d)
        #expect(WorkedReport.workedBackend(of: game, on: crossover, planned: .dxvk) == .wined3d)
        // Learned on another engine: it doesn't count here.
        game.autoGraphics = AutoGraphics(engineID: EngineCatalog.wineStaging.id, worked: .wined3d)
        #expect(WorkedReport.workedBackend(of: game, on: crossover, planned: .dxmt) == .dxmt)
        // Compatible and Custom are the user's own pick: nothing is learned there, so a leftover record is ignored.
        game.autoGraphics = AutoGraphics(engineID: crossover.id, worked: .dxmt)
        game.options = LaunchOptions(profile: .compatible)
        #expect(WorkedReport.workedBackend(of: game, on: crossover, planned: .wined3d) == .wined3d)
        #expect(report(game, planned: .wined3d).lines.contains("Graphics backend: WineD3D"))
        #expect(report(game, planned: .wined3d).lines.contains("Profile: Compatible"))
    }

    @Test func aStoredFastProfileIsReportedAsRecommendedOnAnEngineWithoutD3DMetal() {
        var game = plain()
        game.options = LaunchOptions(profile: .fast)
        #expect(report(game).lines.contains("Profile: Recommended"))
        #expect(report(game, engine: EngineCatalog.crossover).lines.contains("Profile: Fast"))
    }

    @Test func theOptionsThatMatterAreListedAndTheOnesThatDontAreLeftOut() {
        var game = plain()
        game.options = LaunchOptions(windowMode: .fullscreen, showFrameRate: true)
        #expect(report(game).lines.contains("Options: fullscreen"))
        game.options = LaunchOptions(useKnownFixes: false)
        #expect(report(game).lines.contains("Options: known fixes off"))
        // Fix ids can hold a Steam app ID, so only how many are off is said.
        game.options = LaunchOptions(disabledFixIDs: ["steam-424242"])
        #expect(report(game).lines.contains("Options: 1 known fix off"))
        game.options = LaunchOptions(disabledFixIDs: ["steam-424242", "gplayer-sample"])
        #expect(report(game).lines.contains("Options: 2 known fixes off"))
        #expect(!report(game).text.contains("424242"))
        game.options = LaunchOptions(showFrameRate: true)
        #expect(!report(game).lines.contains { $0.hasPrefix("Options:") })
    }

    @Test func theAnalysisSaysTheEngineTheGraphicsAndTheProgramWhenKnown() {
        var game = plain()
        game.analysis = GameAnalysis(engineName: "Godot", engine: .godot, graphics: [.vulkan, .opengl], architecture: .x86, isDotNet: true)
        let lines = report(game).lines
        #expect(lines.contains("Game engine: Godot"))
        #expect(lines.contains("Game graphics: Vulkan"))
        #expect(lines.contains("Game program: 32-bit, .NET"))
        game.analysis = GameAnalysis()
        #expect(!report(game).lines.contains { $0.hasPrefix("Game ") })
    }

    @Test func aStoreGameSaysWhichStoreAndAnAddedProgramWhichLaunchersItBrought() {
        var epic = plain()
        epic.source = .epic(appName: "SampleCodeName", launchURI: "com.epicgames.launcher://apps/SampleCodeName?action=launch")
        #expect(report(epic).lines.contains("Store: Epic"))
        #expect(!report(epic).text.contains("SampleCodeName"))

        var added = plain()
        added.analysis = GameAnalysis(launchers: ["Ubisoft", "EA_App"])
        #expect(report(added).lines.contains("Store: Added .exe"))
        #expect(report(added).lines.contains("Launchers: Ubisoft, EA App"))
    }

    @Test func componentsAreListedOnceInOrderAndOnlyAsPlainIDs() {
        let lines = report(plain(), components: ["xact", "d3dx9", "xact", "/Users/jane/x", "not a name", ""]).lines
        #expect(lines.contains("Windows components: d3dx9, xact"))
        #expect(!report(plain()).lines.contains { $0.hasPrefix("Windows components") })
    }

    // MARK: The Steam app ID

    @Test func theSteamAppIDIsLeftOutUnlessTheUserTicksTheBox() {
        var game = plain()
        game.source = .steam(appID: "424242")
        #expect(!report(game).text.contains("424242"))
        #expect(report(game, steamID: true).lines.last == "Steam app ID: 424242")
        // Only a number counts as an app ID, and only a Steam game has one.
        game.source = .steam(appID: "42 and more")
        #expect(!report(game, steamID: true).text.contains("42 and more"))
        #expect(!report(plain(), steamID: true).lines.contains { $0.hasPrefix("Steam app ID") })
    }

    // MARK: The Mac

    @Test func theChipIsAPlainAppleNameAndNothingElse() {
        #expect(WorkedReport.Machine.chipFamily(from: "Apple M2 Pro") == "Apple M2 Pro")
        #expect(WorkedReport.Machine.chipFamily(from: " Apple M4 Max\n") == "Apple M4 Max")
        #expect(WorkedReport.Machine.chipFamily(from: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz") == nil)
        #expect(WorkedReport.Machine.chipFamily(from: "Apple M2 Pro (C02XK1ABCD12)") == nil)
        #expect(WorkedReport.Machine.chipFamily(from: "") == nil)
        #expect(WorkedReport.Machine.chipFamily(from: nil) == nil)
    }

    @Test func theMacOSVersionHasAPatchNumberOnlyWhenThereIsOne() {
        #expect(WorkedReport.Machine.osVersion(15, 4, 0) == "15.4")
        #expect(WorkedReport.Machine.osVersion(15, 4, 1) == "15.4.1")
    }

    @Test func theMachineIsReadFromThisMac() {
        let now = WorkedReport.Machine.current()
        #expect(now.macOSVersion.range(of: "^[0-9]+\\.[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil)
        #expect(!now.appVersion.isEmpty)
        // Whatever the chip is called here, it is nil or a plain Apple name.
        #expect(now.chip == nil || now.chip!.hasPrefix("Apple "))
    }

    // MARK: What must never be in it

    /// A game whose every field holds a path, the home folder or the user's name.
    func leaky() -> Game {
        var game = Game(title: "Sample Game", spaceID: UUID(), source: .steam(appID: "424242"),
                        executablePath: "/Users/jane/Games/Sample Game/Sample.exe",
                        arguments: ["-windowed", "-logfile", "/Users/jane/Library/Logs/sample.log", "-name=Jane", "C:\\Users\\jane\\x"],
                        environment: ["DXVK_HUD": "fps", "DXVK_STATE_CACHE_PATH": "/Users/jane/Library/Caches",
                                      "WINEPREFIX": "/Volumes/Games/Library/Spaces/Main", "WINE_ROOT": "C:\\Games",
                                      "OWNER": "jane", "FULL_NAME": "Jane Doe", "HOME_ISH": "~/Games", "NOTE": "made by JANE",
                                      "/Users/jane/odd": "1", "jane": "1", "NOT A NAME": "1"],
                        coverFile: "cover-jane.png", iconFile: "icon-jane.png")
        game.options = LaunchOptions(disabledFixIDs: ["steam-424242"])
        game.analysis = GameAnalysis(engineName: "Unity", engine: .unity, graphics: [.d3d11], architecture: .x64,
                                     programPath: "/Users/jane/Games/Sample Game/Sample.exe")
        return game
    }

    @Test func aGameWithPathsTheHomeFolderAndTheUserNameInItsFieldsLeaksNoneOfThem() {
        let text = report(leaky(), components: ["xact"]).text
        for secret in ["/Users", "jane", "Jane", "Doe", "/Volumes", "Library", "C:", "\\", "/", "~", "Sample", "Games", "424242",
                       ".log", ".png"] {
            #expect(!text.contains(secret), "the report holds “\(secret)”")
        }
        // What is safe stays.
        #expect(text.contains("DXVK_HUD=fps"))
        #expect(text.contains("Arguments: -windowed -logfile (hidden) (hidden) (hidden)"))
    }

    @Test func environmentValuesShowOnlyWhenTheyHoldNoPathHomeFolderOrUserName() {
        let text = report(leaky()).text
        #expect(text.contains("DXVK_STATE_CACHE_PATH=…(hidden)"))
        #expect(text.contains("WINEPREFIX=…(hidden)"))
        #expect(text.contains("WINE_ROOT=…(hidden)"))
        #expect(text.contains("OWNER=…(hidden)"))
        #expect(text.contains("FULL_NAME=…(hidden)"))
        #expect(text.contains("HOME_ISH=…(hidden)"))
        #expect(text.contains("NOTE=…(hidden)"))
        // A variable named after a path, the user or a sentence isn't listed at all.
        let environment = report(leaky()).lines.first { $0.hasPrefix("Environment:") }!
        #expect(environment == "Environment: DXVK_HUD=fps, DXVK_STATE_CACHE_PATH=…(hidden), FULL_NAME=…(hidden), HOME_ISH=…(hidden), NOTE=…(hidden), OWNER=…(hidden), WINEPREFIX=…(hidden), WINE_ROOT=…(hidden)")
    }

    @Test func theUserNameIsMatchedWhateverTheCaseAndTheHomeFoldersOwnNameToo() {
        var game = plain()
        game.environment = ["A": "Jane", "B": "xJANEx", "C": "fine"]
        let text = WorkedReport(game: game, engine: crossover, planned: .dxvk, components: [], machine: machine,
                                redaction: WorkedReport.Redaction(homeFolder: "/Users/jdoe", names: ["jdoe", "Jane"])).text
        #expect(text.contains("A=…(hidden)") && text.contains("B=…(hidden)") && text.contains("C=fine"))
        // Nothing to match, nothing hidden but paths.
        let empty = WorkedReport(game: game, engine: crossover, planned: .dxvk, components: [], machine: machine,
                                 redaction: WorkedReport.Redaction(homeFolder: "", names: [""])).text
        #expect(empty.contains("A=Jane") && empty.contains("B=xJANEx"))
    }

    @Test func aValueIsOneShortLineWithoutBackticks() {
        var game = plain()
        game.environment = ["A": "one\ntwo", "B": "a`b", "C": String(repeating: "x", count: 300)]
        let environment = report(game).lines.first { $0.hasPrefix("Environment:") }!
        #expect(environment.contains("A=one two"))
        #expect(environment.contains("B=a'b"))
        #expect(environment.contains("C=" + String(repeating: "x", count: 100) + "…"))
        #expect(!environment.contains("\n") && !environment.contains("`"))
    }

    @Test func theGamesTitleNeverIsInTheReport() {
        var game = plain()
        game.title = "Totally Unique Title"
        #expect(!report(game).text.contains("Unique"))
        #expect(!report(game).text.contains("Title"))
    }

    // MARK: Who may share

    @Test func onlyAGameThatRanWellMayBeShared() {
        var game = plain()
        #expect(!WorkedReport.mayShare(game))
        game.secondsPlayed = GraphicsRetry.secondsToWork - 1
        #expect(!WorkedReport.mayShare(game))
        game.secondsPlayed = GraphicsRetry.secondsToWork
        #expect(WorkedReport.mayShare(game))
        // Automatic wrote its graphics down as working: that is a minute of running already.
        game.secondsPlayed = 0
        game.autoGraphics = AutoGraphics(engineID: crossover.id, failed: [.dxmt])
        #expect(!WorkedReport.mayShare(game))
        game.autoGraphics = AutoGraphics(engineID: crossover.id, worked: .dxvk)
        #expect(WorkedReport.mayShare(game))
        // An app such as Steam isn't a game.
        game.kind = .app
        #expect(!WorkedReport.mayShare(game))
    }
}
