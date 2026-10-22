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

    public var wineserver: URL { wineRoot.appendingPathComponent("bin/wineserver") }
    /// GPTK's D3DMetal and its helpers live here.
    public var externalLibraries: URL { wineRoot.appendingPathComponent("lib/external") }
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
            try await unpack(file, into: staging, isDXVK: item.fileName.hasPrefix("dxvk"))
            try? FileManager.default.removeItem(at: file)
        }
        await Files.clearQuarantine(staging)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)
        progress(1, "Ready")
        guard let engine = engine(info) else { throw ShellError.failed("\(info.name) was unpacked but can't be found.") }
        return engine
    }

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
        guard info.kind == .wineStaging else { return }
        try FileManager.default.removeItem(at: folder(for: info))
    }
}
