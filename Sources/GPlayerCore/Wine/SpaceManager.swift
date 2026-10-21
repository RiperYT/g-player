import Foundation

/// Creates Windows environments and keeps their graphics DLLs right for each launch.
public struct SpaceManager: Sendable {
    public let paths: LibraryPaths

    public init(paths: LibraryPaths) { self.paths = paths }

    /// Makes a new prefix in the library's Spaces folder. Takes about half a minute the first time.
    public func create(name: String, engine: Engine, colorIndex: Int, presetID: String? = nil) async throws -> Space {
        try paths.createFolders()
        let folder = Files.uniqueURL(in: paths.spaces, name: Files.safeName(name))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let space = Space(name: name, path: folder.path, engineID: engine.info.id, origin: .managed,
                          presetID: presetID, colorIndex: colorIndex)
        try await initialize(space, engine: engine)
        return space
    }

    /// `wineboot --init` plus the settings Mac users expect. Safe to run again.
    public func initialize(_ space: Space, engine: Engine) async throws {
        let boot = try await WineLauncher.runTool(engine: engine, space: space, ["wineboot", "--init"])
        await WineLauncher.waitForAll(engine: engine, space: space)
        guard space.exists else {
            throw ShellError.failed("Wine couldn't create the space. \(boot.stderr.suffix(400))")
        }
        // Command works like Ctrl in Windows programs (copy, paste, game shortcuts).
        try await WineLauncher.runTool(engine: engine, space: space,
            ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "LeftCommandIsCtrl", "/d", "y", "/f"])
        try FileManager.default.createDirectory(at: space.driveC.appendingPathComponent("Games"), withIntermediateDirectories: true)
    }

    /// Puts DXVK's DLLs into the space when the launch uses DXVK. Wine prefers its builtin DLLs unless the
    /// launch says `n,b`, so the copies are harmless for WineD3D launches.
    public func prepareGraphics(_ backend: GraphicsBackend, engine: Engine, space: Space) throws {
        guard engine.info.resolve(backend) == .dxvk, let dxvk = engine.dxvk else { return }
        let fm = FileManager.default
        for (arch, folder) in [("x64", "system32"), ("x32", "syswow64")] {
            let to = space.driveC.appendingPathComponent("windows/\(folder)")
            guard fm.fileExists(atPath: to.path) else { continue }
            for dll in ["d3d11.dll", "d3d10core.dll"] {
                let src = dxvk.appendingPathComponent("\(arch)/\(dll)"), dst = to.appendingPathComponent(dll)
                guard let new = fm.contents(atPath: src.path) else { continue }
                if fm.contents(atPath: dst.path) == new { continue }
                // Keep Wine's own copy once, so the space can go back to plain Wine.
                let backup = to.appendingPathComponent(dll + ".gplayer-wine")
                if !fm.fileExists(atPath: backup.path), fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: dst, to: backup) }
                try new.write(to: dst, options: .atomic)
            }
        }
    }

    /// Deletes a managed space and everything in it.
    public func delete(_ space: Space) throws {
        guard space.origin == .managed else { return }
        try FileManager.default.trashItem(at: space.url, resultingItemURL: nil)
    }

    /// True when `url` looks like a Wine prefix.
    public static func isPrefix(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("drive_c/windows").path)
            && fm.fileExists(atPath: url.appendingPathComponent("system.reg").path)
    }
}
