import Foundation
import Testing
@testable import GPlayerCore

/// A real G-Player Wine install into a throwaway library, GStreamer included: the official package is downloaded (or
/// taken from the library's Downloads folder when it is already there with the pinned checksum), expanded with pkgutil
/// and the engine's list copied in. Off unless `GPLAYER_LIVE=1`; it downloads about 450 MB.
///
///     GPLAYER_LIVE=1 GPLAYER_LIVE_ROOT=/private/tmp/gplayer-live swift test --filter LiveEngineInstallTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GPLAYER_LIVE"] == "1"), .serialized, .timeLimit(.minutes(30)))
struct LiveEngineInstallTests {
    @Test func gPlayerWineInstallsWithGStreamer() async throws {
        let root = ProcessInfo.processInfo.environment["GPLAYER_LIVE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("gplayer-live-\(UUID().uuidString.prefix(8))")
        let manager = EngineManager(paths: LibraryPaths(root: root))
        let engine = try await manager.install(EngineCatalog.crossover) { fraction, message in print("live:", Int(fraction * 100), message) }

        let manifest = try #require(try GStreamerRuntime.manifest(in: engine.wineRoot.deletingLastPathComponent()))
        #expect(!manifest.files.isEmpty)
        for path in manifest.files {
            #expect(FileManager.default.fileExists(atPath: engine.wineRoot.appendingPathComponent(path).path), "\(path)")
        }
        // The libraries GStreamer leaves to Gcenx's copy are there too, and nothing of the expanded package is left.
        for lib in ["libintl.8.dylib", "libz.1.dylib", "libfreetype.6.dylib"] {
            #expect(FileManager.default.fileExists(atPath: engine.wineRoot.appendingPathComponent("lib/\(lib)").path), "\(lib)")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: engine.wineRoot.deletingLastPathComponent().path)
        #expect(Set(leftovers).isSubset(of: ["wine", "dxvk", "licenses", "ENGINE.json", "gstreamer-files.txt"]), "\(leftovers)")

        let space = Space(name: "Live", path: root.appendingPathComponent("Spaces/Live").path, engineID: engine.info.id, origin: .managed)
        let env = WineEnvironment.make(engine: engine, space: space, backend: .dxvk)
        #expect(env["GST_PLUGIN_SYSTEM_PATH_1_0"] == engine.wineRoot.appendingPathComponent("lib/gstreamer-1.0").path)
    }
}
