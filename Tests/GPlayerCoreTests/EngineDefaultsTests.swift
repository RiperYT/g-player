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
        #expect(EngineCatalog.info("wine-cx-26.3.0-1")?.kind == .crossover)
        #expect(EngineCatalog.info("gptk")?.kind == .gptk)
        #expect(EngineCatalog.info("wine-from-the-future") == nil)
    }

    @Test func firstRunInstallsStagingBeforeGPlayerWine() {
        #expect(EngineCatalog.firstRunInstalls.map(\.id) == [staging.id, gplayerWine.id])
        // G-Player Wine's runtime libraries come from Staging's download, so it must be there first.
        #expect(gplayerWine.downloads.contains { $0.role == .runtimeLibraries && $0.sha256 == staging.downloads[0].sha256 })
    }

    @Test func aNewSpaceNeedsNoDownloadWhileAnEngineIsInstalled() {
        #expect(EngineCatalog.engineForNewSpace(installed: [staging, gplayerWine]).id == gplayerWine.id)
        #expect(EngineCatalog.engineForNewSpace(installed: [gplayerWine]).id == gplayerWine.id)
        #expect(EngineCatalog.engineForNewSpace(installed: [staging]).id == staging.id)         // offline: no 288 MB download
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
