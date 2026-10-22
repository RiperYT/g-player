import Foundation
import Testing
@testable import GPlayerCore

/// A Wine prefix with a very long path made `explorer.exe /desktop` fail and Wine flood the Mac with processes.
@Suite struct PrefixPathTests {
    /// An absolute path of exactly `length` characters.
    private func path(ofLength length: Int, prefix: String = "/Users/me/") -> String {
        prefix + String(repeating: "a", count: length - prefix.utf16.count)
    }

    @Test func aPrefixPathIsFineUpToTheLimitAndRefusedAfterIt() throws {
        let limit = PrefixPath.maxLength
        #expect(PrefixPath.problem(forPrefix: URL(fileURLWithPath: path(ofLength: limit))) == nil)
        let message = try #require(PrefixPath.problem(forPrefix: URL(fileURLWithPath: path(ofLength: limit + 1))))
        // It says why (the number, the limit) and what to do.
        #expect(message.contains("\(limit + 1) characters") && message.contains("limit is \(limit)"))
        #expect(message.contains("Move it"))
        #expect(PrefixPath.problem(forPrefix: URL(fileURLWithPath: "/Users/me/Games/G-Player/Spaces/Main")) == nil)
    }

    @Test func lengthIsCountedTheWayWindowsDoes() {
        // UTF-16 units: Cyrillic letters are one each (two bytes in UTF-8), an emoji is two.
        #expect(PrefixPath.length(of: "/Ігри/Козаки") == 12)
        #expect(PrefixPath.length(of: "/x😀") == 4)
        // The kernel and Wine know /var, /tmp and /etc by their /private names.
        #expect(PrefixPath.length(of: "/var/folders/x") == 14 + 8)
        #expect(PrefixPath.length(of: "/tmp/x") == 6 + 8)
        #expect(PrefixPath.length(of: "/Users/me") == 9)
    }

    @Test func theLibraryFolderMustLeaveRoomForSpaceNames() throws {
        let longest = PrefixPath.maxLibraryRootLength
        let fine = URL(fileURLWithPath: path(ofLength: longest))
        #expect(PrefixPath.libraryRootProblem(fine) == nil)
        // Exactly room for the shortest space folder name, and no more.
        #expect(PrefixPath.nameRoom(in: LibraryPaths(root: fine).spaces) == PrefixPath.shortestName)
        let message = try #require(PrefixPath.libraryRootProblem(URL(fileURLWithPath: path(ofLength: longest + 1))))
        #expect(message.contains("\(longest + 1) characters") && message.contains("limit is \(longest)"))
        #expect(message.contains("Choose a folder"))
        #expect(PrefixPath.libraryRootProblem(LibraryPaths.defaultRoot) == nil)
    }

    @Test func aLongSpaceNameIsCutSoThePathStaysWithinTheLimit() throws {
        let root = URL(fileURLWithPath: "/tmp/gplayer-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SpaceManager(paths: LibraryPaths(root: root))
        let name = String(repeating: "Some very long game title ", count: 12)
        let first = try manager.folder(forNew: name)
        #expect(PrefixPath.problem(forPrefix: first) == nil)
        #expect(first.lastPathComponent.utf16.count <= PrefixPath.folderNameLimit(in: manager.paths.spaces))
        #expect(!first.lastPathComponent.hasSuffix(" "))
        // A second space of the same name gets " 2", still inside the limit.
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = try manager.folder(forNew: name)
        #expect(second != first && second.lastPathComponent.hasSuffix(" 2"))
        #expect(PrefixPath.problem(forPrefix: second) == nil)
        // A short name stays as it is.
        #expect(try manager.folder(forNew: "Main").lastPathComponent == "Main")
    }

    @Test func aLibraryFolderThatIsTooLongMakesNoSpaceAndWritesNothing() throws {
        let root = URL(fileURLWithPath: path(ofLength: PrefixPath.maxLibraryRootLength + 1, prefix: "/tmp/gplayer-tests-"))
        let manager = SpaceManager(paths: LibraryPaths(root: root))
        #expect(throws: ShellError.self) { try manager.folder(forNew: "Main") }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aBottleWithALongPathCantBeAdopted() throws {
        func found(_ path: String) -> FoundEnvironment {
            FoundEnvironment(name: "Bottle", url: URL(fileURLWithPath: path), originNote: "CrossOver", suggestedEngineID: "x",
                             presetID: nil, games: [], size: nil)
        }
        #expect(found("/Users/me/Library/Application Support/CrossOver/Bottles/Bottle").pathProblem == nil)
        let problem = try #require(found(path(ofLength: 200)).pathProblem)
        #expect(problem.contains("200 characters"))
    }
}

@Suite struct SafeNameTests {
    @Test func aNameIsCutAtTheLimitWithoutLeavingASpaceOrDotBehind() {
        #expect(Files.safeName("Hello World", maxLength: 6) == "Hello")
        #expect(Files.safeName("Hello. World", maxLength: 6) == "Hello")
        #expect(Files.safeName("Hello World", maxLength: 11) == "Hello World")
        #expect(Files.safeName("Hello", maxLength: 0) == "Untitled")
        // An emoji is two UTF-16 units; it isn't cut in half.
        #expect(Files.safeName("ab😀cd", maxLength: 3) == "ab")
        #expect(Files.safeName("ab😀cd", maxLength: 4) == "ab😀")
    }

    @Test func theUsualLimitIsEightyAndTheRestIsAsBefore() {
        #expect(Files.safeName(String(repeating: "x", count: 200)).count == 80)
        #expect(Files.safeName(#"a/b\c:d*e?f"g<h>i|j"#) == "a b c d e f g h i j")
        #expect(Files.safeName("  ..  ") == "Untitled")
    }
}
