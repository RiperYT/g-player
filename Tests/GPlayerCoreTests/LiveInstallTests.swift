import Foundation
import Testing
@testable import GPlayerCore

/// Real installs into a throwaway space, with the Wine Staging engine from the default library. Off unless
/// `GPLAYER_LIVE=1`: they download from Microsoft and take minutes.
///
///     GPLAYER_LIVE=1 swift test --filter LiveInstallTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GPLAYER_LIVE"] == "1"), .serialized, .timeLimit(.minutes(20)))
struct LiveInstallTests {
    @Test func baseComponentsInstallIntoANewSpace() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gplayer-live-\(UUID().uuidString)", isDirectory: true)
        let paths = LibraryPaths(root: root)
        try paths.createFolders()
        defer { try? fm.removeItem(at: root) }
        // Borrow the installed engine instead of downloading it again.
        try fm.removeItem(at: paths.engines)
        try fm.createSymbolicLink(at: paths.engines, withDestinationURL: LibraryPaths(root: LibraryPaths.defaultRoot).engines)
        let engine = try #require(EngineManager(paths: paths).engine(EngineCatalog.wineStaging))

        let space = try await SpaceManager(paths: paths).create(name: "Live", engine: engine, colorIndex: 0)
        let installer = RuntimeInstaller(paths: paths)
        let base = CompatResolver.baseComponents
        #expect(installer.missing(base, in: space) == base)
        do {
            try await installer.install(base, in: space, engine: engine) { fraction, message in
                print("live:", fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "…", message)
            }
        } catch {
            await WineLauncher.killAll(engine: engine, space: space)      // no wineserver left for a deleted prefix
            throw error
        }
        await WineLauncher.killAll(engine: engine, space: space)

        #expect(installer.installed(in: space).isSuperset(of: base))
        #expect(installer.missing(base, in: space).isEmpty)
        #expect(installer.failed(in: space).isEmpty)
        for file in ["windows/system32/vcruntime140.dll", "windows/syswow64/vcruntime140.dll",
                     "windows/system32/msvcp140.dll", "windows/system32/d3dcompiler_47.dll",
                     "windows/syswow64/d3dcompiler_47.dll"] {
            #expect(fm.fileExists(atPath: space.driveC.appendingPathComponent(file).path), "\(file)")
        }
    }
}
