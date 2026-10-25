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
    public func wineMonoDiskProblem(for info: EngineInfo) -> String? { wineMonoDiskError(for: info)?.errorDescription }

    /// `wineMonoDiskProblem` as an error to throw, with its English for the install's log.
    func wineMonoDiskError(for info: EngineInfo) -> ShellError? {
        guard let package = info.mono else { return nil }
        let file = wineMonoDownloadFile(package, of: info)
        let have = Files.size(of: file) + Files.size(of: FileDownloader.partialFile(for: file))
        return DiskSpace.error(needing: WineMono.neededBytes(package, alreadyDownloaded: have),
                               available: DiskSpace.available(at: paths.root), for: "Installing Wine Mono")
    }

    /// Downloads the engine's Wine Mono (`EngineInfo.mono`), checks it against its pinned SHA-256, and unpacks it to
    /// `<engine>/share/wine/mono/wine-mono-<version>`, where its Wine looks for a shared one. Nothing happens when it is there. The
    /// download goes on where it stopped, like an engine's (`fetch`). The folder is unpacked beside the engine and moved into place
    /// when it is whole, so a stop or a failure leaves the engine as it was. `progress` gets 0…1 and what to say.
    public func installWineMono(into engine: Engine, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard let package = engine.info.mono else {
            throw ShellError.said("G-Player doesn't know a Wine Mono for \(engine.info.name).")
        }
        guard !WineMono.isUnpacked(package, in: engine.wineRoot) else { return }
        try requireInstalled(engine)
        if let problem = wineMonoDiskError(for: engine.info) { throw problem }
        try paths.createFolders()
        let item = package.download
        let file = wineMonoDownloadFile(package, of: engine.info)
        if !(FileManager.default.fileExists(atPath: file.path) && (try? Files.sha256(of: file)) == item.sha256) {
            try await fetch(item, to: file) { received, note in
                let fraction = item.approximateBytes > 0 ? Double(received) / Double(item.approximateBytes) : 0
                progress(min(0.9, fraction * 0.9), note ?? say(DownloadResume.resource(received: received, total: item.approximateBytes)))
            }
        }
        progress(0.92, say("Unpacking Wine Mono"))
        // A hidden folder of the kind `cleanLeftovers` removes when an unpack never ended.
        let staging = paths.engines.appendingPathComponent(".\(engine.info.id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let unpack = try await Shell.runStoppable(Shell.tool("tar"), ["-xf", file.path, "-C", staging.path])
        guard unpack.succeeded else { throw ShellError.said("Couldn't unpack \(item.fileName): \(unpack.stderr)") }
        let unpacked = staging.appendingPathComponent(package.folderName, isDirectory: true)
        guard WineMono.isWhole(unpacked) else { throw ShellError.said("\(item.fileName) doesn't hold \(package.folderName).") }
        try Task.checkCancellation()
        // The engine may have been removed while this downloaded: its folders are not made again for a Wine Mono nothing runs on.
        try requireInstalled(engine)
        let target = WineMono.folder(of: package, in: engine.wineRoot)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: unpacked, to: target)
        // Last: a move that was cut short has no marker, and is fetched again.
        do { try WineMono.writeMarker(for: package, in: target) } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        try? FileManager.default.removeItem(at: wineMonoDownloadFolder(for: engine.info))
        progress(1, say("Ready"))
    }

    /// The engine is still installed (its Wine is there to run).
    private func requireInstalled(_ engine: Engine) throws {
        guard Self.wineBinary(in: engine.wineRoot) != nil else {
            throw ShellError.said("\(engine.info.name) was removed while Wine Mono was being added to it.")
        }
    }
}
