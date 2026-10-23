import Foundation
import Testing
@testable import GPlayerCore

@Suite struct DiskSpaceTests {
    @Test func aShortfallSaysWhatIsNeededAndWhatIsThere() throws {
        let message = try #require(DiskSpace.problem(needing: 2_700_000_000, available: 900_000_000, for: "Installing G-Player Wine"))
        #expect(message.hasPrefix("Installing G-Player Wine needs about"))
        #expect(message.contains(Int64(2_700_000_000).formattedBytes) && message.contains(Int64(900_000_000).formattedBytes))
        #expect(message.contains("Free some space"))
    }

    @Test func enoughRoomOrNoAnswerOrNothingNeededIsNoProblem() {
        #expect(DiskSpace.problem(needing: 1_000, available: 1_000, for: "x") == nil)
        #expect(DiskSpace.problem(needing: 1_000, available: 5_000, for: "x") == nil)
        #expect(DiskSpace.problem(needing: 1_000, available: nil, for: "x") == nil)
        #expect(DiskSpace.problem(needing: 0, available: 0, for: "x") == nil)
    }

    @Test func theRoomOnADiskIsToldAlsoForAFolderThatIsNotThereYet() throws {
        let tmp = TempFolder()
        let here = try #require(DiskSpace.available(at: tmp.url))
        #expect(here > 0)
        #expect(DiskSpace.available(at: tmp.url.appendingPathComponent("a/b/c")) != nil)
        #expect(DiskSpace.sameVolume(tmp.url, tmp.url.appendingPathComponent("not/made/yet")))
        #expect(!DiskSpace.sameVolume(tmp.url, URL(fileURLWithPath: "/dev")))
    }

    @Test func theFirstRunsEngineNeedsAboutThreeGigabytes() {
        let needed = EngineCatalog.firstRunDiskBytes(installed: [])
        #expect(needed > 2_900_000_000 && needed < 3_200_000_000)
        // What is installed already isn't counted again. A Wine Staging that is there doesn't lower it: G-Player Wine takes
        // the same room unpacked, and Gcenx's archive is counted among its files (the figure only has to be enough).
        #expect(EngineCatalog.firstRunDiskBytes(installed: [EngineCatalog.wineStaging]) == needed)
        #expect(EngineCatalog.firstRunDiskBytes(installed: [EngineCatalog.crossover]) == 0)
        // One engine: what it takes unpacked, and room for its files while it installs (both of Wine Staging's archives).
        let one = EngineCatalog.diskBytes(installing: [EngineCatalog.wineStaging])
        #expect(one == EngineCatalog.wineStaging.installedBytes + 193_105_336 + 3_900_000)
    }

    @Test func everyEngineThatIsDownloadedSaysHowMuchRoomItTakes() {
        for info in EngineCatalog.all where !info.downloads.isEmpty {
            #expect(info.installedBytes > info.downloads.map(\.approximateBytes).max()!)
            // A narrowed copy of the engine (`limited`) keeps it.
            #expect(info.limited(to: info.backends).installedBytes == info.installedBytes)
        }
    }

    @Test func installingNothingNeedsNothingChecked() {
        let tmp = TempFolder()
        #expect(EngineManager(paths: LibraryPaths(root: tmp.url)).diskProblem(installing: []) == nil)
    }
}

@Suite struct StoppableShellTests {
    @Test func aProcessThatFinishesGivesItsOutput() async throws {
        let result = try await Shell.runStoppable(URL(fileURLWithPath: "/bin/echo"), ["hello"])
        #expect(result.succeeded && result.stdout == "hello\n")
        let failed = try await Shell.runStoppable(URL(fileURLWithPath: "/bin/ls"), ["/no/such/place"])
        #expect(!failed.succeeded && !failed.stderr.isEmpty)
    }

    @Test func cancellingTheTaskStopsTheProcess() async throws {
        let started = Date()
        let task = Task { try await Shell.runStoppable(URL(fileURLWithPath: "/bin/sleep"), ["60"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

@Suite struct ImportProgressTests {
    private func makeGame(in tmp: TempFolder) -> URL {
        tmp.file("src/Game/Game.exe", bytes: 20_000)
        tmp.file("src/Game/data/a.pak", bytes: 50_000)
        tmp.file("src/Game/data/deeper/b.pak", bytes: 30_000)
        return tmp.url.appendingPathComponent("src/Game")
    }

    @Test func aListingAddsUpTheFilesNotTheFolders() {
        let listing = """
        drwxr-xr-x  0 user   staff       0 Oct 23 12:00 Game/
        -rw-r--r--  0 user   staff   12345 Oct 23 12:00 Game/Game.exe
        -rw-r--r--  0 user   staff     655 Oct 23 12:00 Game/read me first.txt
        lrwxr-xr-x  0 user   staff       0 Oct 23 12:00 Game/link -> Game.exe
        -rw-r--r--  0 0      0           5 Jan  1  2020 Game/data/x.bin
        """
        #expect(ArchiveExtractor.uncompressedBytes(fromListing: listing) == 12345 + 655 + 5)
        #expect(ArchiveExtractor.uncompressedBytes(fromListing: "") == 0)
        #expect(ArchiveExtractor.uncompressedBytes(fromListing: "bsdtar: Error opening archive") == 0)
    }

    @Test func aZipsListingGivesWhatItHoldsUnpacked() async throws {
        let tmp = TempFolder()
        tmp.file("src/Inner/Game.exe", bytes: 4000)
        tmp.file("src/Inner/data/x.bin", bytes: 6000)
        let zip = tmp.url.appendingPathComponent("g.zip")
        let r = try await Shell.run(Shell.tool("ditto"), ["-c", "-k", "--keepParent", tmp.url.appendingPathComponent("src/Inner").path, zip.path])
        #expect(r.succeeded)
        let listed = try #require(await ArchiveExtractor.uncompressedBytes(of: zip))
        #expect(listed >= 10_000)
        // Only archives with a cheap listing are listed.
        #expect(await ArchiveExtractor.uncompressedBytes(of: tmp.url.appendingPathComponent("x.tar.gz")) == nil)
    }

    @Test func aFolderPlanKnowsItsSizeAndWhatItNeedsFree() async {
        let tmp = TempFolder()
        let game = makeGame(in: tmp)
        let destination = tmp.dir("space/drive_c/Games")
        let plan = await GameImporter.plan(.folder(game), move: false, destination: destination)
        #expect(plan.totalBytes >= 100_000)
        // Same disk: a move is a rename, a copy is a clone on APFS and takes the folder's size elsewhere.
        #expect(plan.neededBytes == 0 || plan.neededBytes == plan.totalBytes)
        let move = await GameImporter.plan(.folder(game), move: true, destination: destination)
        #expect(move.neededBytes == 0)
    }

    @Test func whatDoesntFitIsRefusedBeforeAnythingIsWritten() throws {
        let tmp = TempFolder()
        let huge = GameImporter.ImportPlan(totalBytes: .max / 4, neededBytes: .max / 4)
        let message = try #require(GameImporter.spaceProblem(for: huge, destination: tmp.url, title: "My Game"))
        #expect(message.hasPrefix("Adding “My Game” needs about"))
        #expect(GameImporter.spaceProblem(for: GameImporter.ImportPlan(totalBytes: 500, neededBytes: 0), destination: tmp.url, title: "x") == nil)
        // The Mac keeps some room for itself.
        let small = GameImporter.ImportPlan(totalBytes: 10, neededBytes: 10)
        let free = try #require(DiskSpace.available(at: tmp.url))
        let tight = GameImporter.ImportPlan(totalBytes: free, neededBytes: free)
        #expect(GameImporter.spaceProblem(for: small, destination: tmp.url, title: "x") == nil)
        #expect(GameImporter.spaceProblem(for: tight, destination: tmp.url, title: "x") != nil)
    }

    @Test func copyingReportsProgressAndKeepsLinksAndFiles() async throws {
        let tmp = TempFolder()
        let game = makeGame(in: tmp)
        try FileManager.default.createSymbolicLink(atPath: game.appendingPathComponent("latest.exe").path, withDestinationPath: "Game.exe")
        let s = space(at: tmp.prefix("S"))
        let plan = await GameImporter.plan(.folder(game), move: false, destination: s.driveC)
        let seen = LockedValue<[Int64]>([])
        let folder = try await GameImporter.copyIntoSpace(.folder(game), space: s, title: "Game", totalBytes: plan.totalBytes) { done, _ in
            seen.update { $0.append(done) }
        }
        #expect(folder.lastPathComponent == "Game" && folder.deletingLastPathComponent().lastPathComponent == "Games")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("data/deeper/b.pak").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("latest.exe").path) == "Game.exe")
        #expect(FileManager.default.fileExists(atPath: game.appendingPathComponent("Game.exe").path))        // a copy leaves the original
        #expect((seen.get().last ?? 0) >= 100_000)
        #expect(seen.get() == seen.get().sorted())
    }

    @Test func stoppingACopyRemovesWhatWasCopiedAndKeepsTheOriginal() async throws {
        let tmp = TempFolder()
        let game = makeGame(in: tmp)
        let s = space(at: tmp.prefix("S"))
        let outcome = await Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }                              // stopped before the first file
            do { _ = try await GameImporter.copyIntoSpace(.folder(game), space: s, title: "Game"); return nil } catch { return error }
        }.value
        #expect(outcome is CancellationError)
        #expect(!FileManager.default.fileExists(atPath: s.driveC.appendingPathComponent("Games/Game").path))
        #expect(FileManager.default.fileExists(atPath: game.appendingPathComponent("Game.exe").path))
    }

    @Test func aMoveOnTheSameDiskIsARename() async throws {
        let tmp = TempFolder()
        let game = makeGame(in: tmp)
        let s = space(at: tmp.prefix("S"))
        let folder = try await GameImporter.copyIntoSpace(.folder(game), space: s, title: "Game", move: true)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Game.exe").path))
        #expect(!FileManager.default.fileExists(atPath: game.path))
    }

    @Test func unpackingReportsWhatCameAndStoppingLeavesNothingBehind() async throws {
        let tmp = TempFolder()
        tmp.file("src/Inner/Game.exe", bytes: 4000)
        let zip = tmp.url.appendingPathComponent("g.zip")
        let r = try await Shell.run(Shell.tool("ditto"), ["-c", "-k", "--keepParent", tmp.url.appendingPathComponent("src/Inner").path, zip.path])
        #expect(r.succeeded)
        let games = tmp.dir("space/Games")
        let out = try await ArchiveExtractor.extract(zip, into: games, name: "Game", expectedBytes: 4000) { _, _ in }
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Game.exe").path))
        // Stopped: the half-unpacked folder is removed and nothing is added to Games.
        let before = try FileManager.default.contentsOfDirectory(atPath: games.path)
        let outcome = await Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await ArchiveExtractor.extract(zip, into: games, name: "Game 2"); return nil } catch { return error }
        }.value
        #expect(outcome is CancellationError)
        #expect(try FileManager.default.contentsOfDirectory(atPath: games.path) == before)
    }
}

@Suite struct StoppableShellTimeoutTests {
    @Test func aProcessThatRunsPastItsTimeIsStopped() async throws {
        let started = Date()
        await #expect(throws: Supervised.TimedOut.self) {
            _ = try await Shell.runStoppable(URL(fileURLWithPath: "/bin/sleep"), ["60"], timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 10)
        // One that finishes in time is unaffected.
        let quick = try await Shell.runStoppable(URL(fileURLWithPath: "/bin/echo"), ["ok"], timeout: 30)
        #expect(quick.succeeded && quick.stdout == "ok\n")
    }
}

@Suite struct DiscardEmptySpaceTests {
    @Test func aSpaceWithNoGameFilesHoldsNoGames() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("S"))
        #expect(SpaceManager.holdsNoGames(s))                                           // no Games folder at all
        try FileManager.default.createDirectory(at: s.driveC.appendingPathComponent("Games"), withIntermediateDirectories: true)
        #expect(SpaceManager.holdsNoGames(s))
        tmp.file("S/drive_c/Games/.DS_Store")
        #expect(SpaceManager.holdsNoGames(s))
        tmp.file("S/drive_c/Games/Some Game/Game.exe")
        #expect(!SpaceManager.holdsNoGames(s))
    }

    @Test func aSpaceThatIsDiscardedIsGoneForGoodAndAnExternalOneIsNeverTouched() throws {
        let tmp = TempFolder()
        let manager = SpaceManager(paths: LibraryPaths(root: tmp.url.appendingPathComponent("Library")))
        let made = space(at: tmp.prefix("Library/Spaces/Made"))
        try manager.delete(made, permanently: true)
        #expect(!FileManager.default.fileExists(atPath: made.url.path))
        // A managed record pointing outside the library's Spaces folder is never deleted for good.
        let stray = space(at: tmp.prefix("Elsewhere/Made"))
        #expect(throws: ShellError.self) { try manager.delete(stray, permanently: true) }
        #expect(FileManager.default.fileExists(atPath: stray.url.path))
        var found = space(at: tmp.prefix("Bottles/Mine"))
        found.origin = .external
        try manager.delete(found, permanently: true)
        #expect(FileManager.default.fileExists(atPath: found.url.path))
    }
}
