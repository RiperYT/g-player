import Foundation
import Testing
@testable import GPlayerCore

// A library file written by another version of G-Player: a game this one can't read is kept and left alone (never a reason to
// refuse the whole library), and the library as it was is kept before the first Epic game goes in.

private func decode(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }

/// The same each time it is made (an id comes from the name, a date is fixed), so two libraries can be compared.
private func fixedID(_ name: String) -> UUID {
    var bytes = Array(name.utf8.prefix(16))
    bytes += [UInt8](repeating: 0, count: 16 - bytes.count)
    return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
}

private let mainSpace = Space(id: fixedID("Main"), name: "Main", path: "/x", engineID: "e", origin: .managed,
                              createdAt: Date(timeIntervalSince1970: 1_700_000_000))

private func fixedGame(_ title: String, source: Game.Source = .executable) -> Game {
    Game(id: fixedID(title), title: title, spaceID: mainSpace.id, source: source, addedAt: Date(timeIntervalSince1970: 1_700_000_000))
}

@Suite struct JSONValueTests {
    @Test func everyKindOfValueComesBackTheSame() throws {
        let json = #"{"a": [1, -2, 9007199254740993, 1.5, true, false, null, "text é é \n"], "b": {"c": {}, "d": []}, "e": 0, "f": 1e3}"#
        let value = try decode(json)
        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(value == again)
        guard case .object(let object) = value, case .array(let items)? = object["a"] else { Issue.record("shape"); return }
        #expect(items[2] == .int(9_007_199_254_740_993))                      // a big whole number loses nothing
        #expect(items[3] == .double(1.5) && items[4] == .bool(true) && items[6] == .null)
        #expect(items[7] == .string("text é é \n"))
    }

    @Test func aBareValueIsAValue() throws {
        #expect(try decode("42") == .int(42))
        #expect(try decode(#""x""#) == .string("x"))
        #expect(try decode("null") == .null)
        #expect(try decode("[]") == .array([]))
    }
}

@Suite struct UnreadableGamesTests {
    let tmp = TempFolder()
    var store: LibraryStore { LibraryStore(paths: LibraryPaths(root: tmp.url)) }

    /// A library file with the games given as JSON text, next to one that this version writes itself.
    private func write(_ games: [String]) throws -> UUID {
        var state = LibraryState()
        state.spaces = [mainSpace]
        state.games = [fixedGame("Mine")]
        try store.save(state)
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.libraryFile)) as? [String: Any])
        var list = try #require(root["games"] as? [Any])
        for game in games { list.append(try JSONSerialization.jsonObject(with: Data(game.utf8), options: .fragmentsAllowed)) }
        root["games"] = list
        try JSONSerialization.data(withJSONObject: root).write(to: store.paths.libraryFile)
        return mainSpace.id
    }

    private func games(in data: Data) throws -> [Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["games"] as? [Any])
    }

    private func same(_ a: Any, _ b: Any) -> Bool { (a as AnyObject).isEqual(b) }

    /// A game from a newer version: a source this one doesn't have, and a field it doesn't know.
    private func futureGame(_ space: UUID) -> String {
        """
        {"id": "6E3B8B4E-7C1F-4B1B-9D1E-0A1B2C3D4E5F", "title": "From The Future", "kind": "game", "spaceID": "\(space.uuidString)",
         "source": {"gog": {"productID": "123", "extra": [1, 2, {"x": null}]}}, "arguments": ["-a"], "graphics": "auto",
         "environment": {"K": "V"}, "addedAt": "2026-10-23T10:00:00.000Z", "secondsPlayed": 12.5, "newField": {"deep": [true, 1.25]}}
        """
    }

    @Test func aGameWithASourceThisVersionDoesNotKnowDoesNotBreakTheLibrary() throws {
        let space = try write([futureGame(UUID())])
        let loaded = try store.load()
        #expect(loaded.games.map(\.title) == ["Mine"])                         // the other game, and not the unknown one
        #expect(loaded.unreadableGames.count == 1)
        #expect(loaded.spaces.map(\.id) == [space])
        guard case .opened(let state) = open() else { Issue.record("blocked"); return }
        #expect(state.games.map(\.title) == ["Mine"])
    }

    private enum Opened { case opened(LibraryState), blocked(LibraryProblem) }
    private func open() -> Opened {
        switch store.open(expectingLibrary: true) {
        case .ready(let state): .opened(state)
        case .blocked(let problem): .blocked(problem)
        }
    }

    @Test func itIsLeftOutOfWhatIsShownAndUsed() throws {
        _ = try write([futureGame(UUID())])
        let loaded = try store.load()
        #expect(loaded.visibleGames.map(\.title) == ["Mine"] && loaded.hiddenGames.isEmpty)
        #expect(loaded.games.allSatisfy { $0.title != "From The Future" })
    }

    @Test func itIsWrittenBackWithTheSameContentOnEverySave() throws {
        let original = futureGame(UUID())
        _ = try write([original])
        var loaded = try store.load()
        loaded.games[0].title = "Renamed"                                       // the library changes, and is saved, twice
        try store.save(loaded)
        try store.save(try store.load())
        let list = try games(in: Data(contentsOf: store.paths.libraryFile))
        #expect(list.count == 2)
        let expected = try JSONSerialization.jsonObject(with: Data(original.utf8))
        #expect(list.contains { same($0, expected) })                           // equal key by key, number by number
        #expect(try store.load().games.map(\.title) == ["Renamed"])
    }

    @Test func itSurvivesTheOtherThingsThatChangeALibrary() throws {
        _ = try write([futureGame(UUID())])
        var state = try store.load()
        state = state.movingLibrary(from: URL(fileURLWithPath: "/old"), to: URL(fileURLWithPath: "/new"))
        #expect(state.unreadableGames.count == 1)
        state.hiddenStoreKeys.insert("steam:1")
        state.games.removeAll()
        try store.save(state)
        #expect(try store.load().unreadableGames.count == 1)
    }

    @Test func aGameThatIsReadableOtherwiseButHasOneBadFieldIsKeptToo() throws {
        let space = UUID()
        let bad = """
        {"id": "6E3B8B4E-7C1F-4B1B-9D1E-0A1B2C3D4E5F", "title": "Odd", "kind": "game", "spaceID": "\(space.uuidString)",
         "source": {"executable": {}}, "arguments": [], "graphics": "quantum", "environment": {}, "addedAt": "2026-10-23T10:00:00.000Z",
         "secondsPlayed": 0}
        """
        _ = try write([bad, #"{"title": "no id at all"}"#, "42", "null", #""just text""#, "[1]"])
        let loaded = try store.load()
        #expect(loaded.games.map(\.title) == ["Mine"] && loaded.unreadableGames.count == 6)
        try store.save(loaded)
        let list = try games(in: Data(contentsOf: store.paths.libraryFile))
        #expect(list.count == 7)
        #expect(list.contains { ($0 as? NSNumber) == 42 } && list.contains { $0 is NSNull } && list.contains { ($0 as? String) == "just text" })
    }

    @Test func aNormalGameWithAnExtraFieldIsStillReadAndNotSetAside() throws {
        let space = UUID()
        let extra = """
        {"id": "6E3B8B4E-7C1F-4B1B-9D1E-0A1B2C3D4E5F", "title": "Known", "kind": "game", "spaceID": "\(space.uuidString)",
         "source": {"epic": {"appName": "a", "launchURI": "u"}}, "arguments": [], "graphics": "auto", "environment": {},
         "addedAt": "2026-10-23T10:00:00.000Z", "secondsPlayed": 0, "somethingNew": 1}
        """
        _ = try write([extra])
        let loaded = try store.load()
        #expect(loaded.games.map(\.title) == ["Mine", "Known"] && loaded.unreadableGames.isEmpty)
    }

    @Test func aLibraryThatIsDamagedInAnyOtherWayIsStillRefused() throws {
        try FileManager.default.createDirectory(at: store.paths.root, withIntermediateDirectories: true)
        for text in ["garbage", #"{"version": 1, "spaces": [], "hiddenStoreKeys": []}"#, #"{"version": 1, "spaces": [], "games": 3, "hiddenStoreKeys": []}"#,
                     #"{"version": 1, "spaces": [{"name": 1}], "games": [], "hiddenStoreKeys": []}"#] {
            try Data(text.utf8).write(to: store.paths.libraryFile)
            guard case .blocked(let problem) = open() else { Issue.record("opened \(text)"); continue }
            #expect(problem.kind == .damaged, "\(text)")
        }
    }

    @Test func aLibraryWithNothingUnreadableIsWrittenAsBefore() throws {
        var state = LibraryState()
        state.spaces = [mainSpace]
        state.games = [fixedGame("A", source: .legendary(appName: "SampleApp"))]
        try store.save(state)
        #expect(try store.load() == state)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.libraryFile)) as? [String: Any])
        #expect(Set(root.keys) == ["version", "spaces", "games", "hiddenStoreKeys"])        // no new key for an older version to trip on
    }
}

@Suite struct KeepBeforeEpicTests {
    let tmp = TempFolder()
    var store: LibraryStore { LibraryStore(paths: LibraryPaths(root: tmp.url)) }

    private func library(_ titles: [String]) -> LibraryState {
        var state = LibraryState()
        state.spaces = [mainSpace]
        state.games = titles.map { fixedGame($0) }
        return state
    }

    @Test func theLibraryIsKeptOnceBeforeTheFirstEpicGame() throws {
        try store.save(library(["One"]))
        let kept = try #require(try store.keepBeforeEpic())
        #expect(kept.lastPathComponent.hasPrefix("library.json.before-epic-"))
        #expect(try Data(contentsOf: kept) == Data(contentsOf: store.paths.libraryFile))
        // The library with Epic games in it is saved, and saved again: the copy stays the library from before.
        var state = library(["One"])
        state.games.append(fixedGame("Epic", source: .legendary(appName: "SampleApp")))
        try store.save(state)
        try store.save(state)
        #expect(try LibraryStore.decoder.decode(LibraryState.self, from: Data(contentsOf: kept)) == library(["One"]))
        // Once: asked again, even on another day, it names the copy there is and keeps no second one.
        #expect(try store.keepBeforeEpic(now: Date().addingTimeInterval(3 * 24 * 3600)) == kept)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.paths.root.path)
        #expect(names.filter { $0.hasPrefix("library.json.before-epic-") }.count == 1)
    }

    @Test func itIsNamedByTheDayAndNeverMixedUpWithTheEngineUpdateCopy() throws {
        let day = Date(timeIntervalSince1970: 1_792_000_000)
        #expect(LibraryStore.dayName(LibraryStore.beforeEpicPrefix, at: day, in: TimeZone(identifier: "UTC")!) == "library.json.before-epic-2026-10-14")
        try store.save(library(["One"]))
        let engine = try #require(try store.keepBeforeEngineUpdate())
        let epic = try #require(try store.keepBeforeEpic())
        #expect(engine != epic && epic.lastPathComponent.hasPrefix("library.json.before-epic-"))
    }

    @Test func withoutALibraryFileThereIsNothingToKeepAndNothingIsWritten() throws {
        try store.paths.createFolders()
        #expect(try store.keepBeforeEpic() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.paths.root.path).filter { $0.hasPrefix("library.json.") }.isEmpty)
    }

    @Test func aCopyThatCantBeMadeSaysSoAndLeavesTheLibraryAlone() throws {
        try store.save(library(["One"]))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.paths.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.paths.root.path) }
        if getuid() != 0 { #expect(throws: (any Error).self) { try store.keepBeforeEpic() } }
        #expect(try LibraryStore.decoder.decode(LibraryState.self, from: Data(contentsOf: store.paths.libraryFile)) == library(["One"]))
    }

    @Test func aMergeThatAddsAnEpicGameIsTheOneThatNeedsTheCopy() {
        let space = UUID()
        let mine = Game(title: "Mine", spaceID: space)
        let steam = Game(title: "Steam Game", spaceID: space, source: .steam(appID: "1"))
        let epic = Game(title: "Epic", spaceID: space, source: .legendary(appName: "SampleApp"))
        let other = Game(title: "Other", spaceID: space, source: .legendary(appName: "OtherApp"))
        #expect(!EpicGames.addsGames([mine, steam], to: [mine]))                      // nothing from Epic
        #expect(EpicGames.addsGames([mine, epic], to: [mine]))                        // the first one
        #expect(EpicGames.addsGames([mine, epic, other], to: [mine, epic]))           // another: the copy there is is reused
        #expect(!EpicGames.addsGames([mine, epic], to: [mine, epic]))                 // none new
        #expect(!EpicGames.addsGames([mine], to: [mine, epic]))                       // one gone
    }
}
