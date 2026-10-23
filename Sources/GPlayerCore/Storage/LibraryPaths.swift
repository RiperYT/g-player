import Foundation

/// The library folder the user picked on first launch (default `~/Games/G-Player`).
///
///     G-Player/
///       library.json      spaces, games, settings that travel with the library
///       library.json.previous   the file as it was before the last change
///       Spaces/<name>/    Wine prefixes G-Player created (drive_c, registry…)
///       Engines/<id>/     downloaded Wine engines and DXVK
///       Covers/           cover art (custom and cached store art)
///       Logs/             one log per launch
///       Downloads/        installers while they run
///       Tools/            programs G-Player downloads and runs on their own (Legendary, with its settings)
public struct LibraryPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/G-Player", isDirectory: true)
    }

    public var libraryFile: URL { root.appendingPathComponent("library.json") }
    public var previousFile: URL { root.appendingPathComponent("library.json.previous") }
    public var spaces: URL { root.appendingPathComponent("Spaces", isDirectory: true) }
    public var engines: URL { root.appendingPathComponent("Engines", isDirectory: true) }
    public var covers: URL { root.appendingPathComponent("Covers", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    /// Programs G-Player downloads and runs as separate programs (`Legendary`). Made when one is first needed.
    public var tools: URL { root.appendingPathComponent("Tools", isDirectory: true) }
    /// Apple's D3DMetal, copied from the user's own Game Porting Toolkit (`D3DMetalStore`).
    public var d3dMetal: URL { root.appendingPathComponent("D3DMetal", isDirectory: true) }

    public func createFolders() throws {
        for dir in [root, spaces, engines, covers, logs, downloads] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
