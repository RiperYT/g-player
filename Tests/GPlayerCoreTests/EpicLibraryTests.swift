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

    @Test func onlyAnEpicGameInstalledWithLegendaryHasALegendaryName() {
        let space = UUID()
        #expect(Game(title: "A", spaceID: space, source: .legendary(appName: "SampleApp")).legendaryAppName == "SampleApp")
        #expect(Game(title: "A", spaceID: space).legendaryAppName == nil)
        #expect(Game(title: "A", spaceID: space, source: .epic(appName: "x", launchURI: "u")).legendaryAppName == nil)
        #expect(Game(title: "A", spaceID: space, source: .steam(appID: "1")).legendaryAppName == nil)
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

    @Test func aGameLegendaryNoLongerListsStaysWithItsPlaytimeAndSettings() {
        // An empty list can be a look at a bad moment (a disk away, the settings folder moved): nothing is lost for it.
        let s = epic
        var gone = Game(title: "Gone", spaceID: s.id, source: .legendary(appName: "Gone"), executablePath: "x.exe", secondsPlayed: 3600, hidden: true)
        gone.environment = ["A": "1"]
        let merged = EpicGames.merge(existing: [gone], installed: [], space: s)
        #expect(!merged.changed && merged.games == [gone])
    }

    @Test func aGameWhoseProgramIsNotFoundStaysAndIsNotChanged() {
        let s = epic                                                                         // the library moved: the record's path is old
        let game = Game(title: "Sample Game", spaceID: s.id, source: .legendary(appName: "SampleApp"),
                        executablePath: "drive_c/Games/Epic/SampleGame/Bin/Sample.exe", secondsPlayed: 600)
        let merged = EpicGames.merge(existing: [game], installed: [installedGame(folder: "/old/library/Spaces/Epic Games/drive_c/Games/Epic/SampleGame")], space: s)
        #expect(!merged.changed && merged.games == [game])
    }

    @Test func aGameInstalledButNotOnTheDiskIsNotAddedYet() {
        let s = epic
        let merged = EpicGames.merge(existing: [], installed: [installedGame(folder: folder)], space: s)     // no file made
        #expect(!merged.changed && merged.games.isEmpty)
    }

    @Test func removingTakesOnlyThatGameOfThatSpace() {
        let s = epic, other = space(at: tmp.prefix("Main"))
        let a = Game(title: "A", spaceID: s.id, source: .legendary(appName: "SampleApp"))
        let b = Game(title: "B", spaceID: s.id, source: .legendary(appName: "OtherApp"))
        let c = Game(title: "C", spaceID: other.id, source: .legendary(appName: "SampleApp"))
        let d = Game(title: "D", spaceID: s.id)
        #expect(EpicGames.removing(appName: "SampleApp", of: s.id, from: [a, b, c, d]) == [b, c, d])
        #expect(EpicGames.removing(appName: "Missing", of: s.id, from: [a, b]) == [a, b])
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

    @Test func theAccountAndTheListOfOwnedGamesAreKeptAndForgotten() throws {
        let paths = LibraryPaths(root: tmp.url.appendingPathComponent("Library"))
        #expect(EpicGames.loadCache(in: paths) == EpicGames.Cache())
        let cache = EpicGames.Cache(account: "Sample Player", games: [
            EpicGame(appName: "SampleApp", title: "Sample Game", coverURL: URL(string: "https://cdn.example/t.jpg")),
            EpicGame(appName: "Other", title: "Other Game")])
        try EpicGames.saveCache(cache, in: paths)
        #expect(EpicGames.loadCache(in: paths) == cache)
        EpicGames.forgetCache(in: paths)
        #expect(EpicGames.loadCache(in: paths) == EpicGames.Cache())
    }

    @Test func theKeptCacheIsPrivateToTheUserFromItsFirstByte() throws {
        let paths = LibraryPaths(root: tmp.url.appendingPathComponent("Library"))
        try EpicGames.saveCache(EpicGames.Cache(account: "Sample Player", games: [EpicGame(appName: "SampleApp", title: "Sample Game")]), in: paths)
        func mode() throws -> Int { (try FileManager.default.attributesOfItem(atPath: EpicGames.cacheFile(in: paths).path)[.posixPermissions] as? Int) ?? 0 }
        #expect(try mode() == 0o600)
        try EpicGames.saveCache(EpicGames.Cache(), in: paths)                                // a second save keeps it private
        #expect(try mode() == 0o600)
        let left = try FileManager.default.contentsOfDirectory(atPath: paths.tools.path)
        #expect(left == ["epic-library.json"])                                                // no temporary file is left behind
    }

    @Test func aWriteThatNeverFinishedLeavesATemporaryFileTheCleanupKnows() throws {
        let paths = LibraryPaths(root: tmp.url.appendingPathComponent("Library"))
        try FileManager.default.createDirectory(at: paths.tools, withIntermediateDirectories: true)
        tmp.file("Library/Tools/.epic-library.json.1A2B3C4D")
        tmp.file("Library/Tools/epic-library.json")
        Leftovers.clean(paths, processes: [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.tools.path) == ["epic-library.json"])
    }

    @Test func aCacheThatCannotBeReadIsEmptyAndABadNameIsDropped() throws {
        let paths = LibraryPaths(root: tmp.url.appendingPathComponent("Library"))
        try FileManager.default.createDirectory(at: paths.tools, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: EpicGames.cacheFile(in: paths))
        #expect(EpicGames.loadCache(in: paths) == EpicGames.Cache())
        try Data(#"{"account": "Sample Player", "games": [{"appName": "--force", "title": "Bad"}, {"appName": "Fine", "title": "Fine"}]}"#.utf8)
            .write(to: EpicGames.cacheFile(in: paths))
        let cache = EpicGames.loadCache(in: paths)
        #expect(cache.account == "Sample Player" && cache.games.map(\.appName) == ["Fine"])
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

    @Test func theEnvironmentFromLegendaryIsOnlyWhatIsAllowedAndSitsBelowTheLayersAndTheUsersOwn() throws {
        let s = epic
        let json = launchJSON(folder: folder, environment: """
            {"CX_BOTTLE": "Legendary", "WINEPREFIX": "/elsewhere", "WINEDLLOVERRIDES": "d3d11=b", "DXVK_HUD": "full",
             "SAMPLE_FLAG": "legendary", "FIX_SET": "legendary", "USER_SET": "legendary"}
            """)
        let launch = try #require(LegendaryOutput.launch(json, allowing: ["SAMPLE_FLAG", "FIX_SET", "USER_SET", "WINEPREFIX", "DXVK_HUD"]))
        var g = game(s)
        g.environment = ["USER_SET": "mine"]
        let fix = GameFix(id: "t", exeNames: ["sample.exe"], environment: ["FIX_SET": "fix"], source: "test")
        let plan = try LaunchPlanner.plan(for: g, in: s, fixes: [fix], legendary: launch)
        #expect(plan.tweaks.environment["SAMPLE_FLAG"] == "legendary")
        #expect(plan.tweaks.environment["FIX_SET"] == "fix")                      // the layers' value wins over Legendary's
        #expect(plan.tweaks.environment["USER_SET"] == "mine")                    // and the user's own over both
        for name in ["CX_BOTTLE", "WINEPREFIX", "WINEDLLOVERRIDES", "DXVK_HUD"] { #expect(plan.tweaks.environment[name] == nil, "\(name)") }
        // What Wine gets is G-Player's own, whatever Legendary says.
        let env = WineEnvironment.make(engine: fakeEngine(), space: s, backend: plan.backend, tweaks: plan.tweaks, base: [:])
        #expect(env["WINEPREFIX"] == s.path && env["CX_BOTTLE"] == nil && env["DXVK_HUD"] == nil && env["SAMPLE_FLAG"] == "legendary")
        #expect(env["WINEDLLOVERRIDES"]?.contains("d3d11=b") != true)
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

    @Test func aProgramThatIsNotThereSaysWhatToDoAndNeverToChooseOneInItsSettings() throws {
        let s = epic
        let g = Game(title: "Sample Game", spaceID: s.id, source: .legendary(appName: "SampleApp"), executablePath: "drive_c/Games/Epic/none.exe")
        func message(_ work: () throws -> LaunchPlan) -> String? {
            do { _ = try work(); return nil } catch { return error.localizedDescription }
        }
        let first = message { try LaunchPlanner.plan(for: g, in: s) }
        let launch = try #require(LegendaryOutput.launch(launchJSON(folder: folder, game: "Bin/none.exe")))
        let second = message { try LaunchPlanner.plan(for: game(s), in: s, legendary: launch) }
        for text in [first, second] {
            let text = try #require(text)
            #expect(text.contains("Open Epic Games in the sidebar") && !text.contains("settings"), "\(text)")
        }
        #expect(first?.contains("Sample Game") == true)
        // A program the user added still says how to choose another.
        let mine = Game(title: "Mine", spaceID: s.id, executablePath: "drive_c/Games/none.exe")
        #expect(message { try LaunchPlanner.plan(for: mine, in: s) }?.contains("Choose one in its settings") == true)
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

@Suite struct EpicRaceTests {
    @Test func aGameThatRunsOrStartsCantBeUninstalledAndSaysWhy() {
        #expect(EpicGames.uninstallBlock(gameIsRunning: true, gameIsStarting: false, busy: nil) == "Quit the game first.")
        #expect(EpicGames.uninstallBlock(gameIsRunning: false, gameIsStarting: true, busy: nil) == "The game is starting. Wait for it, then quit it.")
        // A running game is named before anything else Legendary does.
        #expect(EpicGames.uninstallBlock(gameIsRunning: true, gameIsStarting: true, busy: "installing") == "Quit the game first.")
    }

    @Test func legendaryDoingSomethingElseBlocksAnUninstall() {
        #expect(EpicGames.uninstallBlock(gameIsRunning: false, gameIsStarting: false, busy: "Installing “Sample Game”")
                == "Epic Games is busy (Installing “Sample Game”). Wait for it to finish.")
        #expect(EpicGames.uninstallBlock(gameIsRunning: false, gameIsStarting: false, busy: nil) == nil)
    }

    @Test func aGameBeingUninstalledCantBeStartedButAnotherCan() {
        #expect(EpicGames.playBlock(appName: "SampleApp", uninstalling: "SampleApp") == "It is being uninstalled.")
        #expect(EpicGames.playBlock(appName: "SampleApp", uninstalling: "OtherApp") == nil)
        #expect(EpicGames.playBlock(appName: "SampleApp", uninstalling: nil) == nil)
    }
}

@Suite struct EpicHealthTests {
    let tmp = TempFolder()
    var epic: Space { space(at: tmp.prefix("Epic Games"), preset: EpicGames.presetID) }
    private let old = "/old/library/Spaces/Epic Games/drive_c/Games/Epic/SampleGame"

    private func record(_ folder: String, executable: String = "Bin\\Sample.exe") -> LegendaryInstalledGame {
        installedGame(folder: folder, executable: executable)
    }

    @Test func nothingIsWrongBeforeLegendarysListHasBeenRead() {
        #expect(EpicGames.health(record: nil, recordsKnown: false, space: epic) == .ok)
        #expect(EpicGames.health(record: record(old), recordsKnown: false, space: epic) == .ok)
    }

    @Test func aGameWhoseProgramIsWhereLegendarySaysIsFine() {
        let s = epic
        let folder = s.driveC.appendingPathComponent("Games/Epic/SampleGame").path
        tmp.file("Epic Games/drive_c/Games/Epic/SampleGame/Bin/Sample.exe")
        #expect(EpicGames.health(record: record(folder), recordsKnown: true, space: s) == .ok)
    }

    @Test func aGameLegendaryHasNoRecordOfIsNotRecorded() {
        #expect(EpicGames.health(record: nil, recordsKnown: true, space: epic) == .notRecorded)
    }

    @Test func aMovedLibraryIsRepairableWhenTheFilesAreInTheSpaceAtTheSameRelativePath() {
        let s = epic
        tmp.file("Epic Games/drive_c/Games/Epic/SampleGame/Bin/Sample.exe")                  // the files moved along with the library
        let health = EpicGames.health(record: record(old), recordsKnown: true, space: s)
        #expect(health == .filesNotFound(repairBase: EpicGames.installBase(in: s)))
    }

    @Test func aGameWhoseFilesAreNowhereIsNotRepairable() {
        #expect(EpicGames.health(record: record(old), recordsKnown: true, space: epic) == .filesNotFound(repairBase: nil))
    }

    @Test func aRecordAlreadyInThisSpaceWithoutItsProgramHasNothingToRepairWith() {
        let s = epic
        let here = s.driveC.appendingPathComponent("Games/Epic/SampleGame").path
        tmp.dir("Epic Games/drive_c/Games/Epic/SampleGame")                                    // the folder, but not the program
        #expect(EpicGames.health(record: record(here), recordsKnown: true, space: s) == .filesNotFound(repairBase: nil))
    }

    @Test func aFolderOfAnotherNameIsNotTakenForTheGame() {
        let s = epic
        tmp.file("Epic Games/drive_c/Games/Epic/Renamed/Bin/Sample.exe")
        #expect(EpicGames.health(record: record(old), recordsKnown: true, space: s) == .filesNotFound(repairBase: nil))
    }

    @Test func aRecordWhoseProgramLeavesItsFolderIsBroken() {
        let s = epic
        let health = EpicGames.health(record: record(old, executable: "..\\..\\x.exe"), recordsKnown: true, space: s)
        #expect(health == .filesNotFound(repairBase: nil))
    }
}

@Suite struct EpicHealthNoteTests {
    @Test func aHealthyGameHasNothingToSay() {
        #expect(EpicGames.note(for: .ok, title: "Sample Game") == nil)
    }

    @Test func aRepairableGameOffersTheRepairAndSaysNothingIsDeletedOnRemoval() throws {
        let note = try #require(EpicGames.note(for: .filesNotFound(repairBase: URL(fileURLWithPath: "/lib/Epic")), title: "Sample Game"))
        #expect(note.title == "Files not found")
        #expect(note.detail.contains("Repair") && note.detail.contains("“Sample Game”"))
        #expect(note.removal.contains("No file is deleted") && note.removal.contains("install it again"))
    }

    @Test func aGameWhoseFilesAreGoneSaysToPutThemBackOrRemoveIt() throws {
        let note = try #require(EpicGames.note(for: .filesNotFound(repairBase: nil), title: "Sample Game"))
        #expect(note.title == "Files not found" && !note.detail.contains("Repair"))
        #expect(note.detail.contains("put them back") && note.detail.contains("install it again"))
        #expect(note.removal.contains("No file is deleted"))
    }

    @Test func aGameLegendaryForgotCanOnlyLeaveTheLibrary() throws {
        let note = try #require(EpicGames.note(for: .notRecorded, title: "Sample Game"))
        #expect(note.title == "Not installed" && note.detail.contains("Remove it from the library"))
        #expect(note.removal.contains("leaves the library") && note.removal.contains("no file is deleted"))
    }
}

@Suite struct EpicInstallQuestionTests {
    private let gigabytes: Int64 = 1_000_000_000

    @Test func theQuestionSaysWhereTheGameGoesAndWhatItTakes() {
        let details = EpicGames.installDetails(sizeBytes: 20 * gigabytes, availableBytes: 100 * gigabytes, spaceExists: true, engineDownloadBytes: nil)
        #expect(details.lines == ["It takes about \((20 * gigabytes).formattedBytes) on disk.", "It goes into the “Epic Games” space."])
        #expect(details.problem == nil)
    }

    @Test func aSpaceThatIsNotThereYetIsMadeFirstAndSaidSo() {
        let details = EpicGames.installDetails(sizeBytes: nil, availableBytes: nil, spaceExists: false, engineDownloadBytes: nil)
        #expect(details.lines == ["It goes into the “Epic Games” space, which G-Player makes first."])
        #expect(details.problem == nil)                                                        // no size known: nothing to refuse for
    }

    @Test func gPlayerWineThatIsNotThereIsDownloadedFirstAndSaidSo() {
        let details = EpicGames.installDetails(sizeBytes: nil, availableBytes: nil, spaceExists: false, engineDownloadBytes: 450_400_000)
        #expect(details.lines.count == 2)
        #expect(details.lines[1] == "G-Player Wine isn't installed yet, so G-Player downloads it first (about 450 MB).")
    }

    @Test func aDiskThatIsTooSmallIsAProblem() {
        let details = EpicGames.installDetails(sizeBytes: 50 * gigabytes, availableBytes: 10 * gigabytes, spaceExists: true, engineDownloadBytes: nil)
        #expect(details.problem == "It needs about \((50 * gigabytes).formattedBytes) free, and this disk has \((10 * gigabytes).formattedBytes). Free some space, then try again.")
        #expect(EpicGames.installDetails(sizeBytes: 50 * gigabytes, availableBytes: nil, spaceExists: true, engineDownloadBytes: nil).problem == nil)
    }

    @Test func theSpaceIsMadeOnGPlayerWineNeverOnWineStaging() {
        let staging = EngineCatalog.wineStaging
        #expect(EpicGames.engineForSpace(installed: []).id == EngineCatalog.crossover.id)
        #expect(EpicGames.engineForSpace(installed: [staging]).id == EngineCatalog.crossover.id)           // not what a new space gets
        #expect(EngineCatalog.engineForNewSpace(installed: [staging]).id == staging.id)                    // (which would have been Staging)
        #expect(EpicGames.engineForSpace(installed: [staging, EngineCatalog.crossover]).id == EngineCatalog.crossover.id)
        // A G-Player Wine that is installed, even a retired revision, is used rather than downloading another.
        #expect(EpicGames.engineForSpace(installed: [EngineCatalog.crossoverRevision1, staging]).id == EngineCatalog.crossoverRevision1.id)
    }

    @Test func aGameStartedOfflineSaysWhy() {
        #expect(EpicGames.offlineNote(reason: "Epic Games can't be reached.") == "Started offline: Epic Games can't be reached.")
        #expect(EpicGames.askingEpic == "Asking Epic for the launch parameters…")
    }

    @Test func theDownloadIsDescribedFromThePin() {
        let text = Legendary.downloadSummary
        #expect(text.contains("open-source") && text.contains("github.com") && text.contains(Legendary.download.approximateBytes.formattedBytes))
    }
}

@Suite struct EpicPageTests {
    private struct Boom: LocalizedError { var errorDescription: String? { "the file is gone" } }

    @Test func aLookThatSaysNobodyIsSignedInIsTheOnlyWayToBeSignedOut() {
        #expect(EpicGames.account(afterLook: .success(LegendaryStatus(account: nil)), was: "Sample Player") == nil)
        #expect(EpicGames.account(afterLook: .success(LegendaryStatus(account: "Sample Player")), was: nil) == "Sample Player")
        #expect(EpicGames.account(afterLook: .success(LegendaryStatus(account: "Other")), was: "Sample Player") == "Other")
    }

    @Test func aLookThatFailsKeepsWhoWasKnown() {
        #expect(EpicGames.account(afterLook: .failure(Boom()), was: "Sample Player") == "Sample Player")
        #expect(EpicGames.account(afterLook: .failure(Boom()), was: nil) == nil)
        #expect(EpicGames.lookFailureLine(Boom()) == "Couldn't reach Legendary: the file is gone")
    }

    @Test func theSignedInPageStaysWhenALookFailsAndOnlyTheFailureShowsWhenNothingIsKnown() {
        #expect(EpicGames.page(account: "Sample Player", looked: true, lookFailed: true) == .signedIn)
        #expect(EpicGames.page(account: "Sample Player", looked: false, lookFailed: false) == .signedIn)       // from what was kept
        #expect(EpicGames.page(account: nil, looked: true, lookFailed: true) == .failed)                       // not "sign in": nothing was learned
        #expect(EpicGames.page(account: nil, looked: true, lookFailed: false) == .signedOut)
        #expect(EpicGames.page(account: nil, looked: false, lookFailed: false) == .checking)
    }

    @Test func aListThatIsThereIsShownWhateverHappenedSince() {
        #expect(EpicGames.listContent(hasGames: true, fetched: true, fetchFailed: true) == .games)           // with the failure above it
        #expect(EpicGames.listContent(hasGames: true, fetched: false, fetchFailed: false) == .games)         // the kept one, while Epic is asked
        #expect(EpicGames.listContent(hasGames: false, fetched: true, fetchFailed: true) == .failureOnly)
        #expect(EpicGames.listContent(hasGames: false, fetched: false, fetchFailed: false) == .loading)
        #expect(EpicGames.listContent(hasGames: false, fetched: true, fetchFailed: false) == .empty)
    }
}
