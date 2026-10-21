import Foundation
import Testing
@testable import GPlayerCore

@Suite struct VDFTests {
    @Test func parsesNestedObjectsCommentsAndEscapes() throws {
        let text = """
        "libraryfolders"
        {
            // a comment
            "0"
            {
                "path"      "C:\\\\Program Files (x86)\\\\Steam"
                "apps" { "620" "123" }
            }
        }
        """
        let root = try VDF.parse(text)
        #expect(root["LibraryFolders"]?["0"]?["path"]?.string == #"C:\Program Files (x86)\Steam"#)
        #expect(root["libraryfolders"]?["0"]?["apps"]?["620"]?.string == "123")
    }

    @Test func rejectsUnbalancedBraces() {
        #expect(throws: (any Error).self) { try VDF.parse(#""a" { "b" "c""#) }
    }

    @Test func steamManifestBecomesAGame() {
        let acf = """
        "AppState" { "appid" "448510" "name" "Overcooked" "StateFlags" "4" "installdir" "Overcooked" }
        """
        let g = SteamLibrary.parseManifest(acf, steamapps: URL(fileURLWithPath: "/x/steamapps"))
        #expect(g?.title == "Overcooked")
        #expect(g?.installed == true)
        #expect(g?.source == .steam(appID: "448510"))
        #expect(g?.installFolder?.path == "/x/steamapps/common/Overcooked")
    }

    @Test func steamToolsAreSkipped() {
        let acf = #""AppState" { "appid" "228980" "name" "Steamworks Common Redistributables" "StateFlags" "4" }"#
        #expect(SteamLibrary.parseManifest(acf, steamapps: URL(fileURLWithPath: "/x")) == nil)
    }
}

@Suite struct ShellLinkTests {
    @Test func readsAWineMadeShortcut() throws {
        let link = try #require(ShellLink.parse(Data(contentsOf: fixture("Steam.lnk"))))
        #expect(link.localBasePath == #"C:\Program Files (x86)\Steam\steam.exe"#)
    }

    @Test func mapsTheTargetIntoTheSpace() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("S"))
        let menu = tmp.dir("S/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Steam")
        try FileManager.default.copyItem(at: fixture("Steam.lnk"), to: menu.appendingPathComponent("Steam.lnk"))
        tmp.file("S/drive_c/Program Files (x86)/Steam/steam.exe", bytes: 1000)
        let programs = ShortcutScanner.programs(in: s)
        #expect(programs.map(\.name) == ["Steam"])
        #expect(programs.first?.target?.path == s.driveC.appendingPathComponent("Program Files (x86)/Steam/steam.exe").path)
    }

    @Test func garbageIsNotAShortcut() {
        #expect(ShellLink.parse(Data("hello".utf8)) == nil)
    }
}

@Suite struct SpacePathTests {
    @Test func windowsAndMacPathsRoundTrip() {
        let s = Space(name: "Main", path: "/tmp/Main", engineID: "x", origin: .managed)
        let mac = s.macURL(forWindowsPath: #"C:\Games\Hollow\hollow.exe"#)
        #expect(mac?.path == "/tmp/Main/drive_c/Games/Hollow/hollow.exe")
        #expect(s.windowsPath(for: mac!) == #"C:\Games\Hollow\hollow.exe"#)
        #expect(s.macURL(forWindowsPath: #"Z:\Users\a\x.exe"#)?.path == "/Users/a/x.exe")
        #expect(s.windowsPath(for: URL(fileURLWithPath: "/Users/a/x.exe")) == #"Z:\Users\a\x.exe"#)
    }

    @Test func gamePathsAreStoredRelativeToTheSpace() {
        let s = Space(name: "Main", path: "/tmp/Main", engineID: "x", origin: .managed)
        #expect(Game.storedPath(for: URL(fileURLWithPath: "/tmp/Main/drive_c/Games/a.exe"), in: s) == "drive_c/Games/a.exe")
        #expect(Game.storedPath(for: URL(fileURLWithPath: "/Users/a/b.exe"), in: s) == "/Users/a/b.exe")
        let g = Game(title: "A", spaceID: s.id, executablePath: "drive_c/Games/a.exe")
        #expect(g.executableURL(in: s)?.path == "/tmp/Main/drive_c/Games/a.exe")
    }
}
