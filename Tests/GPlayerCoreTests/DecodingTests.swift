import Foundation
import Testing
@testable import GPlayerCore

// A field added, changed or damaged must never stop a whole library.json from loading.

@Suite struct DecodingSafetyTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func anEmptyObjectDecodesToTheDefaults() throws {
        let analysis = try decode(GameAnalysis.self, "{}")
        #expect(analysis == GameAnalysis())
        #expect(analysis.programPath == nil && analysis.version == nil)
        #expect(analysis.antiCheat.isEmpty && analysis.graphics.isEmpty && !analysis.isDotNet)
        let options = try decode(LaunchOptions.self, "{}")
        #expect(options == LaunchOptions.default)
        #expect(options.profile == .recommended && options.windowMode == .automatic && options.useKnownFixes)
    }

    @Test func fieldsThatAreThereAreKeptAndUnknownOnesIgnored() throws {
        let analysis = try decode(GameAnalysis.self, """
            {"engine": "unity", "engineName": "Unity", "graphics": ["d3d11"], "architecture": "x64", "isDotNet": true,
             "programPath": "/g/Game.exe", "version": 1, "somethingNew": {"a": [1, 2]}}
            """)
        #expect(analysis.engine == .unity && analysis.engineName == "Unity" && analysis.graphics == [.d3d11])
        #expect(analysis.architecture == .x64 && analysis.isDotNet)
        #expect(analysis.programPath == "/g/Game.exe" && analysis.version == 1)
        let options = try decode(LaunchOptions.self, #"{"profile": "compatible", "retina": true, "disabledFixIDs": ["a"], "later": 1}"#)
        #expect(options.profile == .compatible && options.retina && options.disabledFixIDs == ["a"])
        #expect(options.windowMode == .automatic)
    }

    @Test func aValueThisVersionDoesNotUnderstandFallsBackWithoutSpoilingTheRest() throws {
        // A newer G-Player added an engine, a profile and a graphics API; a damaged file has the wrong type.
        let analysis = try decode(GameAnalysis.self, """
            {"engine": "cryengine9", "graphics": ["d3d11", "d3d99"], "antiCheat": ["EasyAntiCheat"], "isDotNet": "yes", "version": 7}
            """)
        #expect(analysis.engine == nil)
        #expect(analysis.graphics.isEmpty)
        #expect(analysis.antiCheat == ["EasyAntiCheat"])
        #expect(!analysis.isDotNet)
        #expect(analysis.version == 7)
        let options = try decode(LaunchOptions.self, #"{"profile": "turbo", "windowMode": 3, "retina": true}"#)
        #expect(options.profile == .recommended && options.windowMode == .automatic && options.retina)
    }

    @Test func aLibraryWithOldOrOddGamesStillLoads() throws {
        let tmp = TempFolder()
        let store = LibraryStore(paths: LibraryPaths(root: tmp.url))
        var state = LibraryState()
        let s = Space(name: "Main", path: "/x", engineID: "e", origin: .managed)
        state.spaces = [s]
        state.games = [Game(title: "A", spaceID: s.id), Game(title: "B", spaceID: s.id)]
        try store.save(state)

        // Game A: analysis and options written by an older version (nearly empty); game B: by one with unknown values.
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.libraryFile)) as? [String: Any])
        var games = try #require(root["games"] as? [[String: Any]])
        games[0]["analysis"] = ["engine": "unity"]
        games[0]["options"] = ["profile": "fast"]
        games[1]["analysis"] = ["engine": "unreal5", "graphics": ["vulkan3"], "isDotNet": 3]
        games[1]["options"] = ["profile": "ludicrous", "windowMode": "sideways"]
        root["games"] = games
        try JSONSerialization.data(withJSONObject: root).write(to: store.paths.libraryFile)

        let loaded = try store.load()
        #expect(loaded.games.count == 2)
        #expect(loaded.games[0].analysis?.engine == .unity && loaded.games[0].analysis?.version == nil)
        #expect(loaded.games[0].launchOptions.profile == .fast)
        #expect(loaded.games[1].analysis == GameAnalysis())
        #expect(loaded.games[1].launchOptions == LaunchOptions.default)
    }

    @Test func theAnalyzerSaysWhichProgramItReadAndWhichVersionItIs() throws {
        #expect(GameAnalysis.currentVersion == 3)          // 3: components from imports
        let tmp = TempFolder()
        let exe = tmp.file("Game/Game.exe", contents: try Data(contentsOf: fixture("D3D11Fixture.exe")))
        let analysis = GameAnalyzer.analyze(executable: exe)
        #expect(analysis.programPath == exe.standardizedFileURL.path)
        #expect(analysis.programPath?.hasPrefix("/") == true)
        #expect(analysis.version == GameAnalysis.currentVersion)
        // And both survive the library file.
        let again = try JSONDecoder().decode(GameAnalysis.self, from: JSONEncoder().encode(analysis))
        #expect(again == analysis)
    }
}

@Suite struct SpaceConsentTests {
    private let json = """
        {"id": "6E9B2A4C-1D3F-4E5A-8B7C-9D0E1F2A3B4C", "name": "Steam", "path": "/b/Steam", "engineID": "wine-staging-11.18",
         "origin": "external", "colorIndex": 0, "createdAt": 0}
        """

    @Test func aSpaceFromBeforeConsentHasNoAnswerAndMayNotBeChanged() throws {
        let space = try JSONDecoder().decode(Space.self, from: Data(json.utf8))
        #expect(space.allowsChanges == nil)
        #expect(!space.mayChange)
    }

    @Test func onlyAnExternalSpaceTheUserAllowedMayBeChanged() {
        var external = Space(name: "Bottle", path: "/b", engineID: "x", origin: .external)
        #expect(!external.mayChange)
        external.allowsChanges = false
        #expect(!external.mayChange)
        external.allowsChanges = true
        #expect(external.mayChange)
        #expect(Space(name: "Main", path: "/m", engineID: "x", origin: .managed).mayChange)
    }

    @Test func theAnswerSurvivesARoundTrip() throws {
        var space = Space(name: "Bottle", path: "/b", engineID: "x", origin: .external)
        space.allowsChanges = false
        let back = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space))
        #expect(back.allowsChanges == false)
    }
}
