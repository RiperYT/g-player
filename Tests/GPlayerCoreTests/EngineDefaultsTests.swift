import Foundation
import Testing
@testable import GPlayerCore

@Suite struct EngineDefaultsTests {
    let staging = EngineCatalog.wineStaging
    let gplayerWine = EngineCatalog.crossover

    @Test func newSpacesGetGPlayerWineAndThePickersListItFirst() {
        #expect(EngineCatalog.defaultForNewSpaces.id == gplayerWine.id)
        #expect(EngineCatalog.all.first?.id == gplayerWine.id)
        #expect(EngineCatalog.all.map(\.id) == [gplayerWine.id, staging.id, EngineCatalog.gptk.id])
        #expect(EngineCatalog.all.filter(\.isRecommended).map(\.id) == [gplayerWine.id])
    }

    @Test func existingEngineIDsStillResolve() {
        // Spaces keep the engine they were made with; an id nobody knows has no entry, which the callers read as Wine Staging.
        #expect(EngineCatalog.info("wine-staging-11.18")?.kind == .wineStaging)
        #expect(EngineCatalog.info("wine-cx-26.3.0-2")?.kind == .crossover)
        #expect(EngineCatalog.info("wine-cx-26.3.0-1")?.kind == .crossover)             // retired, but still found
        #expect(EngineCatalog.info("gptk")?.kind == .gptk)
        #expect(EngineCatalog.info("wine-from-the-future") == nil)
    }

    @Test func aRetiredEngineIsKnownButNeverOffered() {
        let revision1 = EngineCatalog.crossoverRevision1
        #expect(revision1.id == "wine-cx-26.3.0-1" && gplayerWine.id == "wine-cx-26.3.0-2")
        #expect(EngineCatalog.retired.map(\.id) == [revision1.id])
        #expect(EngineCatalog.known.map(\.id) == EngineCatalog.all.map(\.id) + [revision1.id])
        // Not in the pickers, the first run or Settings (`all`), not for a new space, not recommended.
        #expect(!EngineCatalog.all.contains { $0.id == revision1.id })
        #expect(!EngineCatalog.firstRunInstalls.contains { $0.id == revision1.id })
        #expect(EngineCatalog.engineForNewSpace(installed: [revision1]).id == gplayerWine.id)
        #expect(EngineCatalog.firstRunEngine(installed: [revision1]) == nil)
        #expect(!revision1.isRecommended && revision1.isRetired && !gplayerWine.isRetired && !staging.isRetired)
        // Limiting its backends (what a launch plans with) keeps it retired.
        #expect(revision1.limited(to: [.wined3d]).replacedBy == gplayerWine.id)
    }

    @Test func aRetiredEngineHasItsReplacement() {
        #expect(EngineCatalog.replacement(of: EngineCatalog.crossoverRevision1)?.id == gplayerWine.id)
        #expect(EngineCatalog.replacement(of: gplayerWine) == nil)
        #expect(EngineCatalog.replacement(of: staging) == nil)
        // The same Wine under another revision: what was learned on one holds on the other.
        #expect(EngineCatalog.isRevision("wine-cx-26.3.0-1", of: gplayerWine))
        #expect(EngineCatalog.isRevision(gplayerWine.id, of: gplayerWine))
        #expect(!EngineCatalog.isRevision(staging.id, of: gplayerWine))
        #expect(!EngineCatalog.isRevision("wine-from-the-future", of: gplayerWine))
        #expect(!EngineCatalog.isRevision(gplayerWine.id, of: staging))
        // A retired engine whose replacement isn't in the catalogue has none, and never loops.
        let orphan = EngineInfo(id: "o", name: "O", version: "1", kind: .crossover, summary: "", backends: [], downloads: [],
                                replacedBy: "nobody")
        #expect(EngineCatalog.replacement(of: orphan) == nil)
    }

    @Test func revisionOneKeepsItsPinsAndRevisionTwoHasItsOwn() {
        let one = EngineCatalog.crossoverRevision1.downloads[0]
        #expect(one.url.absoluteString == "https://github.com/RiperYT/g-player/releases/download/engine-cx26.3.0-1/g-player-engine-cx26.3.0-1.tar.xz")
        #expect(one.fileName == "g-player-engine-cx26.3.0-1.tar.xz")
        #expect(one.sha256 == "c10b3dff14429944f99ce660ff294c11d58dff3c39df9a0b91bdfd114e223686" && one.approximateBytes == 283_981_528)
        let two = gplayerWine.downloads[0]
        #expect(two.url.absoluteString == "https://github.com/RiperYT/g-player/releases/download/engine-cx26.3.0-2/g-player-engine-cx26.3.0-2.tar.xz")
        #expect(two.fileName == "g-player-engine-cx26.3.0-2.tar.xz" && two.role == .engine)
        // Both use the same runtime libraries and DXVK.
        #expect(EngineCatalog.crossoverRevision1.downloads.dropFirst().map(\.sha256) == gplayerWine.downloads[1...2].map(\.sha256))
    }

    /// Whatever the real archive of revision 2 turns out to be, every pin has the shape a pin must have.
    @Test(arguments: EngineCatalog.known.flatMap { engine in engine.downloads.map { (engine.id, $0) } })
    func everyPinIsWellFormed(engineID: String, download: PinnedDownload) {
        #expect(download.sha256.count == 64 && download.sha256.allSatisfy { "0123456789abcdef".contains($0) }, "\(engineID) \(download.fileName)")
        #expect(download.url.scheme == "https" && download.url.lastPathComponent == download.fileName)
        #expect(download.approximateBytes > 0)
    }

    @Test func firstRunInstallsStagingBeforeGPlayerWine() {
        #expect(EngineCatalog.firstRunInstalls.map(\.id) == [staging.id, gplayerWine.id])
        // G-Player Wine's runtime libraries come from Staging's download, so it must be there first.
        #expect(gplayerWine.downloads.contains { $0.role == .runtimeLibraries && $0.sha256 == staging.downloads[0].sha256 })
    }

    @Test func aNewSpaceNeedsNoDownloadWhileAnEngineIsInstalled() {
        #expect(EngineCatalog.engineForNewSpace(installed: [staging, gplayerWine]).id == gplayerWine.id)
        #expect(EngineCatalog.engineForNewSpace(installed: [gplayerWine]).id == gplayerWine.id)
        #expect(EngineCatalog.engineForNewSpace(installed: [staging]).id == staging.id)         // offline: nothing to download
        #expect(EngineCatalog.engineForNewSpace(installed: [staging, EngineCatalog.gptk]).id == staging.id)
        #expect(EngineCatalog.engineForNewSpace(installed: []).id == gplayerWine.id)            // nothing yet: the recommended one
        #expect(EngineCatalog.engineForNewSpace(installed: [EngineCatalog.gptk]).id == gplayerWine.id)
    }

    @Test func firstRunSpacesFallBackToStagingOnlyWhenGPlayerWineIsMissing() {
        #expect(EngineCatalog.firstRunEngine(installed: [staging, gplayerWine])?.id == gplayerWine.id)
        #expect(EngineCatalog.firstRunEngine(installed: [gplayerWine])?.id == gplayerWine.id)
        #expect(EngineCatalog.firstRunEngine(installed: [staging])?.id == staging.id)           // G-Player Wine failed
        #expect(EngineCatalog.firstRunEngine(installed: []) == nil)                              // wait for an engine
        #expect(EngineCatalog.firstRunEngine(installed: [EngineCatalog.gptk]) == nil)
    }

    @Test func gPlayerWineIsNamedByWhatItIsBuiltFrom() {
        #expect(staging.displayName == "Wine Staging 11.18")
        #expect(gplayerWine.displayName == "G-Player Wine (Wine 11 from CrossOver 26.3)")
        #expect(gplayerWine.limited(to: [.wined3d]).displayName == gplayerWine.displayName)
        #expect(gplayerWine.summary.contains("DirectX 9–11") && gplayerWine.summary.contains("DirectX 12"))
    }

    @Test func eachEngineDownloadsIntoItsOwnFolder() {
        // Both engines download the same DXVK archive and delete it after unpacking; one path would let them break each other.
        let manager = EngineManager(paths: LibraryPaths(root: URL(fileURLWithPath: "/tmp/gplayer-unused")))
        let dxvk = { (info: EngineInfo) in info.downloads.first { $0.role == .dxvk }! }
        #expect(dxvk(staging).sha256 == dxvk(gplayerWine).sha256)
        #expect(manager.downloadFile(dxvk(staging), of: staging) != manager.downloadFile(dxvk(gplayerWine), of: gplayerWine))
        #expect(manager.downloadFile(dxvk(staging), of: staging).lastPathComponent == dxvk(staging).fileName)
        let runtime = gplayerWine.downloads.first { $0.role == .runtimeLibraries }!
        #expect(manager.downloadFile(runtime, of: gplayerWine) != manager.downloadFile(staging.downloads[0], of: staging))
    }

    @Test func onlyAConnectionThatIsDownCountsAsAConnectionFailure() {
        #expect(EngineManager.isConnectionFailure(URLError(.notConnectedToInternet)))
        #expect(EngineManager.isConnectionFailure(URLError(.timedOut)))
        #expect(EngineManager.isConnectionFailure(URLError(.cannotFindHost)))
        #expect(!EngineManager.isConnectionFailure(URLError(.badServerResponse)))
        #expect(!EngineManager.isConnectionFailure(ShellError.failed("x didn't match its checksum. Try again.")))
        #expect(!EngineManager.isConnectionFailure(CancellationError()))
    }

    @Test func firstRunDownloadSizeSkipsLibrariesStagingAlreadyBrings() {
        let stagingBytes = staging.downloadBytes(wineStagingInstalled: false)
        let withoutLibraries = gplayerWine.downloadBytes(wineStagingInstalled: true)
        let withLibraries = gplayerWine.downloadBytes(wineStagingInstalled: false)
        #expect(withLibraries - withoutLibraries == staging.downloads[0].approximateBytes)
        // Nothing installed: Staging, then G-Player Wine reusing Staging's libraries, so the archive is downloaded once.
        #expect(EngineCatalog.firstRunBytes(installed: []) == stagingBytes + withoutLibraries)
        #expect(EngineCatalog.firstRunBytes(installed: [staging]) == withoutLibraries)
        #expect(EngineCatalog.firstRunBytes(installed: [gplayerWine]) == stagingBytes)
        #expect(EngineCatalog.firstRunBytes(installed: [staging, gplayerWine]) == 0)
        #expect(EngineCatalog.firstRunBytes(installed: [EngineCatalog.gptk]) == stagingBytes + withoutLibraries)
    }
}
