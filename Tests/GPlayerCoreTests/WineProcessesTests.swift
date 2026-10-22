import Foundation
import Testing
@testable import GPlayerCore

/// Telling which space, and which game, a Windows program belongs to.
@Suite struct WineProcessesTests {
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
