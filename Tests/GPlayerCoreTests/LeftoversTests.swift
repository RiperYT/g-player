import Foundation
import Testing
@testable import GPlayerCore

/// What a quit or a crash leaves is found by G-Player's own temporary names, and nothing of the user's is taken for it.
@Suite struct LeftoversTests {
    @Test func aDownloadThatNeverEndedIsRecognisedByItsName() {
        for name in ["vc_redist.x64.exe.1A2B3C4D", "vc_redist.x64.exe.1A2B3C4D.part", "vc_redist.x64.exe.1A2B3C4D.part.part",
                     "winetricks.00FF00FF.part.part", "d3dcompiler_47_32.dll.0A0B0C0D"] {
            #expect(Leftovers.isComponentDownload(name), "\(name)")
        }
        // A file as the publisher names it, a part that isn't G-Player's, a name that merely looks alike.
        for name in ["vc_redist.x64.exe", "d3dx9_43.cab", "setup.part", "archive.7z.001", "x.1a2b3c4d", "x.1A2B3C4", "x.1A2B3C4DE", "x.GGGGGGGG",
                     ".1A2B3C4D", "1A2B3C4D", "movie.mp4.part"] {
            #expect(!Leftovers.isComponentDownload(name), "\(name)")
        }
    }

    @Test func anUnpackedInstallerAndAScratchFolderAreRecognisedByTheirNames() {
        #expect(Leftovers.isInstallFolder("install-1A2B3C4D"))
        #expect(!Leftovers.isInstallFolder("install-games") && !Leftovers.isInstallFolder("install-1A2B3C4") && !Leftovers.isInstallFolder("Install-1A2B3C4D"))
        #expect(Leftovers.isScratchFolder("tmp-\(UUID().uuidString)"))
        #expect(!Leftovers.isScratchFolder("tmp-notauuid") && !Leftovers.isScratchFolder("temp-\(UUID().uuidString)"))
    }

    @Test func cleaningRemovesOnlyThoseAndLeavesTheRest() throws {
        let tmp = TempFolder()
        let paths = LibraryPaths(root: tmp.url)
        let scratch = "tmp-\(UUID().uuidString)"
        // Leftovers:
        let leftovers = [tmp.file("Downloads/components/vc_redist.x64.exe.1A2B3C4D.part.part"),
                         tmp.file("Downloads/components/d3dx9_43.cab.2B3C4D5E"),
                         tmp.file("Downloads/components/\(scratch)/work.txt"),
                         tmp.file("Engines/tools/winetricks.3C4D5E6F.part"),
                         tmp.file("Downloads/install-4D5E6F70/setup.exe")]
        // What isn't:
        let kept = [tmp.file("Downloads/components/vc_redist.x64.exe"),
                    tmp.file("Downloads/components/notes.txt"),
                    tmp.file("Engines/tools/winetricks"),
                    tmp.file("Downloads/my-installers/setup.exe"),
                    tmp.file("Downloads/SteamSetup.exe"),
                    tmp.file("Downloads/wine-cx-26.3.0-1/engine.tar.xz.part")]       // an engine's own download: `EngineManager`'s
        Leftovers.clean(paths, processes: [])
        for url in leftovers { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        for url in kept { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
    }

    @Test func anInstallerThatStillRunsKeepsItsFolder() throws {
        let tmp = TempFolder()
        let paths = LibraryPaths(root: tmp.url)
        let running = tmp.dir("Downloads/install-AAAAAAAA")
        let working = tmp.dir("Downloads/install-BBBBBBBB/Setup")
        let idle = tmp.dir("Downloads/install-CCCCCCCC")
        let processes = [
            WineProcess(pid: 10, command: "\(running.path)/setup.exe /S"),                                  // started from the Mac path
            WineProcess(pid: 11, command: "C:\\setup.exe", directory: working.path),                         // works inside it
            WineProcess(pid: 12, command: "C:\\Program Files\\Steam\\steam.exe", directory: "/Users/me/x")]  // something else
        Leftovers.clean(paths, processes: processes)
        #expect(FileManager.default.fileExists(atPath: running.path))
        #expect(FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("Downloads/install-BBBBBBBB").path))
        #expect(!FileManager.default.fileExists(atPath: idle.path))
        // A folder that only starts with the same letters isn't the one in use.
        #expect(!Leftovers.isInUse(tmp.dir("Downloads/install-AAAAAAAA2"), by: processes))
    }

    @Test func aDownloadThatFailsLeavesNothingInTheComponentCache() async throws {
        let tmp = TempFolder()
        let missing = tmp.url.appendingPathComponent("server/none.dll")                 // a file: link to nothing
        let cache = tmp.url.appendingPathComponent("cache")
        await #expect(throws: (any Error).self) {
            _ = try await RuntimeInstaller.fetch(PinnedDownload(url: missing, fileName: "none.dll", sha256: "0", approximateBytes: 1), into: cache)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { Leftovers.isComponentDownload($0) }.isEmpty)
    }
}
