import Foundation

/// An engine that is ready to run on this Mac.
public struct Engine: Sendable, Hashable {
    public let info: EngineInfo
    /// The folder with `bin/` and `lib/`.
    public let wineRoot: URL
    /// `bin/wine` (Wine 9+) or `bin/wine64` (older builds).
    public let wine: URL
    /// Folder with DXVK's `x64` and `x32` DLLs, when this engine uses DXVK.
    public let dxvk: URL?
    /// Folder with DXMT's `x86_64-windows` and `i386-windows` DLLs, when the engine has DXMT (G-Player Wine).
    public var dxmt: URL? = nil

    public init(info: EngineInfo, wineRoot: URL, wine: URL, dxvk: URL?, dxmt: URL? = nil) {
        self.info = info; self.wineRoot = wineRoot; self.wine = wine; self.dxvk = dxvk; self.dxmt = dxmt
    }

    public var wineserver: URL { wineRoot.appendingPathComponent("bin/wineserver") }
    /// GPTK's D3DMetal and its helpers live here.
    public var externalLibraries: URL { wineRoot.appendingPathComponent("lib/external") }
    /// Apple's bridge from D3DMetal's DLLs to Metal, when D3DMetal is in this engine.
    public var d3dMetalLibrary: URL? {
        let lib = externalLibraries.appendingPathComponent("libd3dshared.dylib")
        return FileManager.default.fileExists(atPath: lib.path) ? lib : nil
    }

    /// The backends this engine can run right now: G-Player Wine runs D3DMetal only once it has been linked in
    /// completely from the user's Game Porting Toolkit, and DXVK and DXMT only when their DLLs are there.
    public var readyBackends: [GraphicsBackend] {
        info.backends.filter { backend in
            switch backend {
            case .d3dmetal: info.kind == .gptk || D3DMetalStore.linkedVersion(in: self) != nil
            case .dxvk: dxvk != nil
            case .dxmt: dxmt != nil
            case .wined3d, .auto: true
            }
        }
    }

    /// The backend a launch really gets: `.auto`, or one this engine can't run now, means the first ready one.
    public func resolve(_ backend: GraphicsBackend) -> GraphicsBackend {
        let ready = readyBackends
        return backend == .auto || !ready.contains(backend) ? (ready.first ?? .wined3d) : backend
    }
}

/// Finds, downloads and removes engines.
public struct EngineManager: Sendable {
    public let paths: LibraryPaths

    public init(paths: LibraryPaths) { self.paths = paths }

    public static let gptkApp = URL(fileURLWithPath: "/Applications/Game Porting Toolkit.app")

    public func folder(for info: EngineInfo) -> URL { paths.engines.appendingPathComponent(info.id, isDirectory: true) }

    /// The engine, if it is installed.
    public func engine(_ info: EngineInfo) -> Engine? {
        switch info.kind {
        case .wineStaging:
            let root = folder(for: info).appendingPathComponent("Wine Staging.app/Contents/Resources/wine")
            guard let wine = Self.wineBinary(in: root) else { return nil }
            let dxvk = folder(for: info).appendingPathComponent("dxvk")
            return Engine(info: info, wineRoot: root, wine: wine,
                          dxvk: FileManager.default.fileExists(atPath: dxvk.appendingPathComponent("x64/d3d11.dll").path) ? dxvk : nil)
        case .crossover:
            let root = folder(for: info).appendingPathComponent("wine")
            guard let wine = Self.wineBinary(in: root) else { return nil }
            let fm = FileManager.default
            let dxvk = folder(for: info).appendingPathComponent("dxvk")
            let dxmt = root.appendingPathComponent("lib/dxmt")
            return Engine(info: info, wineRoot: root, wine: wine,
                          dxvk: fm.fileExists(atPath: dxvk.appendingPathComponent("x64/d3d11.dll").path) ? dxvk : nil,
                          dxmt: fm.fileExists(atPath: dxmt.appendingPathComponent("x86_64-windows/d3d11.dll").path) ? dxmt : nil)
        case .gptk:
            let root = Self.gptkApp.appendingPathComponent("Contents/Resources/wine")
            guard let wine = Self.wineBinary(in: root) else { return nil }
            return Engine(info: info, wineRoot: root, wine: wine, dxvk: nil)
        }
    }

    public func engine(id: String) -> Engine? { EngineCatalog.info(id).flatMap(engine) }
    public func isInstalled(_ info: EngineInfo) -> Bool { engine(info) != nil }

    static func wineBinary(in root: URL) -> URL? {
        for name in ["bin/wine", "bin/wine64"] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Downloads, verifies and unpacks an engine. `progress` gets 0…1.
    public func install(_ info: EngineInfo, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Engine {
        guard !info.downloads.isEmpty else {
            throw ShellError.failed("G-Player doesn't download \(info.name). Install it yourself from Apple if its license fits your use.")
        }
        try paths.createFolders()
        let target = folder(for: info)
        let staging = paths.engines.appendingPathComponent(".\(info.id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let total = Double(info.downloads.reduce(0) { $0 + $1.approximateBytes })
        var done = 0.0
        for item in info.downloads {
            // The runtime libraries are in an installed Wine Staging already, same build: no need to download them.
            if item.role == .runtimeLibraries, let installed = engine(EngineCatalog.wineStaging) {
                try copyRuntimeLibraries(from: installed.wineRoot.appendingPathComponent("lib"), into: staging.appendingPathComponent("wine/lib"))
                done += Double(item.approximateBytes)
                continue
            }
            let file = paths.downloads.appendingPathComponent(item.fileName)
            if !(FileManager.default.fileExists(atPath: file.path) && (try? Files.sha256(of: file)) == item.sha256) {
                let base = done
                try await FileDownloader.download(item.url, to: file) { fraction in
                    progress(min(0.95, (base + fraction * Double(item.approximateBytes)) / total), "Downloading \(item.fileName)")
                }
                progress(min(0.95, (base + Double(item.approximateBytes)) / total), "Checking \(item.fileName)")
                let sum = try Files.sha256(of: file)
                guard sum == item.sha256 else {
                    try? FileManager.default.removeItem(at: file)
                    throw ShellError.failed("\(item.fileName) didn't match its checksum. Try again.")
                }
            }
            done += Double(item.approximateBytes)
            progress(min(0.97, done / total), "Unpacking \(item.fileName)")
            switch item.role {
            case .engine: try await unpack(file, into: staging, isDXVK: false)
            case .dxvk: try await unpack(file, into: staging, isDXVK: true)
            case .runtimeLibraries:
                let unpacked = staging.appendingPathComponent("runtime-unpack", isDirectory: true)
                try await unpack(file, into: unpacked, isDXVK: false)
                let lib = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
                    .first { $0.pathExtension == "app" }?.appendingPathComponent("Contents/Resources/wine/lib")
                guard let lib else { throw ShellError.failed("\(item.fileName) doesn't hold Wine's libraries.") }
                try copyRuntimeLibraries(from: lib, into: staging.appendingPathComponent("wine/lib"))
                try? FileManager.default.removeItem(at: unpacked)
            }
            try? FileManager.default.removeItem(at: file)
        }
        await Files.clearQuarantine(staging)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)
        progress(1, "Ready")
        guard let engine = engine(info) else { throw ShellError.failed("\(info.name) was unpacked but can't be found.") }
        EngineFixes.apply(to: engine)
        return engine
    }

    /// Copies the dylibs of Gcenx's build (FreeType, GnuTLS, SDL2, the Vulkan loader and what they use) into
    /// G-Player Wine's `lib`, which brings only MoltenVK. Under their own licenses, from Gcenx's own download.
    func copyRuntimeLibraries(from lib: URL, into target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        // MoltenVK is G-Player's own; the Vulkan loader isn't used (Wine talks to MoltenVK directly).
        for item in try fm.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil)
        where item.pathExtension == "dylib" && !item.lastPathComponent.hasPrefix("libMoltenVK")
            && !item.lastPathComponent.hasPrefix("libvulkan") {
            let dest = target.appendingPathComponent(item.lastPathComponent)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: item, to: dest)                 // symlinks (libfoo.dylib -> libfoo.1.dylib) stay links
        }
        for needed in Self.runtimeLibraries where !fm.fileExists(atPath: target.appendingPathComponent(needed).path) {
            throw ShellError.failed("Wine Staging's libraries lack \(needed), which G-Player Wine needs.")
        }
    }

    /// The libraries G-Player Wine was built against (scripts/build-engine-cx.sh checks Gcenx's build has them).
    static let runtimeLibraries = ["libfreetype.6.dylib", "libgnutls.30.dylib", "libSDL2-2.0.0.dylib"]

    private func unpack(_ archive: URL, into folder: URL, isDXVK: Bool) async throws {
        let dest = isDXVK ? folder.appendingPathComponent("dxvk-unpack") : folder
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let r = try await Shell.run(Shell.tool("tar"), ["-xf", archive.path, "-C", dest.path])
        guard r.succeeded else { throw ShellError.failed("Couldn't unpack \(archive.lastPathComponent): \(r.stderr)") }
        if isDXVK {
            // The archive holds one top folder with x64/ and x32/.
            let inner = (try? FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil))?
                .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("x64").path) } ?? dest
            try FileManager.default.moveItem(at: inner, to: folder.appendingPathComponent("dxvk"))
            try? FileManager.default.removeItem(at: dest)
        }
    }

    public func remove(_ info: EngineInfo) throws {
        guard info.kind != .gptk else { return }
        try FileManager.default.removeItem(at: folder(for: info))
    }
}
