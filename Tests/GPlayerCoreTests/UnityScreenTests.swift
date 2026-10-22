import CoreGraphics
import Foundation
import Testing
@testable import GPlayerCore

@Suite struct UnityScreenTests {
    /// Wine's user.reg as a Unity game leaves it after a start that failed (made-up values).
    func userReg(width: String, height: String, fullscreen: String = "dword:00000001",
                 key: String = #"Software\\Example Studio\\Example Game"#) -> String {
        """
        WINE REGISTRY Version 2
        ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

        [Software\\\\Example Studio] 1700000000
        #time=1d0000000000000

        [\(key)] 1700000000
        #time=1d0000000000000
        "Screenmanager Is Fullscreen mode_h3981298716"=\(fullscreen)
        "Screenmanager Resolution Height Default_h1380706816"=dword:00000300
        "Screenmanager Resolution Height_h2627697771"=\(height)
        "Screenmanager Resolution Width Default_h680557497"=dword:00000400
        "Screenmanager Resolution Width_h182942802"=\(width)
        "unity.player_session_count_h922449978"=hex:31,00,\\
          32,00

        [Software\\\\Example Studio\\\\Example Game\\\\Unity\\\\UnityGraphicsQuality] 1700000000
        "Screenmanager Resolution Width_h182942802"=dword:00000780

        """
    }
    let zero = "dword:00000000"

    func isEmpty(_ reg: String, _ company: String = "Example Studio", _ product: String = "Example Game") -> Bool {
        let s = UnityScreen.savedSettings(userReg: reg, company: company, product: product)
        return s["Screenmanager Resolution Width"] == zero && s["Screenmanager Resolution Height"] == zero
    }

    @Test func aSavedSizeOfZeroIsFound() {
        #expect(isEmpty(userReg(width: zero, height: zero)))
        #expect(isEmpty(userReg(width: zero, height: zero), "example studio", "EXAMPLE GAME"))
        #expect(!isEmpty(userReg(width: "dword:00000500", height: "dword:00000320")))
        // Only the width at 0 is a size the game chose on purpose.
        #expect(!isEmpty(userReg(width: zero, height: "dword:00000320")))
        // Another game's key, a subkey, or no settings at all.
        #expect(!isEmpty(userReg(width: zero, height: zero), "Example Studio", "Example Game Demo"))
        #expect(!isEmpty("WINE REGISTRY Version 2\n"))
        let s = UnityScreen.savedSettings(userReg: userReg(width: zero, height: zero), company: "Example Studio", product: "Example Game")
        #expect(s["Screenmanager Resolution Width Default"] == "dword:00000400")       // a different name, kept apart
    }

    @Test func keyNamesAreEscapedLikeWine() {
        #expect(UnityScreen.escapedKeyPart("Example Studio") == "Example Studio")
        #expect(UnityScreen.escapedKeyPart(#"A\B]C"#) == #"A\\B\]C"#)
        #expect(UnityScreen.escapedKeyPart("Studio [Beta]") == #"Studio \[Beta\]"#)
        #expect(UnityScreen.escapedKeyPart("Ігри") == #"\x406\x433\x440\x438"#)
        #expect(UnityScreen.escapedKeyPart("Café 2") == #"Caf\xe9 2"#)
        #expect(UnityScreen.escapedKeyPart("Ä1") == #"\x00c41"#)              // four digits when a hex digit follows
        #expect(UnityScreen.escapedKeyPart("a\tb") == nil)
        #expect(isEmpty(userReg(width: zero, height: zero, key: #"Software\\\x406\x433\x440\x438\\Game"#), "Ігри", "Game"))
        #expect(isEmpty(userReg(width: zero, height: zero, key: #"Software\\Studio \[Beta\]\\Game"#), "Studio [Beta]", "Game"))
    }

    @Test func appInfoNamesTheKey() {
        let tmp = TempFolder()
        let exe = tmp.file("Game/Example.exe")
        #expect(UnityScreen.appInfo(forProgram: exe) == nil)
        tmp.file("Game/Example_Data/app.info", contents: Data("Example Studio\r\nExample Game".utf8))
        #expect(UnityScreen.appInfo(forProgram: exe)?.company == "Example Studio")
        #expect(UnityScreen.appInfo(forProgram: exe)?.product == "Example Game")
        tmp.file("Game/Example_Data/app.info", contents: Data("Example Studio\n".utf8))
        #expect(UnityScreen.appInfo(forProgram: exe) == nil)
    }

    /// A Unity game added by hand in a space whose settings hold `reg`, if any.
    func setUp(_ tmp: TempFolder, reg: String?) -> (Space, Game) {
        let s = space(at: tmp.prefix("Main"))
        let exe = tmp.file("Main/drive_c/Games/Example/Example.exe")
        tmp.file("Main/drive_c/Games/Example/Example_Data/app.info", contents: Data("Example Studio\nExample Game".utf8))
        if let reg { tmp.file("Main/user.reg", contents: Data(reg.utf8)) }
        var g = Game(title: "Example", spaceID: s.id, executablePath: "drive_c/Games/Example/Example.exe")
        g.analysis = GameAnalysis(engineName: "Unity", engine: .unity, graphics: [.d3d11], architecture: .x86, programPath: exe.path)
        return (s, g)
    }
    let screen = CGSize(width: 1800, height: 1169)

    @Test func theLaunchPassesTheScreenSizeOnlyWhenTheSavedOneIsZero() throws {
        let tmp = TempFolder()
        let (s, g) = setUp(tmp, reg: userReg(width: zero, height: zero))
        #expect(try LaunchPlanner.plan(for: g, in: s, screen: screen).arguments.suffix(4)
                == ["-screen-width", "1800", "-screen-height", "1169"])

        tmp.file("Main/user.reg", contents: Data(userReg(width: "dword:00000500", height: "dword:00000320").utf8))
        #expect(!(try LaunchPlanner.plan(for: g, in: s, screen: screen).arguments.contains("-screen-width")))

        try FileManager.default.removeItem(at: s.url.appendingPathComponent("user.reg"))
        #expect(!(try LaunchPlanner.plan(for: g, in: s, screen: screen).arguments.contains("-screen-width")))
    }

    @Test func aWindowGetsMostOfTheScreen() throws {
        let tmp = TempFolder()
        // Saved as windowed.
        let (s, g) = setUp(tmp, reg: userReg(width: zero, height: zero, fullscreen: zero))
        #expect(try LaunchPlanner.plan(for: g, in: s, screen: screen).arguments.suffix(4)
                == ["-screen-width", "1440", "-screen-height", "934"])
        // Asked for on the command line, whatever was saved.
        var windowed = g
        windowed.options = LaunchOptions(windowMode: .windowed)
        tmp.file("Main/user.reg", contents: Data(userReg(width: zero, height: zero).utf8))
        let args = try LaunchPlanner.plan(for: windowed, in: s, screen: screen).arguments
        #expect(args.contains("-screen-fullscreen") && args.suffix(4) == ["-screen-width", "1440", "-screen-height", "934"])
    }

    @Test func theUsersOwnSizeWins() throws {
        let tmp = TempFolder()
        let (s, base) = setUp(tmp, reg: userReg(width: zero, height: zero))
        var g = base
        g.arguments = ["-screen-width", "1280"]
        let args = try LaunchPlanner.plan(for: g, in: s, screen: screen).arguments
        #expect(args.filter { $0 == "-screen-width" }.count == 1)
        #expect(args.suffix(4) == ["-screen-height", "1169", "-screen-width", "1280"])
    }

    @Test func steamGamesAreFoundByTheAnalysedProgram() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Steam"), preset: "steam")
        tmp.file("Steam/drive_c/Program Files (x86)/Steam/steam.exe")
        let exe = tmp.file("Steam/drive_c/Program Files (x86)/Steam/steamapps/common/Example/Example.exe")
        tmp.file("Steam/drive_c/Program Files (x86)/Steam/steamapps/common/Example/Example_Data/app.info",
                 contents: Data("Example Studio\nExample Game".utf8))
        tmp.file("Steam/user.reg", contents: Data(userReg(width: zero, height: zero).utf8))
        var g = Game(title: "Example", spaceID: s.id, source: .steam(appID: "1"))
        g.analysis = GameAnalysis(engine: .unity, graphics: [.d3d11], architecture: .x86, programPath: exe.path)
        let args = try LaunchPlanner.plan(for: g, in: s, screen: screen).arguments
        #expect(args.suffix(6) == ["-applaunch", "1", "-screen-width", "1800", "-screen-height", "1169"])

        // Not a Unity game, or the launcher itself: nothing added.
        g.analysis?.engine = .unreal
        #expect(!(try LaunchPlanner.plan(for: g, in: s, screen: screen).arguments.contains("-screen-width")))
        var launcher = Game(title: "Steam", kind: .app, spaceID: s.id, executablePath: "drive_c/Program Files (x86)/Steam/steam.exe")
        launcher.analysis = GameAnalysis(engine: .unity, programPath: exe.path)
        #expect(!(try LaunchPlanner.plan(for: launcher, in: s, screen: screen).arguments.contains("-screen-width")))
    }

    @Test func optionsTheUserSetsAreDroppedWithTheirValues() {
        #expect(LaunchPlanner.dropping(["-screen-fullscreen", "0", "-force-d3d11"], setIn: ["-adapter", "0"])
                == ["-screen-fullscreen", "0", "-force-d3d11"])
        #expect(LaunchPlanner.dropping(["-screen-fullscreen", "0", "-force-d3d11"], setIn: ["-screen-fullscreen", "1"])
                == ["-force-d3d11"])
        #expect(LaunchPlanner.dropping(["+com_skipIntro", "1", "-dx11"], setIn: ["-dx11"]) == ["+com_skipIntro", "1"])
    }
}
