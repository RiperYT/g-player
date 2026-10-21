import Foundation
import Testing
@testable import GPlayerCore

@Suite struct HiddenGameTests {
    @Test func oldLibraryWithoutHiddenStillDecodes() throws {
        let tmp = TempFolder()
        let paths = LibraryPaths(root: tmp.url)
        let space = "8D2B1F0E-0000-4000-8000-000000000001", game = "8D2B1F0E-0000-4000-8000-000000000002"
        let json = """
        {
          "version": 1,
          "spaces": [{"id": "\(space)", "name": "Main", "path": "/x", "engineID": "e", "origin": "managed",
                      "colorIndex": 0, "createdAt": "2026-01-01T10:00:00.000Z"}],
          "games": [{"id": "\(game)", "title": "Old Game", "kind": "game", "spaceID": "\(space)",
                     "source": {"steam": {"appID": "7"}}, "arguments": [], "graphics": "auto", "environment": {},
                     "addedAt": "2026-01-02T10:00:00.000Z", "secondsPlayed": 0}],
          "hiddenStoreKeys": ["steam:2"]
        }
        """
        try paths.createFolders()
        try Data(json.utf8).write(to: paths.libraryFile)
        let loaded = try LibraryStore(paths: paths).load()
        #expect(loaded.games.count == 1)
        #expect(loaded.games[0].hidden == nil)
        #expect(loaded.games[0].isHidden == false)
        #expect(loaded.hiddenStoreKeys == ["steam:2"])
    }

    @Test func hiddenRoundTrips() throws {
        let tmp = TempFolder()
        let store = LibraryStore(paths: LibraryPaths(root: tmp.url))
        let s = Space(name: "Main", path: "/x", engineID: "e", origin: .managed)
        var state = LibraryState()
        state.spaces = [s]
        state.games = [Game(title: "Shown", spaceID: s.id),
                       Game(title: "Hidden", spaceID: s.id, source: .steam(appID: "1"), hidden: true)]
        try store.save(state)
        let loaded = try store.load()
        #expect(loaded.games.map(\.isHidden) == [false, true])
        #expect(loaded.games[1].hidden == true)
        // A visible game doesn't write the key at all, so files stay readable by older versions.
        let text = try String(contentsOf: store.paths.libraryFile, encoding: .utf8)
        #expect(text.components(separatedBy: "\"hidden\"").count == 2)
    }

    @Test func onlyGamesYouAddedCanBeRemoved() {
        let id = UUID()
        #expect(Game(title: "Mine", spaceID: id).canRemove)
        #expect(!Game(title: "Steam", kind: .app, spaceID: id).canRemove)
        #expect(!Game(title: "Portal", spaceID: id, source: .steam(appID: "400")).canRemove)
        #expect(!Game(title: "Fortnite", spaceID: id, source: .epic(appName: "Fn", launchURI: "x")).canRemove)
    }
}

@Suite struct StoreMergeTests {
    let space = UUID()
    func store(_ id: String, installed: Bool = true) -> StoreGame {
        StoreGame(source: .steam(appID: id), title: "Game \(id)", installed: installed, installFolder: nil)
    }
    func entry(_ id: String, in spaceID: UUID? = nil, hidden: Bool? = nil) -> Game {
        Game(title: "Game \(id)", spaceID: spaceID ?? space, source: .steam(appID: id), hidden: hidden)
    }

    @Test func addsInstalledGamesOnly() {
        let r = StoreMerge.merge(existing: [], found: [store("1"), store("2", installed: false)], hiddenKeys: [], spaceID: space)
        #expect(r.games.map(\.title) == ["Game 1"])
        #expect(r.games[0].isHidden == false)
        #expect(r.changed)
    }

    @Test func nothingToDoIsNotAChange() {
        let existing = [entry("1"), entry("2", hidden: true)]
        let r = StoreMerge.merge(existing: existing, found: [store("1"), store("2")], hiddenKeys: [], spaceID: space)
        #expect(r.games == existing)
        #expect(!r.changed)
    }

    @Test func hiddenGameStaysWhileInstalled() {
        let r = StoreMerge.merge(existing: [entry("1", hidden: true)], found: [store("1")], hiddenKeys: [], spaceID: space)
        #expect(r.games.count == 1)
        #expect(r.games[0].isHidden)
    }

    @Test func updatingGameIsKept() {
        var updating = entry("1")
        updating.title = "My name for it"
        updating.secondsPlayed = 7200
        let r = StoreMerge.merge(existing: [updating], found: [store("1", installed: false)], hiddenKeys: [], spaceID: space)
        #expect(r.games == [updating])
        #expect(!r.changed)
    }

    @Test func updatingEpicGameIsKept() {
        let epic = StoreGame(source: .epic(appName: "Fn", launchURI: "u"), title: "Fortnite", installed: false, installFolder: nil)
        let existing = Game(title: "Fortnite", spaceID: space, source: .epic(appName: "Fn", launchURI: "u"), secondsPlayed: 60)
        let r = StoreMerge.merge(existing: [existing], found: [epic], hiddenKeys: [], spaceID: space)
        #expect(r.games == [existing])
        #expect(!r.changed)
    }

    @Test func hiddenGameStaysWhileItUpdates() {
        let hidden = entry("1", hidden: true)
        let r = StoreMerge.merge(existing: [hidden], found: [store("1", installed: false)], hiddenKeys: [], spaceID: space)
        #expect(r.games == [hidden])
        #expect(r.hiddenKeys.isEmpty)
        #expect(!r.changed)
    }

    @Test func gameThatIsNotListedAnymoreIsRemoved() {
        let existing = [entry("1"), entry("2"), entry("3")]
        let r = StoreMerge.merge(existing: existing, found: [store("3"), store("1", installed: false)], hiddenKeys: [], spaceID: space)
        #expect(r.games.map(\.title) == ["Game 1", "Game 3"])         // 1 is updating, 2 is gone
        #expect(r.hiddenKeys.isEmpty)                                   // 2 wasn't hidden: nothing to remember
        #expect(r.changed)
    }

    @Test func notInstalledGameGetsNoEntryAndKeepsItsKey() {
        let r = StoreMerge.merge(existing: [], found: [store("2", installed: false)], hiddenKeys: ["steam:2"], spaceID: space)
        #expect(r.games.isEmpty)
        #expect(r.hiddenKeys == ["steam:2"])
        #expect(!r.changed)
    }

    @Test func hiddenEntryThatVanishesComesBackHidden() {
        let hidden = entry("1", hidden: true)
        // The manifest is gone: the entry goes and its key is remembered.
        let gone = StoreMerge.merge(existing: [hidden, entry("2")], found: [store("2")], hiddenKeys: [], spaceID: space)
        #expect(gone.games.map(\.title) == ["Game 2"])
        #expect(gone.hiddenKeys == ["steam:1"])
        #expect(gone.changed)
        // Still not there: nothing more to do.
        let still = StoreMerge.merge(existing: gone.games, found: [store("2")], hiddenKeys: gone.hiddenKeys, spaceID: space)
        #expect(still.games == gone.games)
        #expect(still.hiddenKeys == ["steam:1"])
        #expect(!still.changed)
        // Its game turns up again: added hidden, key used up.
        let back = StoreMerge.merge(existing: gone.games, found: [store("1"), store("2")], hiddenKeys: gone.hiddenKeys, spaceID: space)
        #expect(back.games.map(\.title) == ["Game 2", "Game 1"])
        #expect(back.games.last?.isHidden == true)
        #expect(back.hiddenKeys.isEmpty)
        #expect(back.changed)
    }

    @Test func removedHiddenEntryRemembersItsKeyInEveryStore() {
        let epic = Game(title: "Fortnite", spaceID: space, source: .epic(appName: "Fn", launchURI: "u"), hidden: true)
        let r = StoreMerge.merge(existing: [epic], found: [], hiddenKeys: ["steam:9"], spaceID: space)
        #expect(r.games.isEmpty)
        #expect(r.hiddenKeys == ["steam:9", "epic:Fn"])
    }

    @Test func removingAGameInOneSpaceLeavesTheSameGameInAnother() {
        let other = UUID()
        let elsewhere = entry("1", in: other, hidden: true)
        let r = StoreMerge.merge(existing: [entry("1", hidden: true), elsewhere], found: [], hiddenKeys: [], spaceID: space)
        #expect(r.games == [elsewhere])
        #expect(r.hiddenKeys == ["steam:1"])
    }

    @Test func changedIsTrueOnlyWhenTheGamesChange() {
        let kept = [entry("1"), entry("2", hidden: true)]
        #expect(!StoreMerge.merge(existing: kept, found: [store("1"), store("2", installed: false)], hiddenKeys: [], spaceID: space).changed)
        #expect(StoreMerge.merge(existing: kept, found: [store("1"), store("2"), store("3")], hiddenKeys: [], spaceID: space).changed)
        #expect(StoreMerge.merge(existing: kept, found: [store("1")], hiddenKeys: [], spaceID: space).changed)
        #expect(!StoreMerge.merge(existing: [], found: [], hiddenKeys: ["steam:1"], spaceID: space).changed)
    }

    @Test func oldHiddenKeyBecomesAHiddenEntry() {
        let r = StoreMerge.merge(existing: [], found: [store("1"), store("2")], hiddenKeys: ["steam:2"], spaceID: space)
        #expect(r.games.first { $0.title == "Game 2" }?.isHidden == true)
        #expect(r.games.first { $0.title == "Game 1" }?.isHidden == false)
        #expect(r.hiddenKeys.isEmpty)
        #expect(r.changed)
    }

    @Test func oldHiddenKeyWaitsUntilItsGameIsInstalled() {
        let r = StoreMerge.merge(existing: [], found: [store("1")], hiddenKeys: ["steam:2"], spaceID: space)
        #expect(r.hiddenKeys == ["steam:2"])
    }

    @Test func otherSpacesAndYourOwnGamesAreLeftAlone() {
        let other = UUID()
        let mine = Game(title: "Mine", spaceID: space)
        let elsewhere = entry("1", in: other)
        let r = StoreMerge.merge(existing: [mine, elsewhere], found: [store("9")], hiddenKeys: [], spaceID: space)
        #expect(r.games.contains(mine))
        #expect(r.games.contains(elsewhere))
        #expect(r.games.map(\.title) == ["Mine", "Game 1", "Game 9"])
    }

    @Test func sameStoreGameInAnotherSpaceIsAnotherEntry() {
        let other = UUID()
        let r = StoreMerge.merge(existing: [entry("1", in: other)], found: [store("1")], hiddenKeys: [], spaceID: space)
        #expect(r.games.count == 2)
    }

    @Test func epicGamesMergeToo() {
        let epic = StoreGame(source: .epic(appName: "Fn", launchURI: "u"), title: "Fortnite", installed: true, installFolder: nil)
        let r = StoreMerge.merge(existing: [], found: [epic], hiddenKeys: ["epic:Fn"], spaceID: space)
        #expect(r.games.first?.isHidden == true)
        #expect(r.hiddenKeys.isEmpty)
    }
}

@Suite struct VisibleGamesTests {
    @Test func visibleAndHiddenGamesAreSplit() {
        let a = Space(name: "A", path: "/a", engineID: "e", origin: .managed)
        let b = Space(name: "B", path: "/b", engineID: "e", origin: .managed)
        var state = LibraryState()
        state.spaces = [a, b]
        state.games = [Game(title: "A1", spaceID: a.id), Game(title: "A2", spaceID: a.id, hidden: true),
                       Game(title: "B1", spaceID: b.id, hidden: true), Game(title: "B2", spaceID: b.id),
                       Game(title: "B3", spaceID: b.id, hidden: false)]
        #expect(state.visibleGames.map(\.title) == ["A1", "B2", "B3"])
        #expect(state.hiddenGames.map(\.title) == ["A2", "B1"])
        #expect(state.visibleGames(in: a).map(\.title) == ["A1"])
        #expect(state.hiddenGames(in: a).map(\.title) == ["A2"])
        #expect(state.visibleGames(in: b).map(\.title) == ["B2", "B3"])
        #expect(state.hiddenGames(in: b).map(\.title) == ["B1"])
    }

    @Test func aSpaceWithOnlyHiddenGamesHasNoVisibleOnes() {
        let s = Space(name: "S", path: "/s", engineID: "e", origin: .managed)
        var state = LibraryState()
        state.spaces = [s]
        state.games = [Game(title: "X", spaceID: s.id, hidden: true), Game(title: "Y", spaceID: s.id, hidden: true)]
        #expect(state.visibleGames(in: s).isEmpty)
        #expect(state.hiddenGames(in: s).count == 2)
    }

    @Test func emptyLibraryHasNeither() {
        let state = LibraryState()
        #expect(state.visibleGames.isEmpty)
        #expect(state.hiddenGames.isEmpty)
    }
}

@Suite struct SpacePlacesTests {
    func makeSpace(_ tmp: TempFolder, folders: [String]) -> Space {
        let prefix = tmp.prefix("Main")
        for f in folders { tmp.dir("Main/drive_c/\(f)") }
        return space(at: prefix)
    }

    @Test func listsOnlyPlacesThatExist() {
        let tmp = TempFolder()
        let s = makeSpace(tmp, folders: ["Games", "Program Files (x86)", "users/Public", "users/bob/Documents", "users/bob/AppData"])
        let places = SpacePlaces.find(in: s, userName: "bob")
        #expect(places.map(\.title) == ["C: Drive", "Games", "Program Files (x86)", "Documents", "AppData", "Space Folder"])
        #expect(places.first { $0.kind == .drive }?.url == s.driveC)
        #expect(places.first { $0.kind == .spaceFolder }?.url == s.url)
        #expect(places.first { $0.kind == .documents }?.url.path.hasSuffix("users/bob/Documents") == true)
    }

    @Test func prefersTheMacUserOverOtherFolders() {
        let tmp = TempFolder()
        let s = makeSpace(tmp, folders: ["users/aaron", "users/zed"])
        #expect(SpacePlaces.windowsUserFolder(in: s, userName: "zed")?.lastPathComponent == "zed")
    }

    @Test func otherwiseTakesTheFirstFolderThatIsNotPublic() {
        let tmp = TempFolder()
        let s = makeSpace(tmp, folders: ["users/Public", "users/steamuser", "users/crossover"])
        #expect(SpacePlaces.windowsUserFolder(in: s, userName: "nobody")?.lastPathComponent == "crossover")
    }

    @Test func publicAloneIsNoUser() {
        let tmp = TempFolder()
        let s = makeSpace(tmp, folders: ["users/Public/Documents"])
        #expect(SpacePlaces.windowsUserFolder(in: s, userName: "bob") == nil)
        #expect(SpacePlaces.find(in: s, userName: "bob").map(\.kind) == [.drive, .spaceFolder])
    }

    @Test func foldersInsideTheSpaceDontLinkToTheMac() {
        let tmp = TempFolder()
        let s = makeSpace(tmp, folders: ["Games", "users/bob/Documents", "users/bob/AppData"])
        let places = SpacePlaces.find(in: s, userName: "bob")
        #expect(places.allSatisfy { !$0.linksToMac })
        #expect(places.map(\.label) == places.map(\.title))
    }

    @Test func aSymlinkOutOfTheSpaceLinksToTheMac() throws {
        let tmp = TempFolder()
        let s = makeSpace(tmp, folders: ["Games", "users/bob/AppData"])
        let macDocuments = tmp.dir("Mac/Documents")
        try FileManager.default.createSymbolicLink(
            at: s.driveC.appendingPathComponent("users/bob/Documents"), withDestinationURL: macDocuments)
        let places = SpacePlaces.find(in: s, userName: "bob")
        let documents = try #require(places.first { $0.kind == .documents })
        #expect(documents.linksToMac)
        #expect(documents.label == "Documents (Mac)")
        #expect(documents.title == "Documents")
        #expect(documents.url.path.hasSuffix("users/bob/Documents"))        // browsed through the space's own path
        #expect(places.filter(\.linksToMac).map(\.kind) == [.documents])
        #expect(places.first { $0.kind == .appData }?.label == "AppData")
    }

    @Test func aSymlinkThatStaysInsideTheSpaceIsNotAMacFolder() throws {
        let tmp = TempFolder()
        let s = makeSpace(tmp, folders: ["users/bob", "SavedGames/Documents"])
        try FileManager.default.createSymbolicLink(
            at: s.driveC.appendingPathComponent("users/bob/Documents"),
            withDestinationURL: s.driveC.appendingPathComponent("SavedGames/Documents"))
        let documents = SpacePlaces.find(in: s, userName: "bob").first { $0.kind == .documents }
        #expect(documents != nil)
        #expect(documents?.linksToMac == false)
    }

    @Test func aWholeUserFolderLinkedToTheMacMakesItsPlacesMacFolders() throws {
        let tmp = TempFolder()
        let s = makeSpace(tmp, folders: ["users"])
        tmp.dir("Mac/bob/Documents")
        try FileManager.default.createSymbolicLink(at: s.driveC.appendingPathComponent("users/bob"),
                                                   withDestinationURL: tmp.url.appendingPathComponent("Mac/bob"))
        let documents = SpacePlaces.find(in: s, userName: "bob").first { $0.kind == .documents }
        #expect(documents?.label == "Documents (Mac)")
    }

    @Test func aBrokenSymlinkIsNotAPlace() throws {
        let tmp = TempFolder()
        let s = makeSpace(tmp, folders: ["users/bob"])
        try FileManager.default.createSymbolicLink(at: s.driveC.appendingPathComponent("users/bob/Documents"),
                                                   withDestinationURL: tmp.url.appendingPathComponent("Mac/Missing"))
        #expect(SpacePlaces.find(in: s, userName: "bob").contains { $0.kind == .documents } == false)
    }

    @Test func aSpaceFolderThatIsItselfALinkStillCountsAsInside() throws {
        let tmp = TempFolder()
        _ = tmp.prefix("Real/Main")
        tmp.dir("Real/Main/drive_c/users/bob/Documents")
        let linked = tmp.url.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: tmp.url.appendingPathComponent("Real"))
        let s = space(at: linked.appendingPathComponent("Main"))
        let places = SpacePlaces.find(in: s, userName: "bob")
        #expect(places.contains { $0.kind == .documents })
        #expect(places.allSatisfy { !$0.linksToMac })
    }
}
