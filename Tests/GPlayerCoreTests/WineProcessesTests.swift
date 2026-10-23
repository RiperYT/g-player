import Foundation
import Testing
@testable import GPlayerCore

/// Telling which space, and which game, a Windows program belongs to.
@Suite struct WineProcessesTests {
    @Test func aSpaceUnderVarIsFoundThroughPrivate() {
        // The kernel says /private/var/folders/… for a space the library keeps as /var/folders/….
        let s = Space(name: "Steam", path: "/var/folders/xy/T/lib/Spaces/Steam", engineID: "e", origin: .managed)
        let p = WineProcess(pid: 1, command: #"C:\Program Files (x86)\Steam\steam.exe"#,
                            directory: "/private/var/folders/xy/T/lib/Spaces/Steam/drive_c/Program Files (x86)/Steam")
        #expect(WineProcesses.programs(in: s, from: [p]).count == 1)
        let back = Space(name: "Steam", path: "/private/tmp/lib/Steam", engineID: "e", origin: .managed)
        let q = WineProcess(pid: 2, command: #"C:\windows\system32\notepad.exe"#, directory: "/tmp/lib/Steam/drive_c/windows")
        #expect(WineProcesses.programs(in: back, from: [q]).count == 1)
    }

    let steam = Space(name: "Steam", path: "/Users/me/Bottles/Steam", engineID: "x", origin: .external)
    let steam2 = Space(name: "Steam 2", path: "/Users/me/Bottles/Steam 2", engineID: "x", origin: .external)
    let indie = Space(name: "Indie", path: "/Users/me/Games/Indie", engineID: "x", origin: .external)

    private var common: String { "/Users/me/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common" }

    private var processes: [WineProcess] {
        [
            WineProcess(pid: 213, command: #"C:\windows\system32\services.exe"#,
                        directory: "/Users/me/Bottles/Steam/drive_c/windows/system32"),
            WineProcess(pid: 223, command: #"C:\windows\system32\explorer.exe /desktop"#,
                        directory: "/Users/me/Bottles/Steam/drive_c/windows/system32"),
            WineProcess(pid: 240, command: #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper_real.exe --type=renderer"#,
                        directory: "/Users/me/Bottles/Steam/drive_c/Program Files (x86)/Steam"),
            WineProcess(pid: 300, command: #"C:\Program Files (x86)\Steam\steamapps\common\Cossacks 3\cossacks.exe"#,
                        directory: common + "/Cossacks 3"),
            WineProcess(pid: 301, command: #"C:\Program Files (x86)\Steam\steamapps\common\Some RPG\Game.exe"#,
                        directory: common + "/Some RPG"),
            WineProcess(pid: 414, command: "/Users/me/Bottles/Steam/drive_c/Program Files (x86)/Steam/steam.exe -silent",
                        directory: "/Users/me/Bottles/Steam/drive_c/Program Files (x86)/Steam",
                        prefix: "/Users/me/Bottles/Steam"),
            // A game kept outside its space: a Z: path and a working folder outside the prefix.
            WineProcess(pid: 500, command: #"Z:\Users\me\Games\Indie-game\Indie\Game.exe --no-sandbox"#,
                        directory: "/Users/me/Games/Indie-game/Indie", prefix: "/Users/me/Games/Indie"),
            WineProcess(pid: 501, command: #"Z:\Users\me\Games\Indie-game\Indie\Game.exe --type=gpu-process"#,
                        directory: "/Users/me/Games/Indie-game/Indie"),
        ]
    }

    @Test func aGameSteamStartedBelongsToSteamsSpace() {
        let names = WineProcesses.programs(in: steam, from: processes).compactMap(\.programName)
        #expect(names == ["services.exe", "explorer.exe", "steamwebhelper_real.exe", "cossacks.exe", "game.exe", "steam.exe"])
        #expect(WineProcesses.programs(in: steam2, from: processes).isEmpty)                   // "Steam" is not "Steam 2"
        #expect(WineProcesses.isRunning(in: steam, processes: processes))
        #expect(WineProcesses.isSteamRunning(in: steam, processes: processes))
        #expect(!WineProcesses.isSteamRunning(in: steam2, processes: processes))
    }

    @Test func steamsHelpersAreLeftoversOnlyOnceSteamItselfHasGone() {
        // With steam.exe there, its web helper is Steam's.
        #expect(WineProcesses.orphanedSteamHelpers(in: steam, processes: processes).isEmpty)
        // Without it, the web helper is a leftover; the game and Wine's services in the space are not.
        let gone = processes.filter { $0.programName != "steam.exe" }
        let orphans = WineProcesses.orphanedSteamHelpers(in: steam, processes: gone)
        #expect(!orphans.isEmpty && orphans.allSatisfy { $0.programName?.hasPrefix("steamwebhelper") == true })
        #expect(WineProcesses.orphanedSteamHelpers(in: steam2, processes: gone).isEmpty)
    }

    @Test func aProgramStartedWithTheSpacesPrefixBelongsToIt() {
        // Indie's own process shows WINEPREFIX; its GPU helper doesn't and isn't in the prefix.
        #expect(WineProcesses.programs(in: indie, from: processes).map(\.pid) == [500])
        #expect(WineProcesses.isRunning(in: indie, processes: processes))
    }

    @Test func wineServicesAloneDontMakeASpaceBusy() {
        let services = processes.filter { [213, 223].contains($0.pid) }
        #expect(services.allSatisfy { $0.isWineService })
        #expect(!WineProcesses.isRunning(in: steam, processes: services))
        #expect(!WineProcess(pid: 1, command: #"C:\windows\system32\msiexec.exe /i x.msi"#).isWineService)
        #expect(!WineProcess(pid: 1, command: #"C:\windows\explorer.exe C:\"#).isWineService)
    }

    @Test func gamesAreToldApartByTheirFolderNotTheirExeName() {
        let rpg = URL(fileURLWithPath: common + "/Some RPG")
        let indieFolder = URL(fileURLWithPath: "/Users/me/Games/Indie-game/Indie")
        let other = URL(fileURLWithPath: common + "/Other RPG")
        #expect(WineProcesses.programs(ofGameIn: rpg, programName: "game.exe", space: steam, from: processes).map(\.pid) == [301])
        #expect(WineProcesses.programs(ofGameIn: indieFolder, programName: "game.exe", space: indie, from: processes).map(\.pid) == [500, 501])
        #expect(WineProcesses.programs(ofGameIn: other, programName: "game.exe", space: steam, from: processes).isEmpty)
        // A launcher goes by its name in its own space.
        #expect(WineProcesses.programs(ofGameIn: nil, programName: "steam.exe", space: steam, from: processes).map(\.pid) == [414])
        #expect(WineProcesses.programs(ofGameIn: nil, programName: "steam.exe", space: steam2, from: processes).isEmpty)
    }

    @Test func theProgramNameIsTheExeWithoutItsFolder() {
        #expect(WineProcess(pid: 1, command: #"C:\Games\My Game\Game.EXE -windowed"#).programName == "game.exe")
        #expect(WineProcess(pid: 1, command: "/x/drive_c/Steam/steam.exe -silent").programName == "steam.exe")
        #expect(WineProcess(pid: 1, command: #"C:\Ігри\Козаки\козаки.exe"#).programName == "козаки.exe")
        #expect(WineProcess(pid: 1, command: "/usr/bin/true").programName == nil)
    }

    @Test func procArgsAreSplitIntoArgumentsAndEnvironment() throws {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { bytes += $0 }
        bytes += Array("/path/wine-preloader".utf8) + [0, 0, 0]
        for s in [#"C:\Ігри\game.exe"#, "", "-x", "WINEPREFIX=/Users/me/Bottles/My Ігри", "HOME=/Users/me", ""] {
            bytes += Array(s.utf8) + [0]
        }
        let (args, env) = try #require(WineProcesses.parseProcArgs(bytes))
        #expect(args == [#"C:\Ігри\game.exe"#, "", "-x"])
        #expect(env["WINEPREFIX"] == "/Users/me/Bottles/My Ігри" && env["HOME"] == "/Users/me")
    }

    // MARK: Programs run from a folder

    @Test func processesRunningFromAnEngineFolderAreFoundWhateverTheyAre() {
        let folder = URL(fileURLWithPath: "/Users/me/Library/G-Player/Engines/wine-cx-26.3.0-1")
        let inside = "/Users/me/Library/G-Player/Engines/wine-cx-26.3.0-1/wine/bin/"
        let all = [
            ProcessExecutable(pid: 10, path: inside + "wine64-preloader"),
            ProcessExecutable(pid: 11, path: inside + "wineserver"),
            ProcessExecutable(pid: 12, path: "/Users/me/Library/G-Player/Engines/wine-cx-26.3.0-2/wine/bin/wineserver"),   // the replacement
            ProcessExecutable(pid: 13, path: "/Users/me/Library/G-Player/Engines/wine-cx-26.3.0-10/wine/bin/wineserver"),  // a longer name
            ProcessExecutable(pid: 14, path: "/Users/me/Library/G-Player/Engines/wine-cx-26.3.0-1"),                       // the folder itself
            ProcessExecutable(pid: 15, path: "/usr/bin/sleep"),
        ]
        #expect(WineProcesses.executables(inside: folder, from: all).map(\.pid) == [10, 11, 14])
        #expect(WineProcesses.executables(inside: folder, from: []).isEmpty)
    }

    @Test func aFolderUnderVarIsFoundThroughPrivateAndWhateverTheCase() {
        // The kernel says /private/var/…; a library kept as /var/… and typed in another case is still the same folder.
        let folder = URL(fileURLWithPath: "/var/folders/xy/T/Lib/Engines/old")
        let all = [ProcessExecutable(pid: 1, path: "/private/var/folders/xy/T/Lib/Engines/old/wine/bin/wineserver"),
                   ProcessExecutable(pid: 2, path: "/var/folders/xy/T/LIB/engines/OLD/wine/bin/wine"),
                   ProcessExecutable(pid: 3, path: "/var/folders/xy/T/Lib/Engines/older/wine/bin/wine")]
        #expect(WineProcesses.executables(inside: folder, from: all).map(\.pid) == [1, 2])
    }

    @Test func theRealProcessTableListsTheProgramFileOfThisProcess() throws {
        let mine = try #require(WineProcesses.executables().first { $0.pid == getpid() })
        #expect(mine.path.hasPrefix("/") && FileManager.default.fileExists(atPath: mine.path))
        // Its own folder holds it; another folder doesn't.
        let folder = URL(fileURLWithPath: mine.path).deletingLastPathComponent()
        #expect(WineProcesses.executables(inside: folder, from: WineProcesses.executables()).contains { $0.pid == getpid() })
        let elsewhere = TempFolder()
        #expect(!WineProcesses.executables(inside: elsewhere.url, from: WineProcesses.executables()).contains { $0.pid == getpid() })
    }

    @Test func theRealSnapshotRuns() {
        let all = WineProcesses.snapshot()
        #expect(all.allSatisfy { $0.pid > 0 && WineProcesses.isWindowsProgram($0.command) })
    }
}

@Suite struct RunningGamesTests {
    let steam = Space(name: "Steam", path: "/Users/me/Bottles/Steam", engineID: "x", origin: .external)
    let indie = Space(name: "Indie", path: "/Users/me/Games/Indie", engineID: "x", origin: .external)
    private var common: String { "/Users/me/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common" }

    private func steamGame(_ id: String, _ folder: String, _ exe: String) -> Game {
        var g = Game(title: folder, spaceID: steam.id, source: .steam(appID: id))
        g.analysis = GameAnalysis(programPath: "\(common)/\(folder)/\(exe)", version: GameAnalysis.currentVersion)
        return g
    }

    @Test func eachKindOfEntryHasItsKey() {
        let launcher = Game(title: "Steam", kind: .app, spaceID: steam.id,
                            executablePath: "drive_c/Program Files (x86)/Steam/steam.exe")
        #expect(RunningGames.key(for: launcher, in: steam) == .init(folder: nil, programName: "steam.exe"))
        let rpg = steamGame("1", "Some RPG", "Game.exe")
        #expect(RunningGames.key(for: rpg, in: steam).folder?.path == common + "/Some RPG")
        let nested = steamGame("2", "Big Game", "Binaries/Win64/BigGame-Shipping.exe")
        #expect(RunningGames.key(for: nested, in: steam).folder?.path == common + "/Big Game")
        let added = Game(title: "Indie", spaceID: indie.id, executablePath: "/Users/me/Games/Indie-game/Indie/Game.exe")
        #expect(RunningGames.key(for: added, in: indie).folder?.path == "/Users/me/Games/Indie-game/Indie")
        let loose = Game(title: "Tool", spaceID: indie.id, executablePath: "drive_c/tool.exe")
        #expect(RunningGames.key(for: loose, in: indie) == .init(folder: nil, programName: "tool.exe"))
        let unknown = Game(title: "?", spaceID: steam.id, source: .steam(appID: "3"))
        #expect(RunningGames.key(for: unknown, in: steam) == .init(folder: nil, programName: nil))
    }

    @Test func twoGamesWithTheSameExeNameAreToldApart() {
        let rpg = steamGame("1", "Some RPG", "Game.exe"), other = steamGame("2", "Other RPG", "Game.exe")
        let running = [WineProcess(pid: 301, command: #"C:\Program Files (x86)\Steam\steamapps\common\Some RPG\Game.exe"#,
                                   directory: common + "/Some RPG")]
        let found = RunningGames.programs(of: [(rpg, steam), (other, steam)], in: running)
        #expect(found.keys.sorted { $0.uuidString < $1.uuidString } == [rpg.id])
    }
}

@Suite struct UnwrappedHelperTests {
    let helpers = ["Program Files (x86)/Steam/bin/cef/cef.*/steamwebhelper.exe"]

    @Test func helpersThatStartedWithoutTheWrapperAreFound() {
        let unwrapped = [
            WineProcess(pid: 1, command: #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe -nocrashdialog"#),
            WineProcess(pid: 2, command: #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=gpu-process"#),
            WineProcess(pid: 3, command: #"C:\Program Files (x86)\Steam\steam.exe -silent"#),
        ]
        #expect(ChromiumHelperWrapper.unwrappedProcesses(helpers: helpers, in: unwrapped).map(\.pid) == [1, 2])
    }

    @Test func wrappedHelpersAreLeftAlone() {
        let wrapped = [
            WineProcess(pid: 1, command: #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe -nocrashdialog"#),
            WineProcess(pid: 2, command: #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper_real.exe -nocrashdialog"#),
            WineProcess(pid: 3, command: #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper_real.exe --type=renderer"#),
        ]
        #expect(ChromiumHelperWrapper.unwrappedProcesses(helpers: helpers, in: wrapped).isEmpty)
    }
}

/// Wine that starts programs without end (a prefix whose path is too long does it) is stopped before the Mac runs out
/// of processes.
@Suite struct RunawayTests {
    let steam = Space(name: "Steam", path: "/Users/me/Bottles/Steam", engineID: "x", origin: .external)
    let steam2 = Space(name: "Steam 2", path: "/Users/me/Bottles/Steam 2", engineID: "x", origin: .external)

    /// Wine's programs have lost their parent, so all there is to go by is where they work and what they were
    /// started with. These have only a working folder, like Explorer copies started by other programs.
    private func explorers(_ count: Int, in space: Space, from pid: Int32 = 1000) -> [WineProcess] {
        (0..<count).map { i in
            WineProcess(pid: pid + Int32(i), command: #"C:\windows\system32\explorer.exe /desktop"#,
                        directory: space.path + "/drive_c/windows/system32")
        }
    }

    private func programs(_ count: Int, in space: Space, from pid: Int32 = 5000) -> [WineProcess] {
        (0..<count).map { i in
            WineProcess(pid: pid + Int32(i), command: #"C:\Games\Some Game\helper.exe --type=utility"#,
                        directory: space.path + "/drive_c/Games/Some Game")
        }
    }

    @Test func aSpaceWithItsDesktopAndAGameIsNotARunaway() {
        let load = WineProcesses.load(of: steam, from: explorers(2, in: steam) + programs(30, in: steam))
        #expect(load.explorers == 2 && load.programs == 32)
        #expect(!load.isRunaway && !load.isGrowing)
    }

    @Test func moreThanTwelveExplorersIsARunaway() {
        #expect(!WineProcesses.load(of: steam, from: explorers(SpaceLoad.maxExplorers, in: steam)).isRunaway)
        let load = WineProcesses.load(of: steam, from: explorers(SpaceLoad.maxExplorers + 1, in: steam))
        #expect(load.isRunaway && load.explorers == 13)
    }

    @Test func moreThanTwoHundredProgramsInTotalIsARunaway() {
        #expect(!WineProcesses.load(of: steam, from: programs(SpaceLoad.maxPrograms, in: steam)).isRunaway)
        #expect(WineProcesses.load(of: steam, from: programs(SpaceLoad.maxPrograms + 1, in: steam)).isRunaway)
        // Explorers count towards the total too.
        #expect(WineProcesses.load(of: steam, from: explorers(10, in: steam) + programs(195, in: steam)).isRunaway)
    }

    @Test func programsThatLostTheirParentAreCountedByWhereTheyWork() {
        // No WINEPREFIX, no drive_c in the command: the working folder is all that links them to the space.
        let orphans = explorers(40, in: steam)
        #expect(orphans.allSatisfy { $0.prefix == nil && !$0.command.contains("drive_c") })
        #expect(WineProcesses.load(of: steam, from: orphans).isRunaway)
        // The ones G-Player started show WINEPREFIX, wherever they work; a program is counted once, not per rule.
        let started = (0..<13).map { WineProcess(pid: 9000 + Int32($0), command: "/Users/me/Bottles/Steam/drive_c/windows/system32/explorer.exe",
                                               directory: "/", prefix: "/Users/me/Bottles/Steam") }
        #expect(WineProcesses.load(of: steam, from: started).isRunaway)
        #expect(WineProcesses.load(of: steam, from: started + started).programs == 13)
    }

    @Test func theRealProcessTableSeesAProgramThatLostItsParent() throws {
        // A stand-in for a Wine program (a shell whose command line names a .exe), started so that its parent is gone:
        // the shell that starts it quits at once and the launch daemon becomes its parent. No Wine involved.
        let tmp = TempFolder()
        let folder = tmp.dir("Space/drive_c/windows/system32")
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", #"sh -c 'sleep 8; true # C:\gplayer-orphan-test.exe' >/dev/null 2>&1 & echo $!"#]
        sh.currentDirectoryURL = folder
        let out = Pipe()
        sh.standardOutput = out
        try sh.run()
        let pid = try #require(Int32(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        sh.waitUntilExit()

        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "ppid=", "-p", "\(pid)"]
        let parent = Pipe()
        ps.standardOutput = parent
        try ps.run()
        #expect(String(decoding: parent.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1")

        let owner = space(at: tmp.url.appendingPathComponent("Space"))
        var mine: [WineProcess] = []
        for _ in 0..<30 where mine.isEmpty {
            mine = WineProcesses.programs(in: owner, from: WineProcesses.snapshot()).filter { $0.pid == pid }
            if mine.isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        }
        #expect(mine.count == 1)
        #expect(mine.first?.prefix == nil)                          // no WINEPREFIX: only its working folder says whose it is
        #expect(WineProcesses.load(of: owner, from: WineProcesses.snapshot()).processes.contains { $0.pid == pid })
    }

    @Test func anotherSpacesProgramsDontCount() {
        let all = explorers(30, in: steam2) + explorers(2, in: steam)
        #expect(WineProcesses.load(of: steam, from: all).explorers == 2)          // "Steam" is not "Steam 2"
        #expect(!WineProcesses.load(of: steam, from: all).isRunaway)
        #expect(WineProcesses.load(of: steam2, from: all).isRunaway)
    }

    @Test func programsOfGamesKeptOutsideTheSpaceCountWhenTheCallerFoundThem() {
        // A game's Explorer copies work in the game's folder, outside the prefix: only the caller knows that folder.
        let outside = (0..<20).map { WineProcess(pid: 7000 + Int32($0), command: #"C:\windows\system32\explorer.exe /desktop"#,
                                              directory: "/Users/me/Games/Indie-game") }
        #expect(!WineProcesses.load(of: steam, from: outside).isRunaway)
        #expect(WineProcesses.load(of: steam, from: outside, alsoAttributed: outside).isRunaway)
    }

    @Test func halfTheLimitIsWorthWatchingClosely() {
        #expect(WineProcesses.load(of: steam, from: explorers(7, in: steam)).isGrowing)
        #expect(!WineProcesses.load(of: steam, from: explorers(6, in: steam)).isGrowing)
        #expect(WineProcesses.load(of: steam, from: programs(101, in: steam)).isGrowing)
    }

    @Test func theMessageSaysWhatHappenedAndWhatCausesIt() {
        let load = WineProcesses.load(of: steam, from: explorers(2310, in: steam))
        let text = load.message(spaceName: "Main")
        #expect(text.contains("“Main”") && text.contains("2310 Windows programs") && text.contains("2310 of them Windows Explorer"))
        #expect(text.contains("stopped everything") && text.contains("keep your Mac usable"))
        #expect(text.contains("under \(PrefixPath.maxLength) characters"))
        // Too many programs of other kinds: no word about Explorer.
        let many = WineProcesses.load(of: steam, from: programs(230, in: steam)).message(spaceName: "Main")
        #expect(many.contains("230 Windows programs") && !many.contains("Explorer"))
    }
}
