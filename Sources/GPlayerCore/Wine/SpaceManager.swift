import Foundation

/// Creates Windows environments and keeps their graphics DLLs right for each launch.
public struct SpaceManager: Sendable {
    public let paths: LibraryPaths

    public init(paths: LibraryPaths) { self.paths = paths }

    /// Makes a new prefix in the library's Spaces folder. Takes about half a minute the first time.
    public func create(name: String, engine: Engine, colorIndex: Int, presetID: String? = nil) async throws -> Space {
        let folder = try self.folder(forNew: name)                      // before anything is written or Wine runs
        try paths.createFolders()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let space = Space(name: name, path: folder.path, engineID: engine.info.id, origin: .managed,
                          presetID: presetID, colorIndex: colorIndex)
        try await initialize(space, engine: engine)
        return space
    }

    /// Where a new space named `name` goes: a folder in Spaces, its name cut so the path stays within `PrefixPath`.
    /// Throws, with nothing written, when the library folder's path is too long for any space to work (only a library
    /// from before the limit can be: onboarding refuses such a folder). The spaces it already has aren't touched.
    public func folder(forNew name: String) throws -> URL {
        if let problem = PrefixPath.existingLibraryProblem(paths.root) { throw ShellError.failed(problem) }
        let limit = PrefixPath.folderNameLimit(in: paths.spaces)
        let folder = Files.uniqueURL(in: paths.spaces, name: Files.safeName(name, maxLength: limit))
        if let problem = PrefixPath.problem(forPrefix: folder) { throw ShellError.failed(problem) }
        return folder
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

    /// Puts the DLLs of the launch's backend into the space: DXVK's `d3d11` and `d3d10core`, or DXMT's `d3d11`,
    /// `d3d10core` and `dxgi`. Wine takes its builtin over a DLL in system32 unless the launch says `n,b`, so copies
    /// an earlier launch left there are harmless for WineD3D and D3DMetal launches.
    public func prepareGraphics(_ backend: GraphicsBackend, engine: Engine, space: Space) throws {
        let fm = FileManager.default
        let source: [(engineFolder: URL, systemFolder: String)]
        let dlls: [String]
        let resolved = engine.resolve(backend)
        switch resolved {
        case .dxvk:
            guard let dxvk = engine.dxvk else { return }
            source = [(dxvk.appendingPathComponent("x64"), "system32"), (dxvk.appendingPathComponent("x32"), "syswow64")]
            dlls = ["d3d11.dll", "d3d10core.dll"]
            // With D3DMetal in G-Player Wine the builtin 64-bit dxgi is Apple's, which DXVK can't present with: Wine's
            // own, kept aside when D3DMetal went in, goes into system32 (the launch says `dxgi=n,b`).
            let wines = engine.wineRoot.appendingPathComponent("lib/wine-d3d/x86_64-windows/dxgi.dll")
            if engine.info.kind == .crossover, D3DMetalStore.linkedVersion(in: engine) != nil, let data = fm.contents(atPath: wines.path) {
                let dst = space.driveC.appendingPathComponent("windows/system32/dxgi.dll")
                let new = Self.nativeCopy(of: data)
                if fm.fileExists(atPath: dst.deletingLastPathComponent().path), fm.contents(atPath: dst.path) != new {
                    let backup = dst.appendingPathExtension("gplayer-wine")
                    if !fm.fileExists(atPath: backup.path), fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: dst, to: backup) }
                    try new.write(to: dst, options: .atomic)
                }
                // `dxgi=n,b` reaches 32-bit programs too: their dxgi has to be Wine's placeholder for its builtin,
                // not a DXMT copy an earlier launch left there.
                let wow = space.driveC.appendingPathComponent("windows/syswow64/dxgi.dll")
                let placeholder = engine.wineRoot.appendingPathComponent("lib/wine/i386-windows/dxgi.dll")
                if let data = fm.contents(atPath: placeholder.path), fm.fileExists(atPath: wow.deletingLastPathComponent().path),
                   fm.contents(atPath: wow.path) != data {
                    try data.write(to: wow, options: .atomic)
                }
            }
        case .dxmt:
            guard let dxmt = engine.dxmt else { return }
            source = [(dxmt.appendingPathComponent("x86_64-windows"), "system32"), (dxmt.appendingPathComponent("i386-windows"), "syswow64")]
            dlls = ["d3d11.dll", "d3d10core.dll", "dxgi.dll"]
        default:
            return
        }
        for (from, folder) in source {
            let to = space.driveC.appendingPathComponent("windows/\(folder)")
            guard fm.fileExists(atPath: to.path) else { continue }
            for dll in dlls {
                let dst = to.appendingPathComponent(dll)
                guard let data = fm.contents(atPath: from.appendingPathComponent(dll).path) else { continue }
                let new = Self.nativeCopy(of: data)
                if fm.contents(atPath: dst.path) == new { continue }
                // Keep Wine's own copy once, so the space can go back to plain Wine.
                let backup = to.appendingPathComponent(dll + ".gplayer-wine")
                if !fm.fileExists(atPath: backup.path), fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: dst, to: backup) }
                try new.write(to: dst, options: .atomic)
            }
            // DXMT's DLLs load winemetal, its bridge to Metal, which is one of the engine's builtins; the space only
            // needs Wine's placeholder for it.
            if resolved == .dxmt {
                let arch = folder == "system32" ? "x86_64-windows" : "i386-windows"
                let helper = to.appendingPathComponent("winemetal.dll")
                let builtin = engine.wineRoot.appendingPathComponent("lib/wine/\(arch)/winemetal.dll")
                if !fm.fileExists(atPath: helper.path), fm.fileExists(atPath: builtin.path) { try fm.copyItem(at: builtin, to: helper) }
            }
        }
    }

    /// A DLL built as one of Wine's builtins (DXMT's are) with that mark cleared, so Wine loads the copy in system32 as
    /// an ordinary Windows DLL when the launch says `n,b`. DLLs without the mark (DXVK's) come back unchanged.
    static func nativeCopy(of dll: Data) -> Data {
        let marker = Data("Wine builtin DLL".utf8)
        let range = (dll.startIndex + 0x40)..<(dll.startIndex + 0x50)
        guard dll.count > 0x50, dll[range].elementsEqual(marker) else { return dll }
        var copy = dll
        copy.replaceSubrange(range, with: Data(count: 16))
        return copy
    }

    /// Deletes a managed space and everything in it: into the Trash, or for good with `permanently` (a space G-Player made a
    /// moment ago for something that came to nothing, which has only Windows in it and isn't worth a Trash full of Wine).
    public func delete(_ space: Space, permanently: Bool = false) throws {
        guard space.origin == .managed else { return }
        if permanently { try FileManager.default.removeItem(at: space.url) }
        else { try FileManager.default.trashItem(at: space.url, resultingItemURL: nil) }
    }

    /// True when no game files are in the space: `C:\Games` is empty or isn't there. A space made for an Add Game that was
    /// stopped or failed has only Windows in it.
    public static func holdsNoGames(_ space: Space) -> Bool {
        let games = space.driveC.appendingPathComponent("Games", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: games.path)) ?? []
        return names.allSatisfy { $0 == ".DS_Store" }
    }

    /// True when `url` looks like a Wine prefix.
    public static func isPrefix(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("drive_c/windows").path)
            && fm.fileExists(atPath: url.appendingPathComponent("system.reg").path)
    }
}
