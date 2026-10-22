import Foundation
import Testing
@testable import GPlayerCore

// Failures, time limits and cancellation of component installs. No Wine: a fake installer stands in for the real
// one, and /bin/sleep stands in for a setup program that hangs.

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private func isGone(_ pid: Int32) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }

/// Waits up to `seconds` for a condition.
private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

// MARK: Install keeps going and remembers failures

@Suite struct InstallFailureTests {
    let tmp = TempFolder()
    var paths: LibraryPaths { LibraryPaths(root: tmp.url.appendingPathComponent("Library")) }
    var s: Space { space(at: tmp.prefix("Main")) }

    private func installer(failing: Set<String> = [], order: Collected = Collected()) -> RuntimeInstaller {
        RuntimeInstaller(paths: paths) { id, _, _, _, _ in
            order.add(id)
            if failing.contains(id) { throw ShellError.failed("\(id) broke") }
        }
    }

    @Test func aFailureDoesNotStopTheOthers() async throws {
        let order = Collected()
        let installer = installer(failing: ["d3dx9", "xact"], order: order)
        let s = self.s
        do {
            try await installer.install(["d3dx9", "vcrun2008", "xact", "physx"], in: s, engine: fakeEngine()) { _, _ in }
            Issue.record("expected an error")
        } catch {
            let text = error.localizedDescription
            // One error that names every component that failed, with its reason.
            #expect(text.contains("DirectX 9 helpers") && text.contains("XACT audio"), "\(text)")
            #expect(text.contains("d3dx9 broke") && text.contains("xact broke"), "\(text)")
            #expect(!text.contains("NVIDIA PhysX") && !text.contains("Visual C++ 2008"), "\(text)")
        }
        #expect(order.all == ["d3dx9", "xact", "physx", "vcrun2008"])                 // catalog order, all tried
        #expect(installer.installed(in: s) == ["vcrun2008", "physx"])
        #expect(Set(installer.failed(in: s).keys) == ["d3dx9", "xact"])
    }

    @Test func oneFailureReadsAsASingleSentence() async {
        let installer = installer(failing: ["physx"])
        do {
            try await installer.install(["physx"], in: s, engine: fakeEngine()) { _, _ in }
            Issue.record("expected an error")
        } catch { #expect(error.localizedDescription == "Couldn't install NVIDIA PhysX. physx broke") }
    }

    @Test func failuresAreWrittenWithTheirDate() async throws {
        let installer = installer(failing: ["d3dx9"])
        let s = self.s
        let before = Date()
        _ = try? await installer.install(["d3dx9", "vcrun2008"], in: s, engine: fakeEngine()) { _, _ in }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: s.url.appendingPathComponent(".gplayer-components.json")))
        let file = try #require(json as? [String: Any])
        let failed = try #require(file["failed"] as? [String: String])
        #expect(failed.keys.sorted() == ["d3dx9"])
        let date = try #require(ISO8601DateFormatter().date(from: failed["d3dx9"] ?? ""))
        #expect(abs(date.timeIntervalSince(before)) < 5)
        #expect((file["installed"] as? [String: String])?.keys.sorted() == ["vcrun2008"])
        #expect(abs((installer.failed(in: s)["d3dx9"] ?? .distantPast).timeIntervalSince(before)) < 5)
    }

    @Test func aFailedComponentIsLeftAloneForThreeDaysUnlessAskedAgain() throws {
        let installer = installer()
        let s = self.s
        let failedAt = Date(timeIntervalSince1970: 1_000_000)
        try installer.recordFailure("d3dx9", in: s, at: failedAt)
        try installer.record("vcrun2008", in: s)
        let ids = ["d3dx9", "vcrun2008", "xact"]
        let day: TimeInterval = 24 * 60 * 60
        #expect(installer.missing(ids, in: s, retryFailed: false, now: failedAt + 1 * day) == ["xact"])
        #expect(installer.missing(ids, in: s, retryFailed: false, now: failedAt + 2.9 * day) == ["xact"])
        #expect(installer.missing(ids, in: s, retryFailed: false, now: failedAt + 3.1 * day) == ["d3dx9", "xact"])
        #expect(installer.missing(ids, in: s, retryFailed: true, now: failedAt + 1 * day) == ["d3dx9", "xact"])
        // The public form: a failure from just now is skipped, and asking again brings it back.
        try installer.recordFailure("xact", in: s)
        #expect(installer.missing(ids, in: s) == ["d3dx9"])
        #expect(installer.missing(ids, in: s, retryFailed: true) == ["d3dx9", "xact"])
    }

    @Test func installingAskedForAgainTriesAndAFreshSuccessForgetsTheFailure() async throws {
        let s = self.s
        let failing = RuntimeInstaller(paths: paths) { id, _, _, _, _ in throw ShellError.failed("no") }
        _ = try? await failing.install(["d3dx9"], in: s, engine: fakeEngine()) { _, _ in }
        #expect(Set(failing.failed(in: s).keys) == ["d3dx9"])
        #expect(failing.missing(["d3dx9"], in: s).isEmpty)                            // not offered again right away
        let working = RuntimeInstaller(paths: paths) { _, _, _, _, _ in }
        try await working.install(["d3dx9"], in: s, engine: fakeEngine()) { _, _ in }   // the user asked: it is tried anyway
        #expect(working.installed(in: s) == ["d3dx9"])
        #expect(working.failed(in: s).isEmpty)
    }

    @Test func oldStateFilesAndDamagedDatesAreFine() throws {
        let installer = installer()
        let s = self.s
        tmp.file("Main/.gplayer-components.json", contents: Data(#"{"installed": {"d3dx9": "2026-01-01T00:00:00Z"}}"#.utf8))
        #expect(installer.installed(in: s) == ["d3dx9"])
        #expect(installer.failed(in: s).isEmpty)
        tmp.file("Main/.gplayer-components.json", contents: Data(#"{"failed": {"xact": "yesterday", "physx": "2026-01-01T00:00:00Z"}}"#.utf8))
        #expect(Set(installer.failed(in: s).keys) == ["physx"])
        #expect(installer.missing(["xact"], in: s) == ["xact"])
        try installer.record("openal", in: s)                                          // writing keeps working
        #expect(installer.installed(in: s) == ["openal"])
    }

    @Test func standInIdsAreInstalledAsWhatTheyStandFor() async throws {
        let order = Collected()
        let installer = installer(order: order)
        let s = self.s
        #expect(installer.missing(["vcrun2019", "vcrun2022", "vcrun2017"], in: s) == ["vcrun2022"])
        try await installer.install(["vcrun2019", "vcrun2017"], in: s, engine: fakeEngine()) { _, _ in }
        #expect(order.all == ["vcrun2022"])
        #expect(installer.installed(in: s) == ["vcrun2022"])
        #expect(installer.missing(["vcrun2015"], in: s).isEmpty)
    }
}

// MARK: Time limits and cancellation

@Suite struct InstallSupervisionTests {
    let tmp = TempFolder()

    private func runSleep(_ seconds: String = "30", timeout: TimeInterval?, onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Winetricks.Finished {
        try await Winetricks.run(URL(fileURLWithPath: "/bin/sleep"), [seconds], environment: [:], currentDirectory: tmp.url,
                                 log: tmp.url.appendingPathComponent("run.log"), timeout: timeout, onLine: onLine)
    }

    @Test func aProgramThatRunsTooLongIsStoppedAndSaysSo() async {
        let start = Date()
        do {
            _ = try await runSleep(timeout: 0.4)
            Issue.record("expected a time-out")
        } catch let timedOut as Supervised.TimedOut {
            #expect(timedOut.seconds == 0.4)
            #expect(timedOut.localizedDescription.contains("took longer"))
        } catch { Issue.record("wrong error: \(error)") }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func aProgramThatFinishesInTimeIsNotDisturbed() async throws {
        let result = try await runSleep("0.1", timeout: 20)
        #expect(result.status == 0)
        let failing = try await Winetricks.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo hello; exit 3"], environment: [:],
                                               currentDirectory: tmp.url, log: tmp.url.appendingPathComponent("b.log"), timeout: 20) { _ in }
        #expect(failing.status == 3 && failing.tail == "hello")
        #expect(try String(contentsOf: tmp.url.appendingPathComponent("b.log"), encoding: .utf8) == "hello\n")
    }

    @Test func aProgramLeftRunningWithThePipeOpenDoesNotHoldTheInstall() async throws {
        // Like winetricks leaving a wineserver behind that inherited its output.
        let start = Date()
        let done = try await Winetricks.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo hi; (sleep 6 &); exit 0"],
                                            environment: [:], currentDirectory: tmp.url,
                                            log: tmp.url.appendingPathComponent("c.log"), timeout: 20) { _ in }
        #expect(done.status == 0 && done.tail == "hi")
        #expect(Date().timeIntervalSince(start) < 4.5)
        #expect(try String(contentsOf: tmp.url.appendingPathComponent("c.log"), encoding: .utf8) == "hi\n")
    }

    @Test func cancellingStopsTheProgramAndWhatItStarted() async throws {
        let pids = Collected()
        let task = Task {
            try await Winetricks.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $$; sleep 30 & echo $!; wait"], environment: [:],
                                     currentDirectory: tmp.url, log: tmp.url.appendingPathComponent("c.log"), timeout: nil) { pids.add($0) }
        }
        #expect(await eventually { pids.all.count == 2 })
        let running = pids.all.compactMap { Int32($0) }
        #expect(running.count == 2 && running.allSatisfy { !isGone($0) })
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected a cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(await eventually { running.allSatisfy(isGone) }, "the program or its child is still running")
    }

    @Test func aTaskCancelledBeforeItStartsNeverStartsTheProgram() async throws {
        let marker = tmp.url.appendingPathComponent("started")
        let task = Task { () -> Winetricks.Finished in
            try await Task.sleep(for: .milliseconds(300))                             // cancelled while waiting here
            return try await Winetricks.run(URL(fileURLWithPath: "/usr/bin/touch"), [marker.path], environment: [:],
                                            currentDirectory: tmp.url, log: tmp.url.appendingPathComponent("d.log"), timeout: nil) { _ in }
        }
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func waitingForProgramsStopsAtTheLimitAndNeverThrows() async {
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        let start = Date()
        #expect(await Supervised.exits(sleep, ["30"], timeout: 0.3) == false)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(await Supervised.exits(URL(fileURLWithPath: "/usr/bin/true"), [], timeout: 20))
        #expect(await Supervised.exits(sleep, ["0.1"], timeout: nil))
        #expect(await Supervised.exits(URL(fileURLWithPath: "/nonexistent/program"), [], timeout: 1) == false)
    }

    @Test func waitingForProgramsAlsoStopsWhenCancelled() async {
        let task = Task { await Supervised.exits(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: nil) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        #expect(await task.value == false)
    }

    @Test func waitForAllGivesUpAtItsLimitWithoutTouchingTheServer() async throws {
        guard await Shell.isRosettaInstalled() else { return }
        // A "wineserver" that waits for ever; the real one would be a client waiting for the space's programs.
        let root = tmp.dir("engine/wine")
        tmp.file("engine/wine/bin/wineserver", contents: Data("#!/bin/sh\nexec sleep 30\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("bin/wineserver").path)
        let engine = Engine(info: EngineCatalog.wineStaging, wineRoot: root, wine: root.appendingPathComponent("bin/wine"), dxvk: nil)
        let s = space(at: tmp.prefix("Main"))
        let start = Date()
        #expect(await WineLauncher.waitForAll(engine: engine, space: s, timeout: 0.5) == false)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func descendantsAreFoundFromTheProcessTable() {
        let table = """
              1     0
            100     1
            101   100
            102   100
            103   101
            200     1
            201   200
        garbage line
        """
        #expect(Supervised.descendants(of: 100, in: table) == [101, 102, 103])
        #expect(Supervised.descendants(of: 200, in: table) == [201])
        #expect(Supervised.descendants(of: 103, in: table).isEmpty)
        #expect(Supervised.descendants(of: 999, in: table).isEmpty)
        #expect(Supervised.descendants(of: 100, in: "5 100\n100 5\n").sorted() == [5])          // a loop never repeats itself
    }

    // MARK: Through the installer

    @Test func theTimeLimitReachesEveryComponentAndATimeOutIsAFailure() async {
        let paths = LibraryPaths(root: tmp.url.appendingPathComponent("Library"))
        let seen = Collected()
        let sleep = tmp.url
        let installer = RuntimeInstaller(paths: paths) { id, _, _, timeout, _ in
            seen.add("\(id) \(timeout)")
            if id == "d3dx9" {
                _ = try await Winetricks.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], environment: [:], currentDirectory: sleep,
                                             log: sleep.appendingPathComponent("slow.log"), timeout: timeout) { _ in }
            }
        }
        let s = space(at: tmp.prefix("Main"))
        do {
            try await installer.install(["d3dx9", "physx"], in: s, engine: fakeEngine(), timeout: 0.4) { _, _ in }
            Issue.record("expected an error")
        } catch { #expect(error.localizedDescription.contains("took longer"), "\(error.localizedDescription)") }
        #expect(seen.all == ["d3dx9 0.4", "physx 0.4"])
        #expect(installer.installed(in: s) == ["physx"])
        #expect(Set(installer.failed(in: s).keys) == ["d3dx9"])
        // The default is 15 minutes.
        let defaults = Collected()
        let quick = RuntimeInstaller(paths: paths) { id, _, _, timeout, _ in defaults.add("\(timeout)") }
        try? await quick.install(["openal"], in: s, engine: fakeEngine()) { _, _ in }
        #expect(defaults.all == ["900.0"])
        #expect(RuntimeInstaller.defaultTimeout == 900 && RuntimeInstaller.settleTimeout == 120)
    }

    @Test func cancellingTheInstallRecordsNothingForTheUnfinishedComponent() async throws {
        let paths = LibraryPaths(root: tmp.url.appendingPathComponent("Library"))
        let started = Collected()
        let installer = RuntimeInstaller(paths: paths) { id, _, _, _, _ in
            started.add(id)
            if id == "xact" {
                try? await Task.sleep(for: .seconds(30))                              // returns at once when cancelled
                throw ShellError.failed("stopped")                                    // whatever the installer reports then
            }
        }
        let s = space(at: tmp.prefix("Main"))
        let task = Task { try await installer.install(["vcrun2008", "xact", "d3dx9"], in: s, engine: fakeEngine()) { _, _ in } }
        #expect(await eventually { started.all.contains("xact") })
        task.cancel()
        do {
            try await task.value
            Issue.record("expected a cancellation")
        } catch { #expect(error is CancellationError, "\(error)") }
        #expect(started.all == ["d3dx9", "xact"])                                     // vcrun2008 was never started
        #expect(installer.installed(in: s) == ["d3dx9"])                              // the finished one stays
        #expect(installer.failed(in: s).isEmpty)                                      // and nothing is recorded for xact
    }
}
