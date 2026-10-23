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
        #expect(problem.kind == .damaged)
        let copy = try #require(problem.brokenCopy)
        #expect(copy.lastPathComponent.hasPrefix("library.json.broken-") && copy.deletingLastPathComponent() == store.paths.root)
        #expect(try Data(contentsOf: copy) == garbage)
        #expect(try Data(contentsOf: store.paths.libraryFile) == garbage)
        #expect(!problem.reason.isEmpty)
    }

    @Test func aFileTheSystemWontLetBeReadIsNotCalledDamaged() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.save(state(named: "Main"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.paths.libraryFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.paths.libraryFile.path) }
        guard case .blocked(let problem) = store.open(expectingLibrary: true) else { Issue.record("not blocked"); return }
        // The system's short reason, without "The file “library.json” couldn’t be opened because" (the screen names the file).
        #expect(problem.kind == .unreadable && !problem.reason.isEmpty && !problem.reason.contains("library.json"))
        // Nothing to copy: the file can't be opened. No copy is made, and the file is as it was.
        #expect(problem.brokenCopy == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.paths.root.path)
        #expect(!names.contains { $0.hasPrefix("library.json.broken-") })
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

    @Test func aSpaceFoundElsewhereStaysWhereItIsAlsoInsideTheOldFolder() {
        // A library in ~/Games with a prefix of the user's own next to it: moving the library doesn't take the prefix along.
        let old = URL(fileURLWithPath: "/Users/me/Games")
        let new = URL(fileURLWithPath: "/Volumes/Big/Games")
        let own = Space(name: "Own", path: "/Users/me/Games/MyPrefix", engineID: "e", origin: .external)
        let deeper = Space(name: "Deeper", path: "/Users/me/Games/Spaces/Found", engineID: "e", origin: .external)
        let made = Space(name: "Main", path: "/Users/me/Games/Spaces/Main", engineID: "e", origin: .managed)
        // A managed space that isn't under Spaces isn't one G-Player made there.
        let odd = Space(name: "Odd", path: "/Users/me/Games/Elsewhere/Odd", engineID: "e", origin: .managed)
        var library = LibraryState()
        library.spaces = [own, deeper, made, odd]
        let moved = library.movingLibrary(from: old, to: new)
        #expect(moved.spaces[0] == own && moved.spaces[1] == deeper && moved.spaces[3] == odd)
        #expect(moved.spaces[2].path == "/Volumes/Big/Games/Spaces/Main")
    }
}


/// Start Empty must not cost the last good library: the empty one is the first thing the saves rotate into `.previous`.
@Suite struct LibraryStartEmptyTests {
    private func store(_ tmp: TempFolder) -> LibraryStore {
        LibraryStore(paths: LibraryPaths(root: tmp.url.appendingPathComponent("Library", isDirectory: true)))
    }

    private func names(_ store: LibraryStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.paths.root.path).filter { $0.hasPrefix("library.json") }.sorted()
    }

    @Test func theOldLibraryIsStillOnDiskAfterAnEmptyOneWasStartedAndChanged() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        let old = library(["One", "Two"])
        try store.save(library(["One"]))
        try store.save(old)                                        // library.json = old, previous = the one before
        try FileManager.default.removeItem(at: store.paths.libraryFile)            // the file is lost
        guard case .blocked(let problem) = store.open(expectingLibrary: true) else { Issue.record("not blocked"); return }
        #expect(problem.kind == .fileMissing && problem.previousIsUsable)
        // Start Empty: the previous copy is kept first, then the empty library is written, then it changes.
        let kept = try #require(try store.keepPreviousBeforeStartingEmpty())
        try store.save(LibraryState())
        try store.save(library(["New"]))
        try store.save(library(["New", "Newer"]))
        #expect(kept.lastPathComponent.hasPrefix("library.json.before-empty-"))
        // Rotation has moved on, and the copy is still the library from before.
        let previous = try LibraryStore.decoder.decode(LibraryState.self, from: Data(contentsOf: store.paths.previousFile))
        #expect(previous == library(["New"]))
        #expect(try LibraryStore.decoder.decode(LibraryState.self, from: Data(contentsOf: kept)) == library(["One"]))
    }

    @Test func aDamagedFilesLibraryIsKeptTwice() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.save(library(["One"]))
        try store.save(library(["One", "Two"]))                    // previous = One
        try Data("garbage".utf8).write(to: store.paths.libraryFile)
        guard case .blocked(let problem) = store.open(expectingLibrary: true) else { Issue.record("not blocked"); return }
        let broken = try #require(problem.brokenCopy)
        let kept = try #require(try store.keepPreviousBeforeStartingEmpty())
        try store.save(LibraryState())
        try store.save(library(["New"]))
        // Both the damaged file and the previous copy are still there, under names no save writes.
        #expect(try Data(contentsOf: broken) == Data("garbage".utf8))
        #expect(try LibraryStore.decoder.decode(LibraryState.self, from: Data(contentsOf: kept)) == library(["One"]))
        #expect(try names(store).filter { $0 != "library.json" && $0 != "library.json.previous" }.count == 2)
    }

    @Test func tryingAgainOrStartingTwiceKeepsOneCopy() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.save(library(["One"]))
        try store.save(library(["One", "Two"]))
        let first = try store.keepPreviousBeforeStartingEmpty()
        let second = try store.keepPreviousBeforeStartingEmpty(now: Date().addingTimeInterval(60))
        #expect(first == second)
        #expect(try names(store).filter { $0.hasPrefix("library.json.before-empty-") }.count == 1)
    }

    @Test func withNoPreviousCopyThereIsNothingToKeepAndNothingIsWritten() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.paths.createFolders()
        #expect(try store.keepPreviousBeforeStartingEmpty() == nil)
        #expect(try names(store).isEmpty)
    }

    // MARK: Before the first engine update

    @Test func theLibraryIsKeptOnceBeforeTheFirstMoveToAnotherEngine() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.save(library(["One"]))
        let kept = try #require(try store.keepBeforeEngineUpdate())
        #expect(kept.lastPathComponent.hasPrefix("library.json.before-engine-update-"))
        #expect(try Data(contentsOf: kept) == Data(contentsOf: store.paths.libraryFile))
        // The moved library is saved and saved again: the copy is still the library from before, under a name no save writes.
        try store.save(library(["One", "Moved"]))
        try store.save(library(["One", "Moved", "More"]))
        #expect(try LibraryStore.decoder.decode(LibraryState.self, from: Data(contentsOf: kept)) == library(["One"]))
        // Once: a later move (another start, another engine) doesn't keep the moved library next to the first copy.
        let again = try store.keepBeforeEngineUpdate(now: Date().addingTimeInterval(3 * 24 * 3600))
        #expect(again == kept)
        #expect(try names(store).filter { $0.hasPrefix("library.json.before-engine-update-") }.count == 1)
        #expect(try LibraryStore.decoder.decode(LibraryState.self, from: Data(contentsOf: kept)) == library(["One"]))
    }

    @Test func withoutALibraryFileThereIsNothingToKeepAndNothingIsWritten() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.paths.createFolders()
        #expect(try store.keepBeforeEngineUpdate() == nil)
        #expect(try names(store).isEmpty)
    }

    @Test func aCopyThatCantBeMadeSaysSoAndLeavesTheLibraryAlone() throws {
        let tmp = TempFolder()
        let store = store(tmp)
        try store.save(library(["One"]))
        // A library folder the system won't let anything be written into: the copy fails, and the caller moves nothing.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.paths.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.paths.root.path) }
        if getuid() != 0 { #expect(throws: (any Error).self) { try store.keepBeforeEngineUpdate() } }
        #expect(try LibraryStore.decoder.decode(LibraryState.self, from: Data(contentsOf: store.paths.libraryFile)) == library(["One"]))
    }

    @Test func theEngineUpdateCopyIsNamedByTheDay() {
        let day = Date(timeIntervalSince1970: 1_792_000_000)
        #expect(LibraryStore.dayName(LibraryStore.beforeEngineUpdatePrefix, at: day, in: TimeZone(identifier: "UTC")!)
                == "library.json.before-engine-update-2026-10-14")
    }

    @Test func theCopyIsNamedByTheSecond() {
        let name = LibraryStore.dated(LibraryStore.beforeEmptyPrefix, at: Date(timeIntervalSince1970: 1_792_000_000), in: TimeZone(identifier: "UTC")!)
        #expect(name == "library.json.before-empty-2026-10-14-174640")
    }
}

/// The library screen's words make promises; these hold them.
@Suite struct LibraryProblemWordsTests {
    private let root = URL(fileURLWithPath: NSHomeDirectory() + "/Games/G-Player")
    private let copy = URL(fileURLWithPath: NSHomeDirectory() + "/Games/G-Player/library.json.broken-2026-10-23-142530")

    @Test func theTitleNamesTheLibraryWithTheHomeFolderAbbreviated() {
        #expect(LibraryProblem(kind: .folderMissing, root: root).title == "G-Player can't read your library at ~/Games/G-Player")
    }

    @Test func aFileTheSystemWontOpenIsNotCalledDamagedAndADamagedOneIs() {
        let denied = LibraryProblem(kind: .unreadable, root: root, reason: "you don’t have permission")
        #expect(denied.explanation.contains("can't be opened") && denied.explanation.contains("permission"))
        #expect(!denied.explanation.contains("is damaged"))
        let damaged = LibraryProblem(kind: .damaged, root: root, reason: "spaces[0].engineID: missing", brokenCopy: copy)
        #expect(damaged.explanation.contains("is damaged") && damaged.explanation.contains("spaces[0].engineID: missing"))
        #expect(damaged.explanation.contains("library.json.broken-2026-10-23-142530"))
    }

    @Test func eachButtonThatIsThereIsExplained() {
        let missing = LibraryProblem(kind: .folderMissing, root: root)
        let help = missing.buttonHelp.joined(separator: "\n")
        #expect(help.contains("Try Again") && help.contains("Locate…") && help.contains("choose the folder your library is in now"))
        #expect(help.contains("Start Empty") && help.contains("files stay on your disk"))
        #expect(!help.contains("Use Previous Copy"))
        let withPrevious = LibraryProblem(kind: .fileMissing, root: root, previousIsUsable: true)
        let previousHelp = withPrevious.buttonHelp.joined(separator: "\n")
        #expect(previousHelp.contains("Use Previous Copy") && previousHelp.contains("before its last change"))
        // No Start Empty line where the button isn't offered.
        let denied = LibraryProblem(kind: .unreadable, root: root, reason: "x")
        #expect(!denied.buttonHelp.joined().contains("Start Empty"))
    }

    @Test func startEmptyIsOfferedOnlyWhereNothingWouldBeLost() {
        #expect(LibraryProblem(kind: .folderMissing, root: root).canStartEmpty)
        #expect(LibraryProblem(kind: .fileMissing, root: root, previousIsUsable: true).canStartEmpty)
        #expect(LibraryProblem(kind: .damaged, root: root, reason: "x", brokenCopy: copy).canStartEmpty)
        #expect(!LibraryProblem(kind: .damaged, root: root, reason: "x", brokenCopy: nil).canStartEmpty)    // the file couldn't be kept
        #expect(!LibraryProblem(kind: .unreadable, root: root, reason: "x").canStartEmpty)
    }

    @Test func startEmptyKeepsItsPromises() {
        // The spaces' files stay on disk, and the old library is kept under the names the code really uses.
        let damaged = LibraryProblem(kind: .damaged, root: root, reason: "x", brokenCopy: copy).startEmptyConsequence
        #expect(damaged.contains("files stay on your disk") && damaged.contains("library.json.broken-2026-10-23-142530"))
        #expect(damaged.contains("library.json.before-empty-"))
        let fileMissing = LibraryProblem(kind: .fileMissing, root: root, previousIsUsable: true).startEmptyConsequence
        #expect(fileMissing.contains("files stay on your disk") && fileMissing.contains("library.json.before-empty-"))
        let folder = LibraryProblem(kind: .folderMissing, root: root).startEmptyConsequence
        #expect(folder.contains("~/Games/G-Player") && folder.contains("aren't deleted") && folder.contains("Try Again"))
        #expect(LibraryStore.beforeEmptyPrefix == "library.json.before-empty-")
    }
}
