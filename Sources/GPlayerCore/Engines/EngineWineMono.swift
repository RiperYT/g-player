import Foundation

/// Fetching Wine Mono into an installed engine (`WineMono`).
extension EngineManager {
    /// Where an engine's Wine Mono download waits: not the engine's own downloads folder, which the start's clean-up deletes for
    /// an installed engine, and with it the part of a download that was stopped.
    func wineMonoDownloadFolder(for info: EngineInfo) -> URL {
        paths.downloads.appendingPathComponent("\(info.id)-mono", isDirectory: true)
    }

    func wineMonoDownloadFile(_ package: WineMonoPackage, of info: EngineInfo) -> URL {
        wineMonoDownloadFolder(for: info).appendingPathComponent(package.download.fileName)
    }

    /// Why Wine Mono can't be fetched on this disk now (not enough room), for the user, or nil.
    public func wineMonoDiskProblem(for info: EngineInfo) -> String? {
        guard let package = info.mono else { return nil }
        let file = wineMonoDownloadFile(package, of: info)
        let have = Files.size(of: file) + Files.size(of: FileDownloader.partialFile(for: file))
        return DiskSpace.problem(needing: WineMono.neededBytes(package, alreadyDownloaded: have),
                                 available: DiskSpace.available(at: paths.root), for: "Installing Wine Mono")
    }

    /// Downloads the engine's Wine Mono (`EngineInfo.mono`), checks it against its pinned SHA-256, and unpacks it to
    /// `<engine>/share/wine/mono/wine-mono-<version>`, where its Wine looks for a shared one. Nothing happens when it is there. The
    /// download goes on where it stopped, like an engine's (`fetch`). The folder is unpacked beside the engine and moved into place
    /// when it is whole, so a stop or a failure leaves the engine as it was. `progress` gets 0…1 and what to say.
    public func installWineMono(into engine: Engine, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard let package = engine.info.mono else {
            throw ShellError.failed("G-Player doesn't know a Wine Mono for \(engine.info.name).")
        }
        guard !WineMono.isUnpacked(package, in: engine.wineRoot) else { return }
        if let problem = wineMonoDiskProblem(for: engine.info) { throw ShellError.failed(problem) }
        try paths.createFolders()
        let item = package.download
        let file = wineMonoDownloadFile(package, of: engine.info)
        if !(FileManager.default.fileExists(atPath: file.path) && (try? Files.sha256(of: file)) == item.sha256) {
            try await fetch(item, to: file) { received, note in
                let fraction = item.approximateBytes > 0 ? Double(received) / Double(item.approximateBytes) : 0
                progress(min(0.9, fraction * 0.9), note ?? DownloadResume.message(received: received, total: item.approximateBytes))
            }
        }
        progress(0.92, "Unpacking Wine Mono")
        // A hidden folder of the kind `cleanLeftovers` removes when an unpack never ended.
        let staging = paths.engines.appendingPathComponent(".\(engine.info.id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let unpack = try await Shell.runStoppable(Shell.tool("tar"), ["-xf", file.path, "-C", staging.path])
        guard unpack.succeeded else { throw ShellError.failed("Couldn't unpack \(item.fileName): \(unpack.stderr)") }
        let unpacked = staging.appendingPathComponent(package.folderName, isDirectory: true)
        guard WineMono.isWhole(unpacked) else { throw ShellError.failed("\(item.fileName) doesn't hold \(package.folderName).") }
        try Task.checkCancellation()
        let target = WineMono.folder(of: package, in: engine.wineRoot)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: unpacked, to: target)
        try? FileManager.default.removeItem(at: wineMonoDownloadFolder(for: engine.info))
        progress(1, "Ready")
    }
}
