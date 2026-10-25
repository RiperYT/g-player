import CryptoKit
import Foundation
import Testing
@testable import GPlayerCore

/// A server that lives in the test: files by path, with ranges, drops, stalls and errors.
final class StubServer: URLProtocol {
    struct Behavior {
        var data: Data
        var honorsRange = true
        /// How many of the first requests send `dropAfter` bytes of their body and then lose the connection.
        var drops = 0
        var dropAfter = 0
        var status: Int?
        /// Send this many bytes of the body, then wait for ever.
        var stallAfter: Int?
    }

    nonisolated(unsafe) private static var behaviors: [String: Behavior] = [:]
    nonisolated(unsafe) private static var seen: [String: [String?]] = [:]
    private static let lock = NSLock()

    /// A URL of its own for this behavior, so tests running side by side don't meet.
    static func serve(_ behavior: Behavior, name: String = "file.bin") -> URL {
        let path = "/\(UUID().uuidString)/\(name)"
        lock.lock(); behaviors[path] = behavior; lock.unlock()
        return URL(string: "https://stub.test\(path)")!
    }

    /// The `Range` header of each request this URL got, in order.
    static func ranges(of url: URL) -> [String?] {
        lock.lock(); defer { lock.unlock() }
        return seen[url.path] ?? []
    }

    static var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubServer.self]
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        var behavior = Self.behaviors[url.path] ?? Behavior(data: Data(), status: 404)
        let range = request.value(forHTTPHeaderField: "Range")
        Self.seen[url.path, default: []].append(range)
        let dropping = behavior.drops > 0
        if dropping { behavior.drops -= 1; Self.behaviors[url.path] = behavior }
        Self.lock.unlock()

        func respond(_ status: Int, _ headers: [String: String]) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        if let status = behavior.status {
            respond(status, [:])
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var start = 0, status = 200
        var headers: [String: String] = [:]
        if behavior.honorsRange, let range, range.hasPrefix("bytes="), let from = Int(range.dropFirst(6).dropLast()) {
            guard from < behavior.data.count else {
                respond(416, ["Content-Range": "bytes */\(behavior.data.count)"])
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            start = from; status = 206
            headers["Content-Range"] = "bytes \(from)-\(behavior.data.count - 1)/\(behavior.data.count)"
        }
        let body = behavior.data.dropFirst(start)
        headers["Content-Length"] = "\(body.count)"
        respond(status, headers)
        let limit = dropping ? behavior.dropAfter : (behavior.stallAfter ?? body.count)
        var sent = 0
        while sent < min(limit, body.count) {
            let end = min(sent + 500, limit, body.count)
            client?.urlProtocol(self, didLoad: Data(body.dropFirst(sent).prefix(end - sent)))
            sent = end
        }
        if dropping {
            // A moment after the data, as on a real connection: what was sent has arrived when it drops.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else if behavior.stallAfter == nil { client?.urlProtocolDidFinishLoading(self) }
    }
}

private func bytes(_ count: Int, seed: UInt8 = 1) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@Suite struct DownloadResumeTests {
    @Test func aRangeIsAskedForOnlyWhenSomethingIsThere() {
        #expect(DownloadResume.rangeHeader(partialSize: 0) == nil)
        #expect(DownloadResume.rangeHeader(partialSize: 1500) == "bytes=1500-")
    }

    @Test func theServersAnswerSaysWhatToDoWithThePart() {
        // The rest of the file, from where the part ends.
        #expect(DownloadResume.answer(partialSize: 100, status: 206, contentRange: "bytes 100-999/1000", contentLength: 900) == .append(total: 1000))
        #expect(DownloadResume.answer(partialSize: 100, status: 206, contentRange: "bytes 100-999/*", contentLength: 900) == .append(total: 1000))
        // A range from somewhere else, or none: not usable.
        #expect(DownloadResume.answer(partialSize: 100, status: 206, contentRange: "bytes 0-999/1000", contentLength: 1000) == .rangeRefused)
        #expect(DownloadResume.answer(partialSize: 100, status: 206, contentRange: nil, contentLength: 900) == .rangeRefused)
        // A server that doesn't do ranges sends all of it.
        #expect(DownloadResume.answer(partialSize: 100, status: 200, contentRange: nil, contentLength: 1000) == .restart(total: 1000))
        #expect(DownloadResume.answer(partialSize: 0, status: 200, contentRange: nil, contentLength: nil) == .restart(total: 0))
        // A 416 that says the file is as long as the part: the part is all of it. Anything else: ask for the whole file.
        #expect(DownloadResume.answer(partialSize: 5000, status: 416, contentRange: "bytes */5000", contentLength: 0) == .complete)
        #expect(DownloadResume.answer(partialSize: 6000, status: 416, contentRange: "bytes */5000", contentLength: 0) == .rangeRefused)
        #expect(DownloadResume.answer(partialSize: 5000, status: 416, contentRange: nil, contentLength: 0) == .rangeRefused)
        #expect(DownloadResume.answer(partialSize: 0, status: 416, contentRange: "bytes */0", contentLength: 0) == .rangeRefused)
        #expect(DownloadResume.answer(partialSize: 0, status: 404, contentRange: nil, contentLength: 0) == .failed(status: 404))
        #expect(DownloadResume.answer(partialSize: 0, status: 503, contentRange: nil, contentLength: 0) == .failed(status: 503))
    }

    @Test func aDroppedConnectionIsTriedAgainOnlyAfterSomethingCame() {
        let dropped = URLError(.networkConnectionLost)
        #expect(DownloadResume.retryDelay(after: dropped, failures: 0, hasReceivedData: true) == 2)
        #expect(DownloadResume.retryDelay(after: dropped, failures: 1, hasReceivedData: true) == 5)
        #expect(DownloadResume.retryDelay(after: dropped, failures: 2, hasReceivedData: true) == 10)
        #expect(DownloadResume.retryDelay(after: dropped, failures: 3, hasReceivedData: true) == nil)
        // Offline from the start: the user is told at once.
        #expect(DownloadResume.retryDelay(after: URLError(.notConnectedToInternet), failures: 0, hasReceivedData: false) == nil)
        #expect(DownloadResume.retryDelay(after: dropped, failures: 0, hasReceivedData: false) == nil)
        // Not a connection problem, or a stop: no.
        #expect(DownloadResume.retryDelay(after: ShellError.failed("x"), failures: 0, hasReceivedData: true) == nil)
        #expect(DownloadResume.retryDelay(after: CancellationError(), failures: 0, hasReceivedData: true) == nil)
    }

    @Test func progressSaysHowManyOfHowManyMegabytes() {
        #expect(DownloadResume.message(received: 41_300_000, total: 98_000_000) == "Downloading 41 of 98 MB")
        // The catalogue's sizes are approximate: never more than the whole.
        #expect(DownloadResume.message(received: 99_500_000, total: 98_000_000) == "Downloading 98 of 98 MB")
        #expect(DownloadResume.message(received: 5_000_000, total: 0) == "Downloading 5 MB")
        // Rounded as everywhere: a total of 287,881,528 bytes is 288 MB and ends as "288 of 288".
        #expect(DownloadResume.message(received: 287_881_528, total: 287_881_528) == "Downloading 288 of 288 MB")
        #expect(DownloadResume.message(received: 143_990_000, total: 287_881_528) == "Downloading 144 of 288 MB")
        #expect(DownloadResume.message(received: 600_000, total: 98_000_000) == "Downloading 1 of 98 MB")
    }
}

@Suite struct FileDownloaderTests {
    @Test func aDownloadLandsInItsPlaceAndLeavesNoPart() async throws {
        let tmp = TempFolder()
        let data = bytes(5000)
        let url = StubServer.serve(.init(data: data))
        let file = tmp.url.appendingPathComponent("f.bin")
        let last = LockedValue<(Int64, Int64)>((0, 0))
        try await FileDownloader.download(url, to: file, configuration: StubServer.configuration) { done, total in last.set((done, total)) }
        #expect(try Data(contentsOf: file) == data)
        #expect(!FileManager.default.fileExists(atPath: FileDownloader.partialFile(for: file).path))
        #expect(last.get() == (5000, 5000))
        #expect(StubServer.ranges(of: url) == [nil])
    }

    @Test func aPartIsContinuedWithARangeRequest() async throws {
        let tmp = TempFolder()
        let data = bytes(5000)
        let url = StubServer.serve(.init(data: data))
        let file = tmp.url.appendingPathComponent("f.bin")
        try data.prefix(2000).write(to: FileDownloader.partialFile(for: file))
        try await FileDownloader.download(url, to: file, resume: true, configuration: StubServer.configuration) { _, _ in }
        #expect(try Data(contentsOf: file) == data)
        #expect(StubServer.ranges(of: url) == ["bytes=2000-"])
    }

    @Test func withoutResumeAnOldPartIsThrownAway() async throws {
        let tmp = TempFolder()
        let data = bytes(5000)
        let url = StubServer.serve(.init(data: data))
        let file = tmp.url.appendingPathComponent("f.bin")
        try bytes(2000, seed: 9).write(to: FileDownloader.partialFile(for: file))
        try await FileDownloader.download(url, to: file, configuration: StubServer.configuration) { _, _ in }
        #expect(try Data(contentsOf: file) == data)
        #expect(StubServer.ranges(of: url) == [nil])
    }

    @Test func aServerThatIgnoresRangesGivesTheWholeFileAndTheOldPartIsReplaced() async throws {
        let tmp = TempFolder()
        let data = bytes(5000)
        let url = StubServer.serve(.init(data: data, honorsRange: false))
        let file = tmp.url.appendingPathComponent("f.bin")
        try bytes(2000, seed: 9).write(to: FileDownloader.partialFile(for: file))
        try await FileDownloader.download(url, to: file, resume: true, configuration: StubServer.configuration) { _, _ in }
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func aPartLongerThanTheFileIsStartedOverOnce() async throws {
        let tmp = TempFolder()
        let data = bytes(5000)
        let url = StubServer.serve(.init(data: data))
        let file = tmp.url.appendingPathComponent("f.bin")
        try bytes(6000, seed: 9).write(to: FileDownloader.partialFile(for: file))
        try await FileDownloader.download(url, to: file, resume: true, configuration: StubServer.configuration) { _, _ in }
        #expect(try Data(contentsOf: file) == data)
        #expect(StubServer.ranges(of: url) == ["bytes=6000-", nil])
    }

    @Test func aPartThatIsAllOfTheFileIsKeptWithoutDownloadingAgain() async throws {
        let tmp = TempFolder()
        let data = bytes(5000)
        let url = StubServer.serve(.init(data: data))
        let file = tmp.url.appendingPathComponent("f.bin")
        try data.write(to: FileDownloader.partialFile(for: file))
        try await FileDownloader.download(url, to: file, resume: true, configuration: StubServer.configuration) { _, _ in }
        #expect(try Data(contentsOf: file) == data)
        #expect(!FileManager.default.fileExists(atPath: FileDownloader.partialFile(for: file).path))
        #expect(StubServer.ranges(of: url) == ["bytes=5000-"])                        // asked once, nothing was sent
    }

    @Test func aDownloadThatCantGoOnLeavesNoPartBehind() async throws {
        let tmp = TempFolder()
        let file = tmp.url.appendingPathComponent("f.bin")
        let dropped = StubServer.serve(.init(data: bytes(5000), drops: 1, dropAfter: 1500))
        await #expect(throws: (any Error).self) {
            try await FileDownloader.download(dropped, to: file, configuration: StubServer.configuration) { _, _ in }
        }
        let gone = StubServer.serve(.init(data: Data(), status: 404))
        await #expect(throws: ShellError.self) {
            try await FileDownloader.download(gone, to: file, configuration: StubServer.configuration) { _, _ in }
        }
        // Not a download that goes on (an installer): its part would be a file nobody ever picks up.
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).isEmpty)
    }

    @Test func anErrorStatusIsAnErrorAndLeavesNoFile() async throws {
        let tmp = TempFolder()
        let url = StubServer.serve(.init(data: Data(), status: 404), name: "gone.tar.xz")
        let file = tmp.url.appendingPathComponent("f.bin")
        await #expect(throws: ShellError.self) {
            try await FileDownloader.download(url, to: file, configuration: StubServer.configuration) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let error = try await #require(throws: ShellError.self) {
            try await FileDownloader.download(url, to: file, configuration: StubServer.configuration) { _, _ in }
        }
        #expect(error.localizedDescription.contains("404") && error.localizedDescription.contains("gone.tar.xz"))
    }

    @Test func aDroppedConnectionKeepsWhatCame() async throws {
        let tmp = TempFolder()
        let url = StubServer.serve(.init(data: bytes(5000), drops: 1, dropAfter: 1500))
        let file = tmp.url.appendingPathComponent("f.bin")
        do {
            try await FileDownloader.download(url, to: file, resume: true, configuration: StubServer.configuration) { _, _ in }
            Issue.record("the connection should have dropped")
        } catch {
            #expect((error as? URLError)?.code == .networkConnectionLost)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(Files.size(of: FileDownloader.partialFile(for: file)) == 1500)
    }

    @Test func stoppingKeepsThePartToo() async throws {
        let tmp = TempFolder()
        let url = StubServer.serve(.init(data: bytes(5000), stallAfter: 1000))
        let file = tmp.url.appendingPathComponent("f.bin")
        let task = Task {
            try await FileDownloader.download(url, to: file, resume: true, configuration: StubServer.configuration) { _, _ in }
        }
        // Wait until something has come, then stop.
        for _ in 0..<200 where Files.size(of: FileDownloader.partialFile(for: file)) == 0 { try await Task.sleep(for: .milliseconds(25)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Files.size(of: FileDownloader.partialFile(for: file)) == 1000)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite struct EngineFetchTests {
    private func manager(_ tmp: TempFolder) -> EngineManager { EngineManager(paths: LibraryPaths(root: tmp.url.appendingPathComponent("Lib"))) }

    private func item(_ data: Data, url: URL) -> PinnedDownload {
        PinnedDownload(url: url, fileName: "engine.tar.xz", sha256: sha(data), approximateBytes: Int64(data.count))
    }

    @Test func aConnectionThatDropsHalfwayIsPickedUpWhereItStopped() async throws {
        let tmp = TempFolder()
        let data = bytes(20_000)
        let url = StubServer.serve(.init(data: data, drops: 2, dropAfter: 7000))
        let file = tmp.url.appendingPathComponent("engine.tar.xz")
        let notes = LockedValue<[String]>([])
        try await manager(tmp).fetch(item(data, url: url), to: file, configuration: StubServer.configuration, delays: [0.01, 0.01, 0.01]) { _, note in
            if let note { notes.update { $0.append(note) } }
        }
        #expect(try Data(contentsOf: file) == data)
        let ranges = StubServer.ranges(of: url)
        #expect(ranges.count == 3 && ranges[0] == nil && ranges[1] == "bytes=7000-" && ranges[2] == "bytes=14000-")
        #expect(notes.get().contains("The connection dropped. Trying again…"))
    }

    @Test func aWholePartIsCheckedAgainstItsChecksumNotDownloadedAgain() async throws {
        let tmp = TempFolder()
        let data = bytes(10_000)
        let url = StubServer.serve(.init(data: data))
        let file = tmp.url.appendingPathComponent("engine.tar.xz")
        try data.write(to: FileDownloader.partialFile(for: file))
        try await manager(tmp).fetch(item(data, url: url), to: file, configuration: StubServer.configuration) { _, _ in }
        #expect(try Data(contentsOf: file) == data)
        #expect(StubServer.ranges(of: url) == ["bytes=10000-"])
    }

    @Test func aWholePartThatIsTheWrongFileIsDownloadedFromTheStart() async throws {
        let tmp = TempFolder()
        let data = bytes(10_000)
        let url = StubServer.serve(.init(data: data))
        let file = tmp.url.appendingPathComponent("engine.tar.xz")
        try bytes(10_000, seed: 9).write(to: FileDownloader.partialFile(for: file))      // as long as the file, but not it
        try await manager(tmp).fetch(item(data, url: url), to: file, configuration: StubServer.configuration) { _, _ in }
        #expect(try Data(contentsOf: file) == data)
        #expect(StubServer.ranges(of: url) == ["bytes=10000-", nil])
    }

    @Test func nothingCameAtAllIsAnErrorAtOnce() async throws {
        let tmp = TempFolder()
        let data = bytes(20_000)
        let url = StubServer.serve(.init(data: data, drops: 5, dropAfter: 0))
        let file = tmp.url.appendingPathComponent("engine.tar.xz")
        await #expect(throws: URLError.self) {
            try await manager(tmp).fetch(item(data, url: url), to: file, configuration: StubServer.configuration, delays: [0.01]) { _, _ in }
        }
        #expect(StubServer.ranges(of: url).count == 1)
    }

    @Test func aFileGluedFromTriesThatFailsItsChecksumIsFetchedOnceMoreFromTheStart() async throws {
        let tmp = TempFolder()
        let data = bytes(10_000)
        let url = StubServer.serve(.init(data: data))
        let file = tmp.url.appendingPathComponent("engine.tar.xz")
        try bytes(3000, seed: 9).write(to: FileDownloader.partialFile(for: file))          // a part that went stale
        try await manager(tmp).fetch(item(data, url: url), to: file, configuration: StubServer.configuration) { _, _ in }
        #expect(try Data(contentsOf: file) == data)
        #expect(StubServer.ranges(of: url) == ["bytes=3000-", nil])
    }

    @Test func aWrongFileFromTheStartIsRefusedAndRemoved() async throws {
        let tmp = TempFolder()
        let data = bytes(10_000)
        let url = StubServer.serve(.init(data: bytes(10_000, seed: 9)))
        let file = tmp.url.appendingPathComponent("engine.tar.xz")
        let error = try await #require(throws: ShellError.self) {
            try await manager(tmp).fetch(item(data, url: url), to: file, configuration: StubServer.configuration) { _, _ in }
        }
        #expect(error.localizedDescription.contains("checksum"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(StubServer.ranges(of: url).count == 1)
    }
}

@Suite struct EngineLeftoversTests {
    private func installFakeEngine(_ info: EngineInfo, in manager: EngineManager) throws {
        let bin = manager.folder(for: info).appendingPathComponent("Wine Staging.app/Contents/Resources/wine/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("wine").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
    }

    @Test func theHiddenFolderOfAnInstallThatNeverEndedIsRemovedAndNothingElse() throws {
        let tmp = TempFolder()
        let manager = EngineManager(paths: LibraryPaths(root: tmp.url))
        try manager.paths.createFolders()
        let id = EngineCatalog.crossover.id
        let staging = tmp.dir("Engines/.\(id)-1A2B3C4D")
        tmp.file("Engines/.\(id)-1A2B3C4D/wine/bin/wine")
        let other = tmp.dir("Engines/.something-else")
        let visible = tmp.dir("Engines/\(id)")
        let tools = tmp.dir("Engines/tools")
        manager.cleanLeftovers()
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        for kept in [other, visible, tools] { #expect(FileManager.default.fileExists(atPath: kept.path)) }
    }

    @Test func aRetiredEngineIsFoundWhereItIsInstalledAndItsLeftoversAreCleanedToo() throws {
        let tmp = TempFolder()
        let manager = EngineManager(paths: LibraryPaths(root: tmp.url))
        try manager.paths.createFolders()
        let retired = EngineCatalog.crossoverRevision1
        #expect(manager.engine(id: retired.id) == nil)
        let bin = tmp.dir("Engines/\(retired.id)/wine/bin")
        FileManager.default.createFile(atPath: bin.appendingPathComponent("wine").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        #expect(manager.engine(id: retired.id)?.info.id == retired.id && manager.isInstalled(retired))
        #expect(manager.engine(id: EngineCatalog.crossover.id) == nil)                    // revision 2 isn't there
        let staging = tmp.dir("Engines/.\(retired.id)-1A2B3C4D")
        let downloads = tmp.file("Downloads/\(retired.id)/g-player-engine.tar.xz")
        manager.cleanLeftovers()
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: downloads.path))                  // installed: its downloads go
        #expect(manager.isInstalled(retired))
        try manager.remove(retired)
        #expect(!manager.isInstalled(retired))
    }

    @Test func downloadsOfAnInstalledEngineGoAndThoseOfOtherEnginesStayUntilTheyAreOld() throws {
        let tmp = TempFolder()
        let manager = EngineManager(paths: LibraryPaths(root: tmp.url))
        try manager.paths.createFolders()
        try installFakeEngine(EngineCatalog.wineStaging, in: manager)
        let stagingDownloads = tmp.dir("Downloads/\(EngineCatalog.wineStaging.id)")
        tmp.file("Downloads/\(EngineCatalog.wineStaging.id)/a.tar.xz")
        let part = tmp.file("Downloads/\(EngineCatalog.crossover.id)/g-player-engine.tar.xz.part")
        manager.cleanLeftovers()
        #expect(!FileManager.default.fileExists(atPath: stagingDownloads.path))
        #expect(FileManager.default.fileExists(atPath: part.path))                    // a download to go on with
        manager.cleanLeftovers(now: Date().addingTimeInterval(8 * 24 * 3600))        // untouched for over a week
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func removingAnEngineRemovesItsLeftOverDownloadsToo() throws {
        let tmp = TempFolder()
        let manager = EngineManager(paths: LibraryPaths(root: tmp.url))
        try manager.paths.createFolders()
        try installFakeEngine(EngineCatalog.wineStaging, in: manager)
        let part = tmp.file("Downloads/\(EngineCatalog.wineStaging.id)/x.part")
        try manager.remove(EngineCatalog.wineStaging)
        #expect(!manager.isInstalled(EngineCatalog.wineStaging))
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }
}

/// G-Player Wine installed on a Mac without Wine Staging, as the first run does it: Gcenx's archive is downloaded for the runtime
/// libraries, unpacked, its libraries copied, and the archive deleted. Stand-in archives with checksums made here wait where the
/// download would put them (a file with the pinned checksum is not downloaded again), so nothing goes over the network.
@Suite struct RuntimeLibrariesInstallTests {
    let id = "wine-cx-test"

    private func pinned(_ name: String, role: PinnedDownload.Role, files: [String: String], executable: [String] = [],
                        _ tmp: TempFolder) async throws -> PinnedDownload {
        let source = tmp.dir("source/\(name)")
        for (path, text) in files { tmp.file("source/\(name)/\(path)", contents: Data(text.utf8)) }
        for path in executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent(path).path)
        }
        let archive = tmp.file("Downloads/\(id)/\(name).tar", bytes: 0)
        let made = try await Shell.runStoppable(Shell.tool("tar"), ["-cf", archive.path, "-C", source.path, "."])
        #expect(made.succeeded)
        return PinnedDownload(url: URL(string: "https://example.invalid/\(name).tar")!, fileName: "\(name).tar",
                              sha256: try Files.sha256(of: archive), approximateBytes: Files.size(of: archive), role: role)
    }

    @Test func gPlayerWineTakesItsLibrariesFromGcenxsArchiveAndDeletesIt() async throws {
        let tmp = TempFolder()
        let manager = EngineManager(paths: LibraryPaths(root: tmp.url))
        let lib = "Wine Staging.app/Contents/Resources/wine/lib"
        let engine = try await pinned("engine", role: .engine, files: ["wine/bin/wine": "#!/bin/sh\n", "wine/lib/libMoltenVK.dylib": "ours"],
                                      executable: ["wine/bin/wine"], tmp)
        let runtime = try await pinned("gcenx", role: .runtimeLibraries,
                                       files: ["\(lib)/libfreetype.6.dylib": "freetype", "\(lib)/libgnutls.30.dylib": "gnutls",
                                               "\(lib)/libSDL2-2.0.0.dylib": "sdl", "\(lib)/libvulkan.1.dylib": "loader",
                                               "\(lib)/libMoltenVK.dylib": "theirs"], tmp)
        let dxvk = try await pinned("dxvk", role: .dxvk, files: ["dxvk-test/x64/d3d11.dll": "x64", "dxvk-test/x32/d3d11.dll": "x32"], tmp)
        let info = EngineInfo(id: id, name: "G-Player Wine", version: "11.0", kind: .crossover, summary: "",
                              backends: [.dxvk, .wined3d], downloads: [engine, runtime, dxvk])
        #expect(!manager.isInstalled(EngineCatalog.wineStaging))

        let installed = try await manager.install(info) { _, _ in }

        #expect(manager.isInstalled(info) && installed.dxvk != nil)
        let wineLib = installed.wineRoot.appendingPathComponent("lib")
        for name in EngineManager.runtimeLibraries {
            #expect(FileManager.default.fileExists(atPath: wineLib.appendingPathComponent(name).path), "\(name)")
        }
        // The Vulkan loader isn't used and MoltenVK is G-Player's own: neither is taken from Gcenx's archive.
        #expect(!FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("libvulkan.1.dylib").path))
        #expect(try String(contentsOf: wineLib.appendingPathComponent("libMoltenVK.dylib"), encoding: .utf8) == "ours")
        // Wine Staging wasn't installed for it, and Gcenx's archive and its unpacked copy are gone.
        #expect(!manager.isInstalled(EngineCatalog.wineStaging))
        #expect(try FileManager.default.contentsOfDirectory(atPath: manager.paths.engines.path) == [id])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: manager.folder(for: info).path)) == ["wine", "dxvk"])
        #expect(!FileManager.default.fileExists(atPath: manager.downloadFolder(for: info).path))
    }
}

/// Installing from files that are in the engine's downloads folder already (nothing is fetched): what stays there until the
/// install has ended, so that one that fails in its last step doesn't download everything again.
@Suite struct EngineInstallKeepsDownloadsTests {
    private let wine = "Wine Staging.app/Contents/Resources/wine/bin/wine"

    private func manager(_ tmp: TempFolder) -> EngineManager { EngineManager(paths: LibraryPaths(root: tmp.url.appendingPathComponent("Lib"))) }

    /// A tar of `files` (relative path: contents), the ones named in `executables` made executable.
    private func archive(_ tmp: TempFolder, _ name: String, _ files: [String: String], executables: [String] = []) async throws -> Data {
        let source = tmp.dir("source-\(name)")
        for (path, text) in files { tmp.file("source-\(name)/\(path)", contents: Data(text.utf8)) }
        for path in executables {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent(path).path)
        }
        let made = try await Shell.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-cf", tmp.url.appendingPathComponent(name).path, "-C", source.path, "."])
        try #require(made.succeeded, "\(made.stderr)")
        return try Data(contentsOf: tmp.url.appendingPathComponent(name))
    }

    private func item(_ name: String, _ data: Data, role: PinnedDownload.Role = .engine) -> PinnedDownload {
        PinnedDownload(url: URL(string: "https://stub.test/\(name)")!, fileName: name, sha256: sha(data),
                       approximateBytes: Int64(data.count), role: role)
    }

    private func engine(_ downloads: [PinnedDownload], installedBytes: Int64 = 0) -> EngineInfo {
        EngineInfo(id: "test-engine", name: "Test Wine", version: "1", kind: .wineStaging, summary: "", backends: [.wined3d],
                   downloads: downloads, installedBytes: installedBytes)
    }

    private func keep(_ data: Data, _ item: PinnedDownload, _ info: EngineInfo, in manager: EngineManager) throws {
        let file = manager.downloadFile(item, of: info)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    @Test func anInstallThatFailsInItsLastStepKeepsEveryFileItHad() async throws {
        let tmp = TempFolder()
        let package = Data("not a package".utf8)
        let list = "package gst-test.pkg \(sha(package))\nlib/a.dylib\n"
        let main = try await archive(tmp, "engine.tar", [wine: "#!/bin/sh\n", "gstreamer-files.txt": list], executables: [wine])
        let extra = try await archive(tmp, "extra.tar", ["extra.txt": "more"])
        let items = [item("engine.tar", main), item("extra.tar", extra), item("gst-test.pkg", package, role: .gstreamer)]
        let info = engine(items), manager = manager(tmp)
        for (data, item) in zip([main, extra, package], items) { try keep(data, item, info, in: manager) }

        let error = try await #require(throws: ShellError.self) { try await manager.install(info) { _, _ in } }
        #expect(error.localizedDescription.contains("Couldn't unpack gst-test.pkg"))
        // Nothing is installed, and nothing that came has to come again.
        #expect(!manager.isInstalled(info))
        for item in items { #expect(FileManager.default.fileExists(atPath: manager.downloadFile(item, of: info).path), "\(item.fileName)") }
    }

    @Test func aSuccessfulInstallKeepsEachFileUntilTheEndAndThenDeletesThem() async throws {
        let tmp = TempFolder()
        let main = try await archive(tmp, "engine.tar", [wine: "#!/bin/sh\n"], executables: [wine])
        let extra = try await archive(tmp, "extra.tar", ["extra.txt": "more"])
        let items = [item("engine.tar", main), item("extra.tar", extra)]
        let info = engine(items), manager = manager(tmp)
        for (data, item) in zip([main, extra], items) { try keep(data, item, info, in: manager) }

        let firstWhileUnpackingTheSecond = LockedValue<Bool?>(nil)
        let first = manager.downloadFile(items[0], of: info)
        // What the install's log gets: the steps in English.
        let logged = LockedValue<[String]>([])
        var withLog = manager
        withLog.log = { line in logged.update { $0.append(line) } }
        let installed = try await withLog.install(info) { _, message in
            if message == "Unpacking extra.tar" { firstWhileUnpackingTheSecond.set(FileManager.default.fileExists(atPath: first.path)) }
        }
        #expect(firstWhileUnpackingTheSecond.get() == true)         // not deleted as soon as it was unpacked
        #expect(logged.get().contains("Unpacking extra.tar") && logged.get().last == "Ready")
        #expect(manager.isInstalled(info) && installed.info.id == info.id)
        #expect(FileManager.default.fileExists(atPath: manager.folder(for: info).appendingPathComponent("extra.txt").path))
        #expect(!FileManager.default.fileExists(atPath: manager.downloadFolder(for: info).path))
    }

    @Test func filesAnEarlierTryLeftAreNotCountedAgainByTheDiskCheck() async throws {
        let tmp = TempFolder()
        let main = Data(count: 4000), extra = Data(count: 1000)
        let items = [item("engine.tar", main), item("extra.tar", extra)]
        let info = engine(items, installedBytes: 10_000), manager = manager(tmp)
        // Nothing there yet: the formula as it is.
        #expect(manager.diskNeeded(installing: [info]) == EngineCatalog.diskBytes(installing: [info]))
        #expect(EngineCatalog.diskBytes(installing: [info]) == 10_000 + 4000 + 1000)
        // A whole file and the part of another are on the disk already.
        try keep(main, items[0], info, in: manager)
        try Data(count: 300).write(to: FileDownloader.partialFile(for: manager.downloadFile(items[1], of: info)))
        #expect(manager.diskNeeded(installing: [info]) == 15_000 - 4000 - 300)
        // Everything there: the unpacked engine is all that is left to make room for.
        try keep(extra, items[1], info, in: manager)
        #expect(manager.diskNeeded(installing: [info]) == 10_000 - 300)
        // Several engines one after the other: no credit, the figure is the plain formula.
        #expect(manager.diskNeeded(installing: [info, EngineCatalog.wineStaging]) == EngineCatalog.diskBytes(installing: [info, EngineCatalog.wineStaging]))
    }
}

/// A value shared with a callback that runs on another thread.
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func update(_ change: (inout T) -> Void) { lock.lock(); change(&value); lock.unlock() }
}
