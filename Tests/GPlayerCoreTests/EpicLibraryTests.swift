import Foundation
import Testing
@testable import GPlayerCore

// Epic games installed with Legendary, in the library and in a launch. No Wine and no Legendary: the planner is pure, and
// `LegendaryLaunch` is read from JSON of the shape `legendary launch --json` prints (made-up game, made-up paths).

private func installedGame(_ appName: String = "SampleApp", title: String = "Sample Game", folder: String,
                           executable: String = "Bin\\Sample.exe") -> LegendaryInstalledGame {
    LegendaryInstalledGame(appName: appName, title: title, version: "1", installPath: folder, executable: executable, installSize: 1)
}

private func launchJSON(folder: String, game: String = "Bin/Sample.exe", parameters: [String] = ["-nosplash"], user: [String] = [],
                        environment: String = #"{"CX_BOTTLE": "Legendary", "SAMPLE_FLAG": "1"}"#) -> String {
    func list(_ items: [String]) -> String { "[" + items.map { "\"\($0)\"" }.joined(separator: ", ") + "]" }
    return """
    {"game_parameters": \(list(parameters)), "game_executable": "\(game)", "game_directory": "\(folder)",
     "egl_parameters": ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=0123456789abcdef0123456789abcdef", "-AUTH_TYPE=exchangecode", "-epicapp=SampleApp", "-epicusername=Sample Player"],
     "launch_command": ["/engine/bin/wine"], "working_directory": "\(folder)/Bin", "user_parameters": \(list(user)),
     "environment": \(environment), "pre_launch_command": "", "pre_launch_wait": false}
    """
}

@Suite struct EpicGameSourceTests {
    @Test func theSourceIsNamedAndNotAStoreKey() {
        let source = Game.Source.legendary(appName: "SampleApp")
        #expect(source.label == "Epic Games")
        #expect(Game.storeKey(for: source) == nil)
        #expect(source.startsProgramItself && Game.Source.executable.startsProgramItself)
        #expect(!Game.Source.steam(appID: "1").startsProgramItself && !Game.Source.epic(appName: "a", launchURI: "u").startsProgramItself)
    }

    @Test func aStoreGameCanBeHiddenButNotRemoved() {
        let game = Game(title: "Sample Game", spaceID: UUID(), source: .legendary(appName: "SampleApp"))
        #expect(!game.canRemove)
        #expect(game.storeKey == nil)
    }

    @Test func theSourceSurvivesALibraryFile() throws {
        let tmp = TempFolder()
        let store = LibraryStore(paths: LibraryPaths(root: tmp.url))
        let s = Space(name: "Epic Games", path: "/x", engineID: "e", origin: .managed, presetID: EpicGames.presetID)
        var state = LibraryState()
        state.spaces = [s]
        state.games = [Game(title: "Sample Game", spaceID: s.id, source: .legendary(appName: "SampleApp"), executablePath: "drive_c/Games/Epic/S/Bin/Sample.exe"),
                       Game(title: "Old", spaceID: s.id)]
        try store.save(state)
        let loaded = try store.load()
        #expect(loaded.games.map(\.source) == [.legendary(appName: "SampleApp"), .executable])
        #expect(loaded.spaces.first?.presetID == "legendary")
    }

    @Test func aLibraryFromBeforeLegendaryLoadsAsItWas() throws {
        let json = """
        {"version": 1, "spaces": [], "games": [{"id": "6E3B8B4E-7C1F-4B1B-9D1E-0A1B2C3D4E5F", "title": "Fan Game", "kind": "game",
         "spaceID": "7E3B8B4E-7C1F-4B1B-9D1E-0A1B2C3D4E5F", "source": {"epic": {"appName": "a", "launchURI": "u"}}, "arguments": [],
         "graphics": "auto", "environment": {}, "addedAt": 0, "secondsPlayed": 0}], "hiddenStoreKeys": []}
        """
        let state = try JSONDecoder().decode(LibraryState.self, from: Data(json.utf8))
        #expect(state.games.first?.source == .epic(appName: "a", launchURI: "u"))
    }
}

@Suite struct EpicMergeTests {
    let tmp = TempFolder()
    var epic: Space { space(at: tmp.prefix("Epic Games"), preset: EpicGames.presetID) }
    var folder: String { epic.driveC.appendingPathComponent("Games/Epic/SampleGame").path }

    @Test func theSpaceIsFoundByItsPresetAndItsGamesGoInDriveC() {
        let s = epic
        let other = space(at: tmp.prefix("Main"))
        #expect(EpicGames.space(in: [other, s])?.id == s.id)
        #expect(EpicGames.space(in: [other]) == nil)
        #expect(EpicGames.installBase(in: s).path == s.driveC.path + "/Games/Epic")
        #expect(AppPresets.preset(EpicGames.presetID) == nil)               // no launcher: nothing of a preset applies to it
    }

    @Test func anInstalledGameBecomesAnEntry() {
        let s = epic
        tmp.file("Epic Games/drive_c/Games/Epic/SampleGame/Bin/Sample.exe")
        let merged = EpicGames.merge(existing: [], installed: [installedGame(folder: folder)], space: s)
        #expect(merged.changed)
        #expect(merged.games.count == 1)
        let game = merged.games[0]
        #expect(game.title == "Sample Game" && game.source == .legendary(appName: "SampleApp") && game.spaceID == s.id)
        #expect(game.executablePath == "drive_c/Games/Epic/SampleGame/Bin/Sample.exe")      // relative: a moved library keeps working
        #expect(game.executableURL(in: s)?.path == folder + "/Bin/Sample.exe")
    }

    @Test func aGameThatIsAlreadyThereKeepsWhatTheUserDid() {
        let s = epic
        tmp.file("Epic Games/drive_c/Games/Epic/SampleGame/Bin/Sample.exe")
        var game = Game(title: "My Name", spaceID: s.id, source: .legendary(appName: "SampleApp"),
                        executablePath: "drive_c/Games/Epic/SampleGame/Bin/Sample.exe", secondsPlayed: 600, hidden: true)
        game.analysis = GameAnalysis(engine: .unity)
        let merged = EpicGames.merge(existing: [game], installed: [installedGame(folder: folder)], space: s)
        #expect(!merged.changed)
        #expect(merged.games == [game])
    }

    @Test func aMovedProgramIsLookedAtAgain() {
        let s = epic
        tmp.file("Epic Games/drive_c/Games/Epic/SampleGame/Bin64/Sample.exe")
        var game = Game(title: "Sample Game", spaceID: s.id, source: .legendary(appName: "SampleApp"),
                        executablePath: "drive_c/Games/Epic/SampleGame/Bin/Sample.exe", secondsPlayed: 5)
        game.analysis = GameAnalysis(engine: .unity)
        let merged = EpicGames.merge(existing: [game], installed: [installedGame(folder: folder, executable: "Bin64/Sample.exe")], space: s)
        #expect(merged.changed)
        #expect(merged.games[0].executablePath == "drive_c/Games/Epic/SampleGame/Bin64/Sample.exe")
        #expect(merged.games[0].analysis == nil && merged.games[0].secondsPlayed == 5)
    }

    @Test func aGameLegendaryNoLongerListsLeaves() {
        let s = epic
        let gone = Game(title: "Gone", spaceID: s.id, source: .legendary(appName: "Gone"), executablePath: "x.exe")
        let merged = EpicGames.merge(existing: [gone], installed: [], space: s)
        #expect(merged.changed && merged.games.isEmpty)
    }

    @Test func aGameWhoseProgramIsGoneFromTheDiskLeaves() {
        let s = epic                                                                         // the folder was deleted in Finder
        let game = Game(title: "Sample Game", spaceID: s.id, source: .legendary(appName: "SampleApp"),
                        executablePath: "drive_c/Games/Epic/SampleGame/Bin/Sample.exe")
        let merged = EpicGames.merge(existing: [game], installed: [installedGame(folder: folder)], space: s)
        #expect(merged.changed && merged.games.isEmpty)
    }

    @Test func otherGamesAndSpacesAreLeftAlone() {
        let s = epic
        let main = space(at: tmp.prefix("Main"))
        let mine = Game(title: "Mine", spaceID: main.id, executablePath: "drive_c/Games/a.exe")
        let steam = Game(title: "Steam Game", spaceID: main.id, source: .steam(appID: "1"))
        let elsewhere = Game(title: "Sample Game", spaceID: main.id, source: .legendary(appName: "SampleApp"), executablePath: "x.exe")
        let merged = EpicGames.merge(existing: [mine, steam, elsewhere], installed: [], space: s)
        #expect(!merged.changed)
        #expect(merged.games == [mine, steam, elsewhere])
    }

    @Test func theListOfOwnedGamesIsKeptAndForgotten() throws {
        let paths = LibraryPaths(root: tmp.url.appendingPathComponent("Library"))
        #expect(EpicGames.loadList(in: paths).isEmpty)
        let games = [EpicGame(appName: "SampleApp", title: "Sample Game", coverURL: URL(string: "https://cdn.example/t.jpg")),
                     EpicGame(appName: "Other", title: "Other Game")]
        try EpicGames.saveList(games, in: paths)
        #expect(EpicGames.loadList(in: paths) == games)
        EpicGames.forgetList(in: paths)
        #expect(EpicGames.loadList(in: paths).isEmpty)
    }

    @Test func aListThatCannotBeReadIsEmptyAndABadNameIsDropped() throws {
        let paths = LibraryPaths(root: tmp.url.appendingPathComponent("Library"))
        try FileManager.default.createDirectory(at: paths.tools, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: EpicGames.listFile(in: paths))
        #expect(EpicGames.loadList(in: paths).isEmpty)
        try Data(#"[{"appName": "--force", "title": "Bad"}, {"appName": "Fine", "title": "Fine"}]"#.utf8).write(to: EpicGames.listFile(in: paths))
        #expect(EpicGames.loadList(in: paths).map(\.appName) == ["Fine"])
    }

    @Test func aCoverIsNamedAfterTheGameOnlyWhenTheNameIsLegendarys() {
        #expect(EpicGames.coverFileName(appName: "SampleApp") == "epic-SampleApp.jpg")
        #expect(EpicGames.coverFileName(appName: "../x") == nil)
        #expect(EpicGames.coverFileName(appName: "") == nil)
    }
}

@Suite struct EpicLaunchPlanTests {
    let tmp = TempFolder()
    var epic: Space { space(at: tmp.prefix("Epic Games"), preset: EpicGames.presetID) }
    var folder: String { epic.driveC.appendingPathComponent("Games/Epic/SampleGame").path }

    private func game(_ s: Space) -> Game {
        tmp.file("Epic Games/drive_c/Games/Epic/SampleGame/Bin/Sample.exe")
        return Game(title: "Sample Game", spaceID: s.id, source: .legendary(appName: "SampleApp"),
                    executablePath: "drive_c/Games/Epic/SampleGame/Bin/Sample.exe")
    }

    @Test func theCheckBeforeALaunchPlansTheProgramWithoutAnyCode() throws {
        let s = epic
        let plan = try LaunchPlanner.plan(for: game(s), in: s)
        #expect(plan.arguments.first == folder + "/Bin/Sample.exe")
        #expect(!plan.arguments.contains { $0.hasPrefix("-AUTH_PASSWORD") })
        #expect(plan.workingDirectory?.path == folder + "/Bin")
        #expect(plan.chromiumHelpers.isEmpty && plan.launcherSettings == nil && !plan.needsFreshLauncher)
    }

    @Test func theLaunchHasLegendarysArgumentsInItsOrderAndTheSignInLast() throws {
        let s = epic
        let launch = try #require(LegendaryOutput.launch(launchJSON(folder: folder, parameters: ["-nosplash"], user: ["-windowed"])))
        var g = game(s)
        g.arguments = ["-mine"]
        let plan = try LaunchPlanner.plan(for: g, in: s, legendary: launch)
        let args = plan.arguments
        #expect(args.first == folder + "/Bin/Sample.exe")
        #expect(args.dropFirst().prefix(1) == ["-nosplash"])                                 // the game's own first
        let signIn = Array(args.suffix(5))
        #expect(signIn == launch.eglParameters)                                              // Epic's sign-in last, unchanged
        let middle = args.dropFirst().dropLast(5)
        #expect(middle.contains("-mine") && middle.contains("-windowed"))
        #expect(middle.firstIndex(of: "-mine")! < middle.firstIndex(of: "-windowed")!)       // G-Player's own before the user's
        #expect(plan.workingDirectory?.path == folder + "/Bin")
    }

    @Test func theEnvironmentHasLegendarysWithoutCXBottleAndTheUsersOwnWins() throws {
        let s = epic
        let launch = try #require(LegendaryOutput.launch(launchJSON(folder: folder,
                                                                    environment: #"{"CX_BOTTLE": "Legendary", "SAMPLE_FLAG": "1", "USER_SET": "legendary"}"#)))
        var g = game(s)
        g.environment = ["USER_SET": "mine"]
        let plan = try LaunchPlanner.plan(for: g, in: s, legendary: launch)
        #expect(plan.tweaks.environment["SAMPLE_FLAG"] == "1")
        #expect(plan.tweaks.environment["CX_BOTTLE"] == nil)
        #expect(plan.tweaks.environment["USER_SET"] == "mine")
        // And what Wine gets is G-Player's space, whatever Legendary says.
        let env = WineEnvironment.make(engine: fakeEngine(), space: s, backend: plan.backend, tweaks: plan.tweaks, base: [:])
        #expect(env["WINEPREFIX"] == s.path && env["CX_BOTTLE"] == nil && env["SAMPLE_FLAG"] == "1")
    }

    @Test func aFixThatRewritesTheProgramNeverTouchesTheCode() throws {
        let s = epic
        let launch = try #require(LegendaryOutput.launch(launchJSON(folder: folder)))
        var g = game(s)
        g.analysis = nil
        let fix = GameFix(id: "t", exeNames: ["sample.exe"], replacements: [ArgumentReplacement(from: "0123456789abcdef|Sample", to: "Other")],
                          source: "test")
        let plan = try LaunchPlanner.plan(for: g, in: s, fixes: [fix], legendary: launch)
        #expect(plan.arguments.first?.hasSuffix("Other.exe") == true)                         // the program path is rewritten, as for any game
        #expect(plan.arguments.contains("-AUTH_PASSWORD=0123456789abcdef0123456789abcdef"))   // the sign-in arguments are not
    }

    @Test func theProgramLegendaryNamesIsTheOneStarted() throws {
        let s = epic
        tmp.file("Epic Games/drive_c/Games/Epic/SampleGame/Bin64/Sample.exe")
        let launch = try #require(LegendaryOutput.launch(launchJSON(folder: folder, game: "Bin64/Sample.exe")))
        let plan = try LaunchPlanner.plan(for: game(s), in: s, legendary: launch)
        #expect(plan.arguments.first == folder + "/Bin64/Sample.exe")
    }

    @Test func aProgramThatIsNotThereIsAClearError() throws {
        let s = epic
        let g = Game(title: "Sample Game", spaceID: s.id, source: .legendary(appName: "SampleApp"), executablePath: "drive_c/Games/Epic/none.exe")
        #expect(throws: LaunchPlanner.PlanError.self) { try LaunchPlanner.plan(for: g, in: s) }
        let launch = try #require(LegendaryOutput.launch(launchJSON(folder: folder, game: "Bin/none.exe")))
        #expect(throws: LaunchPlanner.PlanError.self) { try LaunchPlanner.plan(for: game(s), in: s, legendary: launch) }
    }

    @Test func theGameIsPlannedLikeAProgramOfYourOwn() throws {
        let s = epic
        let plan = try LaunchPlanner.plan(for: game(s), in: s)
        // Graphics and components come from the compatibility layers, as for a game added by hand.
        #expect(plan.compat != nil)
        #expect(LaunchPlanner.programNames(of: game(s), in: s, fixes: [], given: nil) == ["Sample.exe"])
    }

    @Test func itsProgramsAreFoundRunningByTheirOwnFolder() {
        let s = epic
        let key = RunningGames.key(for: game(s), in: s)
        #expect(key.folder?.path == folder + "/Bin" && key.programName == "sample.exe")
    }

    @Test func epicGamesMayTryOtherGraphicsLikeAnyProgramG_PlayerStarts() {
        let s = epic
        #expect(GraphicsRetry.mayTry(game(s), spaceMayChange: true))
        #expect(!GraphicsRetry.mayTry(Game(title: "L", spaceID: s.id, source: .epic(appName: "a", launchURI: "u")), spaceMayChange: true))
    }
}
