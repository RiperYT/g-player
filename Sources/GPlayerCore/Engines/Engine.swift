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

    /// G-Player Wine's GStreamer plugins, when its install copied them in (`GStreamerRuntime`): what Media Foundation's video
    /// decoding loads. Wine Staging has none of its own (it links a GStreamer.framework the user installed, if there is one).
    public var gstreamerPlugins: URL? {
        guard info.kind == .crossover else { return nil }
        let folder = wineRoot.appendingPathComponent("lib/gstreamer-1.0")
        return Files.isDirectory(folder) ? folder : nil
    }

    /// Where GStreamer keeps this engine's plugin registry: in the engine's own folder, next to `wine/`, so removing the engine
    /// removes it.
    public var gstreamerRegistry: URL {
        wineRoot.deletingLastPathComponent().appendingPathComponent("gstreamer-1.0-registry.x86_64.bin")
    }

    /// Wine Mono is in this engine's folder, where its Wine looks for a shared one (`WineMono.isUnpacked`). False for an engine
    /// that has no Mono of its own to go with (`EngineInfo.mono`).
    public var hasWineMono: Bool { info.mono.map { WineMono.isUnpacked($0, in: wineRoot) } ?? false }

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

    /// Where an engine's downloads go while it installs. One folder per engine: Wine Staging and G-Player Wine both
    /// download the same DXVK archive, and each deletes its copy after unpacking, which would break the other's.
    func downloadFolder(for info: EngineInfo) -> URL { paths.downloads.appendingPathComponent(info.id, isDirectory: true) }
    func downloadFile(_ item: PinnedDownload, of info: EngineInfo) -> URL {
        downloadFolder(for: info).appendingPathComponent(item.fileName)
    }

    /// A download that failed because the connection is down, so the same download would fail again right now.
    public static func isConnectionFailure(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        let down: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                                        .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
                                        .secureConnectionFailed]
        return down.contains(code)
    }

    /// Why `infos` can't be installed one after the other on this disk (not enough room), for the user, or nil.
    public func diskProblem(installing infos: [EngineInfo]) -> String? {
        guard !infos.isEmpty else { return nil }
        let names = CompatResolver.list(infos.map(\.name))
        return DiskSpace.problem(needing: diskNeeded(installing: infos), available: DiskSpace.available(at: paths.root),
                                 for: String(localized: "Installing \(names)"))
    }

    /// The free space installing `infos` needs now (`EngineCatalog.diskBytes`). One engine whose files an earlier try left in
    /// its downloads folder (a late failure keeps them) doesn't need that room again: it is taken already.
    func diskNeeded(installing infos: [EngineInfo]) -> Int64 {
        let needed = EngineCatalog.diskBytes(installing: infos)
        guard infos.count == 1, let info = infos.first else { return needed }
        let taken = info.downloads.reduce(Int64(0)) { total, item in
            let file = downloadFile(item, of: info)
            return total + Files.size(of: file) + Files.size(of: FileDownloader.partialFile(for: file))
        }
        return max(0, needed - taken)
    }

    /// Downloads, verifies and unpacks an engine. `progress` gets 0…1 and what to say ("Downloading 41 of 98 MB"). A download
    /// that stops (Stop, a quit, a dropped connection) keeps what came and goes on from there the next time. The files that
    /// came whole and were checked stay in the engine's downloads folder until the whole install has succeeded, so one that
    /// fails late (GStreamer's step, the last) starts again from them and downloads nothing twice. `EngineCatalog.diskBytes`
    /// counts the room they take.
    public func install(_ info: EngineInfo, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Engine {
        guard !info.downloads.isEmpty else {
            throw ShellError.failed(String(localized: "G-Player doesn't download \(info.name). Install it yourself from Apple if its license fits your use."))
        }
        if let problem = diskProblem(installing: [info]) { throw ShellError.failed(problem) }
        try paths.createFolders()
        let target = folder(for: info)
        let staging = paths.engines.appendingPathComponent(".\(info.id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // What is downloaded: the runtime libraries aren't when an installed Wine Staging has them.
        let stagingInstalled = engine(EngineCatalog.wineStaging) != nil
        let totalBytes = info.downloadBytes(wineStagingInstalled: stagingInstalled)
        var done: Int64 = 0
        for item in info.downloads {
            // The runtime libraries are in an installed Wine Staging already, same build: no need to download them.
            if item.role == .runtimeLibraries, let installed = engine(EngineCatalog.wineStaging) {
                try copyRuntimeLibraries(from: installed.wineRoot.appendingPathComponent("lib"), into: staging.appendingPathComponent("wine/lib"))
                continue
            }
            // GStreamer's files come out of its package only for an engine whose archive lists them. The package the list
            // names is checked before anything is downloaded.
            var gstreamer: GStreamerRuntime.Manifest?
            if item.role == .gstreamer {
                guard let listed = try GStreamerRuntime.manifest(in: staging) else { done += item.approximateBytes; continue }
                try GStreamerRuntime.check(listed, against: item)
                gstreamer = listed
            }
            let file = downloadFile(item, of: info)
            if !(FileManager.default.fileExists(atPath: file.path) && (try? Files.sha256(of: file)) == item.sha256) {
                let base = done
                try await fetch(item, to: file) { received, note in
                    let fraction = totalBytes > 0 ? Double(base + received) / Double(totalBytes) : 0
                    progress(min(0.95, fraction), note ?? DownloadResume.message(received: base + received, total: totalBytes))
                }
            }
            done += item.approximateBytes
            progress(min(0.97, totalBytes > 0 ? Double(done) / Double(totalBytes) : 0.97), String(localized: "Unpacking \(item.fileName)"))
            switch item.role {
            case .engine: try await unpack(file, into: staging, isDXVK: false)
            case .dxvk: try await unpack(file, into: staging, isDXVK: true)
            case .runtimeLibraries:
                let unpacked = staging.appendingPathComponent("runtime-unpack", isDirectory: true)
                try await unpack(file, into: unpacked, isDXVK: false)
                let lib = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
                    .first { $0.pathExtension == "app" }?.appendingPathComponent("Contents/Resources/wine/lib")
                guard let lib else { throw ShellError.failed(String(localized: "\(item.fileName) doesn't hold Wine's libraries.")) }
                try copyRuntimeLibraries(from: lib, into: staging.appendingPathComponent("wine/lib"))
                try? FileManager.default.removeItem(at: unpacked)
            case .gstreamer:
                // After the runtime libraries (the item order): it never lists a name they have, and would replace it.
                if let gstreamer { try await installGStreamer(from: file, manifest: gstreamer, into: staging.appendingPathComponent("wine")) }
            case .wineMono:
                break                                           // never in an engine's downloads: `installWineMono` fetches it later
            }
        }
        await Files.clearQuarantine(staging)
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)
        try? FileManager.default.removeItem(at: downloadFolder(for: info))
        progress(1, String(localized: "Ready"))
        guard let engine = engine(info) else { throw ShellError.failed(String(localized: "\(info.name) was unpacked but can't be found.")) }
        EngineFixes.apply(to: engine)
        return engine
    }

    /// Downloads one pinned file and checks it. A connection that drops after it delivered something is tried again where it
    /// stopped (`DownloadResume.retryDelays`), and so is a download that was stopped earlier: what came is kept in a `.part`
    /// file. A file made of several tries that fails its checksum is downloaded once more from the start.
    /// `report` gets the bytes the file has, and a note to show in place of the usual progress text.
    func fetch(_ item: PinnedDownload, to file: URL, configuration: URLSessionConfiguration = .default,
               delays: [TimeInterval] = DownloadResume.retryDelays,
               report: @escaping @Sendable (_ received: Int64, _ note: String?) -> Void) async throws {
        let partial = FileDownloader.partialFile(for: file)
        var failures = 0
        var hasReceivedData = false
        var glued = Files.size(of: partial) > 0                 // what is there came from an earlier try
        while true {
            let before = Files.size(of: partial)
            do {
                try await FileDownloader.download(item.url, to: file, resume: true, configuration: configuration) { done, _ in
                    report(done, nil)
                }
            } catch {
                let grew = Files.size(of: partial) > before
                if grew { hasReceivedData = true; failures = 0 }
                guard let wait = DownloadResume.retryDelay(after: error, failures: failures, hasReceivedData: hasReceivedData,
                                                           delays: delays) else { throw error }
                if !grew { failures += 1 }
                glued = true
                report(Files.size(of: partial), String(localized: "The connection dropped. Trying again…"))
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            report(item.approximateBytes, String(localized: "Checking \(item.fileName)"))
            if try Files.sha256(of: file) == item.sha256 { return }
            try? FileManager.default.removeItem(at: file)
            guard glued else { throw ShellError.failed(String(localized: "\(item.fileName) didn't match its checksum. Try again.")) }
            glued = false                                       // a part that went stale: once more, from the start
        }
    }

    /// Clears what an install that never ended left in the library: its hidden staging folder in Engines (`.<id>-<8 letters>`),
    /// and the downloads of an engine that is installed. A download of an engine that isn't installed stays to be gone on
    /// with, unless nothing touched it for `partialLifetime`. Call it only while no install runs.
    public func cleanLeftovers(now: Date = Date(), partialLifetime: TimeInterval = 7 * 24 * 3600) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: paths.engines.path)) ?? [] where name.hasPrefix(".") {
            let isStaging = EngineCatalog.known.contains { name.hasPrefix(".\($0.id)-") && name.count == $0.id.count + 10 }
            if isStaging { try? fm.removeItem(at: paths.engines.appendingPathComponent(name)) }
        }
        for info in EngineCatalog.known where !info.downloads.isEmpty {
            let downloads = downloadFolder(for: info)
            guard fm.fileExists(atPath: downloads.path) else { continue }
            if isInstalled(info) { try? fm.removeItem(at: downloads); continue }
            removeStaleFiles(in: downloads, now: now, lifetime: partialLifetime)
        }
        // A Wine Mono download goes once Wine Mono is in its engine; one that stopped before that is gone on with, as an engine's is.
        for info in EngineCatalog.known {
            guard let package = info.mono else { continue }
            let downloads = wineMonoDownloadFolder(for: info)
            guard fm.fileExists(atPath: downloads.path) else { continue }
            if let installed = engine(info), WineMono.isUnpacked(package, in: installed.wineRoot) { try? fm.removeItem(at: downloads); continue }
            removeStaleFiles(in: downloads, now: now, lifetime: partialLifetime)
        }
    }

    private func removeStaleFiles(in folder: URL, now: Date, lifetime: TimeInterval) {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let touched = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let touched, now.timeIntervalSince(touched) > lifetime { try? fm.removeItem(at: file) }
        }
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
            throw ShellError.failed(String(localized: "Wine Staging's libraries lack \(needed), which G-Player Wine needs."))
        }
    }

    /// The libraries G-Player Wine was built against (scripts/build-engine-cx.sh checks Gcenx's build has them).
    static let runtimeLibraries = ["libfreetype.6.dylib", "libgnutls.30.dylib", "libSDL2-2.0.0.dylib"]

    /// Expands GStreamer's package with stock `pkgutil` (a few seconds, and room for about 705 MB: `PinnedDownload.scratchBytes`),
    /// copies the files the engine lists into its `wine` folder and deletes the expansion at once. It lives next to `wine` in
    /// the engine being made, so a stop or a failure takes it away with the rest.
    func installGStreamer(from package: URL, manifest: GStreamerRuntime.Manifest, into wineRoot: URL) async throws {
        let expanded = wineRoot.deletingLastPathComponent().appendingPathComponent("gstreamer-unpack", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: expanded) }
        let r = try await Shell.runStoppable(Shell.tool("pkgutil"), ["--expand-full", package.path, expanded.path])
        guard r.succeeded else { throw ShellError.failed(String(localized: "Couldn't unpack \(package.lastPathComponent): \(r.stderr)")) }
        try GStreamerRuntime.copyFiles(of: manifest, from: expanded, into: wineRoot)
    }

    private func unpack(_ archive: URL, into folder: URL, isDXVK: Bool) async throws {
        let dest = isDXVK ? folder.appendingPathComponent("dxvk-unpack") : folder
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let r = try await Shell.runStoppable(Shell.tool("tar"), ["-xf", archive.path, "-C", dest.path])
        guard r.succeeded else { throw ShellError.failed(String(localized: "Couldn't unpack \(archive.lastPathComponent): \(r.stderr)")) }
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
        try? FileManager.default.removeItem(at: downloadFolder(for: info))      // a part of it that was left
        try? FileManager.default.removeItem(at: wineMonoDownloadFolder(for: info))
    }
}
