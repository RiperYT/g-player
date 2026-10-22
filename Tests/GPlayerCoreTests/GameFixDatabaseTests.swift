import Foundation
import Testing
@testable import GPlayerCore

@Suite struct GameFixDatabaseTests {
    // MARK: Bundled data

    @Test func bundledDatabaseHasTheImportedFixes() {
        let fixes = GameFixDatabase.bundled.fixes
        #expect(fixes.count > 100)
        #expect(Set(fixes.map(\.id)).count == fixes.count)
        for fix in fixes where fix.source.hasPrefix("umu-protonfixes@") {
            #expect(fix.id == "steam-" + (fix.steamAppIDs.first ?? "?"))
            #expect(fix.verifiedOnMac == false)
            #expect(fix.macStatus == nil)
        }
        // Nothing that only works on Linux or Proton made it in.
        for fix in fixes {
            #expect(!fix.environment.keys.contains { $0.uppercased().hasPrefix("PROTON_") || $0.uppercased().hasPrefix("VKD3D") })
            #expect(!fix.components.contains { $0 == "gui" || $0.hasPrefix("sound=") })
        }
    }

    @Test func curatedOvercookedWins() throws {
        let matches = GameFixDatabase.bundled.fixes(steamAppID: "448510", exeName: nil)
        let overcooked = try #require(matches.first)
        #expect(matches.count == 1)
        #expect(overcooked.id == "gplayer-overcooked")
        #expect(overcooked.macStatus == .issues)          // reaches its menu; gameplay not checked
        #expect(overcooked.verifiedOnMac)
        #expect(overcooked.source == "g-player")
        #expect(overcooked.notes?.contains("32-bit Unity 5.5") == true)
        #expect(GameFixDatabase.bundled.fix(id: "gplayer-overcooked") == overcooked)
    }

    // MARK: Lookups

    private let database = GameFixDatabase(fixes: [
        GameFix(id: "steam-1", steamAppIDs: ["1"], components: ["vcrun2019"], source: "test"),
        GameFix(id: "both", steamAppIDs: ["1", "2"], exeNames: ["Game.EXE"], source: "test"),
        GameFix(id: "exe-only", exeNames: ["launcher.exe", "game.exe"], source: "test"),
        GameFix(id: "steam-1", steamAppIDs: ["3"], source: "duplicate id"),
    ])

    @Test func findsFixesBySteamAppID() {
        #expect(database.fixes(steamAppID: "1", exeName: nil).map(\.id) == ["steam-1", "both"])
        #expect(database.fixes(steamAppID: "2", exeName: nil).map(\.id) == ["both"])
        #expect(database.fixes(steamAppID: "99", exeName: nil).isEmpty)
    }

    @Test func findsFixesByExeNameIgnoringCaseAndFolders() {
        #expect(database.fixes(steamAppID: nil, exeName: "GAME.exe").map(\.id) == ["both", "exe-only"])
        #expect(database.fixes(steamAppID: nil, exeName: "/Games/Some Game/Launcher.exe").map(\.id) == ["exe-only"])
        #expect(database.fixes(steamAppID: nil, exeName: "C:\\Games\\game.exe").map(\.id) == ["both", "exe-only"])
        #expect(database.fixes(steamAppID: nil, exeName: "other.exe").isEmpty)
    }

    @Test func steamMatchesComeFirstAndEachFixOnce() {
        #expect(database.fixes(steamAppID: "2", exeName: "game.exe").map(\.id) == ["both", "exe-only"])
        #expect(database.fixes(steamAppID: "1", exeName: "game.exe").map(\.id) == ["steam-1", "both", "exe-only"])
    }

    @Test func nothingToMatchGivesNothing() {
        #expect(database.fixes(steamAppID: nil, exeName: nil).isEmpty)
        #expect(database.fixes(steamAppID: nil, exeName: "").isEmpty)
        #expect(GameFixDatabase().fixes(steamAppID: "1", exeName: "game.exe").isEmpty)
    }

    @Test func findsFixByIDAndFirstOfADuplicateWins() {
        #expect(database.fix(id: "exe-only")?.exeNames == ["launcher.exe", "game.exe"])
        #expect(database.fix(id: "steam-1")?.source == "test")
        #expect(database.fix(id: "nope") == nil)
        #expect(database.fixes(steamAppID: "3", exeName: nil).isEmpty)
    }

    @Test func lookupsFollowChangesToFixes() {
        var db = GameFixDatabase()
        db.fixes = [GameFix(id: "late", steamAppIDs: ["7"], source: "test")]
        #expect(db.fixes(steamAppID: "7", exeName: nil).map(\.id) == ["late"])
        #expect(db.fix(id: "late") != nil)
    }

    // MARK: Files

    @Test func decodesEveryFieldAsTheImporterWritesIt() throws {
        let tmp = TempFolder()
        let url = tmp.file("fixes.json", contents: Data("""
        {
          "version": 1,
          "sources": [{"name": "umu-protonfixes", "commit": "f494092", "license": "BSD-2-Clause"}],
          "fixes": [{
            "id": "steam-9", "title": "Nine", "steamAppIDs": ["9"], "exeNames": ["nine.exe"],
            "components": ["vcrun2019", "d3dcompiler_47"],
            "dllOverrides": {"dinput8": "n,b", "*dsound": "b"},
            "environment": {"DXVK_HUD": "0"}, "arguments": ["-dx11"],
            "replacements": [{"from": "Launcher.exe", "to": "Game.exe"}],
            "registry": [{"key": "HKCU\\\\Software\\\\Nine", "name": "Mode", "type": "REG_DWORD", "value": "1"}],
            "notes": "Needs a restart.", "source": "umu-protonfixes@f494092", "verifiedOnMac": true, "macStatus": "issues"
          }]
        }
        """.utf8))
        let fix = try #require(try GameFixDatabase.load(from: url).fix(id: "steam-9"))
        #expect(fix.title == "Nine")
        #expect(fix.components == ["vcrun2019", "d3dcompiler_47"])
        #expect(fix.dllOverrides == ["dinput8": .nativeThenBuiltin, "*dsound": .builtin])
        #expect(fix.environment == ["DXVK_HUD": "0"])
        #expect(fix.arguments == ["-dx11"])
        #expect(fix.replacements == [ArgumentReplacement(from: "Launcher.exe", to: "Game.exe")])
        #expect(fix.registry == [RegistryValue(key: "HKCU\\Software\\Nine", name: "Mode", type: "REG_DWORD", value: "1")])
        #expect(fix.notes == "Needs a restart.")
        #expect(fix.verifiedOnMac)
        #expect(fix.macStatus == .issues)
    }

    @Test func decodesEveryDLLOverrideMode() throws {
        let json = #"{"a": "n", "b": "b", "c": "n,b", "d": "b,n", "e": ""}"#
        let modes = try JSONDecoder().decode([String: DLLOverrideMode].self, from: Data(json.utf8))
        #expect(modes == ["a": .native, "b": .builtin, "c": .nativeThenBuiltin, "d": .builtinThenNative, "e": .disabled])
        #expect(Set(modes.values) == Set(DLLOverrideMode.allCases))
        for mode in DLLOverrideMode.allCases {
            let again = try JSONDecoder().decode([String: DLLOverrideMode].self,
                                                 from: JSONEncoder().encode(["x": mode]))
            #expect(again == ["x": mode])
        }
    }

    @Test func malformedFilesThrow() throws {
        let tmp = TempFolder()
        let cut = tmp.file("cut.json", contents: Data(#"{"version": 1, "fixes": ["#.utf8))
        let wrongShape = tmp.file("shape.json", contents: Data(#"{"version": 1, "fixes": [{"id": "x"}]}"#.utf8))
        let notJSON = tmp.file("text.json", contents: Data("not json".utf8))
        let badMode = tmp.file("mode.json", contents: Data("""
        {"version": 1, "fixes": [{"id": "x", "steamAppIDs": [], "exeNames": [], "components": [],
         "dllOverrides": {"d3d9": "native"}, "environment": {}, "arguments": [], "replacements": [],
         "registry": [], "source": "t", "verifiedOnMac": false}]}
        """.utf8))
        for url in [cut, wrongShape, notJSON, badMode, tmp.url.appendingPathComponent("missing.json")] {
            #expect(throws: (any Error).self) { try GameFixDatabase.load(from: url) }
        }
    }

    @Test func unknownVersionThrows() throws {
        let tmp = TempFolder()
        let url = tmp.file("v2.json", contents: Data(#"{"version": 2, "fixes": []}"#.utf8))
        #expect(throws: GameFixDatabase.LoadError.unsupportedVersion(2)) { try GameFixDatabase.load(from: url) }
    }
}
