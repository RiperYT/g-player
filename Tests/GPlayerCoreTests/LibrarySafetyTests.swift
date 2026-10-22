import Foundation
import Testing
@testable import GPlayerCore

/// A library with spaces named `names`, the same each time it is made (a space's id comes from its name).
private func library(_ names: [String]) -> LibraryState {
    var s = LibraryState()
    s.spaces = names.map { name in
        var bytes = Array(name.utf8.prefix(16))
        bytes += [UInt8](repeating: 0, count: 16 - bytes.count)
        let id = bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
        return Space(id: id, name: name, path: "/x/\(name)", engineID: "e", origin: .managed, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    return s
}

/// A library that can't be read must never turn into an empty one that gets saved over it.
@Suite struct LibraryOpeningTests {
    private func store(_ tmp: TempFolder, folder: String = "Library") -> LibraryStore {
        LibraryStore(paths: LibraryPaths(root: tmp.url.appendingPathComponent(folder, isDirectory: true)))
    }

    private func state(named names: String...) -> LibraryState { library(names) }

    @Test func aFolderThatIsGoneIsAProblemOnceTheLibraryWasSetUpAndWritesNothing() {
        let tmp = TempFolder()
        let store = store(tmp)
        guard case .blocked(let problem) = store.open(expectingLibrary: true) else { Issue.record("not blocked"); return }
        #expect(problem.kind == .folderMissing && problem.root == store.paths.root)
        #expect(problem.brokenCopy == nil && !problem.previousIsUsable)
        // Opening is looking: the folder isn't made, so a disk that comes back later finds its library as it was.
        #expect(!FileManager.default.fileExists(atPath: store.paths.root.path))
    }

    @Test func aNewLibraryFolderThatDoesntExistYetIsFine() {
        let tmp = TempFolder()
        #expect(store(tmp).open(expectingLibrary: false) == .ready(LibraryState()))
    }

    @Test func aFolderWithoutAFileIsNewUnlessAPreviousCopyShowsItWasALibrary() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.paths.createFolders()
        #expect(store.open(expectingLibrary: true) == .ready(LibraryState()))
        // The file was lost and the copy from before the last change is what is left.
        try LibraryStore.encoder.encode(state(named: "Main")).write(to: store.paths.previousFile)
        guard case .blocked(let problem) = store.open(expectingLibrary: true) else { Issue.record("not blocked"); return }
        #expect(problem.kind == .fileMissing && problem.previousIsUsable)
    }

    @Test func anUnreadableFileIsCopiedFirstAndLeftAsItIs() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.paths.createFolders()
        let garbage = Data(#"{"version": 1, "spaces": [{"name": "Main""#.utf8)             // cut off in the middle
        try garbage.write(to: store.paths.libraryFile)
        guard case .blocked(let problem) = store.open(expectingLibrary: true) else { Issue.record("not blocked"); return }
        #expect(problem.kind == .unreadable)
        let copy = try #require(problem.brokenCopy)
        #expect(copy.lastPathComponent.hasPrefix("library.json.broken-") && copy.deletingLastPathComponent() == store.paths.root)
        #expect(try Data(contentsOf: copy) == garbage)
        #expect(try Data(contentsOf: store.paths.libraryFile) == garbage)
        #expect(!problem.reason.isEmpty)
    }

    @Test func tryingAgainOnTheSameFileKeepsOneCopy() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.paths.createFolders()
        try Data("not json".utf8).write(to: store.paths.libraryFile)
        for _ in 0..<3 { _ = store.open(expectingLibrary: true) }
        let copies = try FileManager.default.contentsOfDirectory(atPath: store.paths.root.path).filter { $0.hasPrefix("library.json.broken-") }
        #expect(copies.count == 1)
        // Another damaged file is another copy.
        try Data("not json either".utf8).write(to: store.paths.libraryFile)
        _ = store.open(expectingLibrary: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.paths.root.path).filter { $0.hasPrefix("library.json.broken-") }.count == 2)
    }

    @Test func aFileThatDecodesButHasAWrongValueNamesWhereItIsWrong() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.paths.createFolders()
        try store.save(state(named: "Main"))
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.libraryFile)) as? [String: Any])
        var spaces = try #require(object["spaces"] as? [[String: Any]])
        spaces[0]["engineID"] = nil
        object["spaces"] = spaces
        try JSONSerialization.data(withJSONObject: object).write(to: store.paths.libraryFile)
        guard case .blocked(let problem) = store.open(expectingLibrary: true) else { Issue.record("not blocked"); return }
        #expect(problem.reason.contains("spaces[0].engineID"))
    }

    @Test func aGoodFileOpens() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        let saved = state(named: "Main", "Steam")
        try store.save(saved)
        #expect(store.open(expectingLibrary: true) == .ready(saved))
    }

    @Test func theBrokenCopyIsNamedByTheSecond() {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        let name = LibraryStore.brokenName(at: date, in: TimeZone(identifier: "UTC")!)
        #expect(name == "library.json.broken-2026-10-14-174640")
    }
}

@Suite struct LibrarySaveTests {
    private func store(_ tmp: TempFolder) -> LibraryStore {
        LibraryStore(paths: LibraryPaths(root: tmp.url.appendingPathComponent("Library", isDirectory: true)))
    }

    private func state(_ names: String...) -> LibraryState { library(names) }

    @Test func aSaveKeepsTheFileItReplacedAsThePreviousCopy() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.save(state("One"))
        #expect(!FileManager.default.fileExists(atPath: store.paths.previousFile.path))
        try store.save(state("One", "Two"))
        #expect(try store.load() == state("One", "Two"))
        let previous = try LibraryStore.decoder.decode(LibraryState.self, from: Data(contentsOf: store.paths.previousFile))
        #expect(previous == state("One"))
        // One previous copy: the next change moves it on.
        try store.save(state("One", "Two", "Three"))
        let later = try LibraryStore.decoder.decode(LibraryState.self, from: Data(contentsOf: store.paths.previousFile))
        #expect(later == state("One", "Two"))
    }

    @Test func aSaveThatChangesNothingTouchesNothing() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.save(state("One"))
        try store.save(state("One", "Two"))
        let before = try Data(contentsOf: store.paths.previousFile)
        try store.save(state("One", "Two"))
        try store.save(state("One", "Two"))
        #expect(try Data(contentsOf: store.paths.previousFile) == before)
    }

    @Test func aDamagedFileNeverReplacesTheLastGoodCopy() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.save(state("One"))
        try store.save(state("One", "Two"))
        let good = try Data(contentsOf: store.paths.previousFile)
        try Data("garbage".utf8).write(to: store.paths.libraryFile)
        try store.save(state("Fresh"))
        #expect(try Data(contentsOf: store.paths.previousFile) == good)
        #expect(try store.load() == state("Fresh"))
    }

    @Test func theFileIsNeverLeftMissingOrHalfWritten() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        for n in 1...5 {
            try store.save(state(String(repeating: "x", count: n)))
            #expect(try store.load() == state(String(repeating: "x", count: n)))
        }
        // No temporary files are left next to it.
        let names = try FileManager.default.contentsOfDirectory(atPath: store.paths.root.path).filter { $0.hasPrefix("library.json") }
        #expect(Set(names) == ["library.json", "library.json.previous"])
    }

    @Test func thePreviousCopyTakesTheMissingFilesPlace() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.save(state("One"))
        try store.save(state("One", "Two"))
        try Data("garbage".utf8).write(to: store.paths.libraryFile)
        guard case .blocked(let problem) = store.open(expectingLibrary: true) else { Issue.record("not blocked"); return }
        #expect(problem.previousIsUsable)
        let restored = try store.restorePrevious()
        #expect(restored == state("One"))
        #expect(try store.load() == state("One"))
        // The damaged file stays, next to it.
        #expect(try Data(contentsOf: #require(problem.brokenCopy)) == Data("garbage".utf8))
    }

    @Test func aPreviousCopyThatCantBeReadChangesNothing() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.save(state("One"))
        try Data("garbage".utf8).write(to: store.paths.previousFile)
        #expect(throws: (any Error).self) { try store.restorePrevious() }
        #expect(try store.load() == state("One"))
    }
}

@Suite struct LibraryLocateTests {
    @Test func theFolderWithTheLibraryInIsFoundAsChosenOrByItsGPlayerFolder() throws {
        let tmp = TempFolder()
        let library = tmp.dir("Disk/G-Player")
        try LibraryStore(paths: LibraryPaths(root: library)).save(LibraryState())
        #expect(LibraryStore.libraryFolder(in: library) == library.standardizedFileURL)
        #expect(LibraryStore.libraryFolder(in: tmp.url.appendingPathComponent("Disk")) == library.standardizedFileURL)
        #expect(LibraryStore.libraryFolder(in: tmp.dir("Elsewhere")) == nil)
        #expect(LibraryStore.libraryFolder(in: tmp.url.appendingPathComponent("Nope")) == nil)
    }

    @Test func aFolderThatOnlyHasThePreviousCopyStillCounts() throws {
        let tmp = TempFolder()
        let library = tmp.dir("Lib")
        let store = LibraryStore(paths: LibraryPaths(root: library))
        try store.save(LibraryState())
        try store.save({ var s = LibraryState(); s.hiddenStoreKeys = ["a"]; return s }())
        try FileManager.default.removeItem(at: store.paths.libraryFile)
        #expect(LibraryStore.libraryFolder(in: library) == library.standardizedFileURL)
    }

    @Test func spacesInsideTheOldFolderFollowTheLibraryToTheNewOne() {
        let old = URL(fileURLWithPath: "/Volumes/Games/Very/Long/Place/G-Player")
        let new = URL(fileURLWithPath: "/Users/me/Games/G-Player")
        var library = LibraryState()
        let main = Space(name: "Main", path: old.path + "/Spaces/Main", engineID: "e", origin: .managed)
        let steam = Space(name: "Steam", path: old.path + "/Spaces/Steam 2", engineID: "e", origin: .managed)
        let bottle = Space(name: "Bottle", path: "/Users/me/Library/Application Support/CrossOver/Bottles/B", engineID: "e", origin: .external)
        // A folder that only starts with the same letters is not inside the old one.
        let lookalike = Space(name: "Other", path: old.path + "-copy/Spaces/Other", engineID: "e", origin: .managed)
        library.spaces = [main, steam, bottle, lookalike]
        library.games = [Game(title: "G", spaceID: main.id, executablePath: "drive_c/Games/G/G.exe")]
        let moved = library.movingLibrary(from: old, to: new)
        #expect(moved.spaces[0].path == "/Users/me/Games/G-Player/Spaces/Main")
        #expect(moved.spaces[1].path == "/Users/me/Games/G-Player/Spaces/Steam 2")
        #expect(moved.spaces[2] == bottle && moved.spaces[3] == lookalike)
        // Names, ids and games are as they were: a game's path is inside its space.
        #expect(moved.spaces[0].id == main.id && moved.spaces[0].name == "Main")
        #expect(moved.games == library.games)
        #expect(library.movingLibrary(from: old, to: old) == library)
    }
}
