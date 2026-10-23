import Darwin
import Foundation
import Testing
@testable import GPlayerCore

// What happens to Legendary's processes: a stop waits until Legendary is gone (it locks what it installs), and one that a
// crashed G-Player left running is ended at the next start, if it is ours.

private func isGone(_ pid: Int32) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }

private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

@Suite struct PidFileTests {
    @Test func processIdsAreReadFromLinesAndNothingElse() {
        #expect(PidFile.parse("123\n456\n") == [123, 456])
        #expect(PidFile.parse(" 7 \r\n8") == [7, 8])
        #expect(PidFile.parse("12\n12\n12") == [12])                               // once
        #expect(PidFile.parse("abc\n-5\n0\n1\n9999999999\n\n2 3\n") == [])         // not a process id of anything of ours
        #expect(PidFile.parse("") == [])
        #expect(PidFile.text([]) == "" && PidFile.text([4, 5]) == "4\n5\n")
    }

    @Test func recordingAndForgettingKeepsTheFileInStep() {
        let tmp = TempFolder()
        let file = tmp.url.appendingPathComponent("running.pids")
        PidFile.record(100, in: file)
        PidFile.record(200, in: file)
        PidFile.record(100, in: file)
        #expect(PidFile.read(file) == [100, 200])
        PidFile.forget(100, in: file)
        #expect(PidFile.read(file) == [200])
        PidFile.forget(200, in: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))               // an empty file is no file
        PidFile.forget(5, in: file)                                                // forgetting what isn't there is fine
        #expect(PidFile.read(file).isEmpty)
    }
}

@Suite struct LegendaryProcessTests {
    let tmp = TempFolder()
    var paths: LibraryPaths { LibraryPaths(root: tmp.url.appendingPathComponent("Library")) }

    private func stand(_ body: String, name: String = "legendary") throws -> Legendary {
        let file = tmp.file("stand/\(name)", contents: Data("#!/bin/bash\n\(body)\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return Legendary(paths: paths, executable: file, checksum: try Files.sha256(of: file))
    }

    private var pidFileOfScript: URL { tmp.url.appendingPathComponent("script.pid") }
    private func scriptPID() -> Int32? {
        (try? String(contentsOf: pidFileOfScript, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// A program that takes a second to end once it is asked to.
    private var slowToEnd: String {
        "echo $$ > '\(pidFileOfScript.path)'\ntrap 'sleep 1; exit 0' TERM\nwhile true; do sleep 0.1; done"
    }

    // MARK: A stop waits for the process

    @Test func aStopIsReportedOnlyOnceLegendaryIsGone() async throws {
        let legendary = try stand(slowToEnd)
        let task = Task { try await legendary.run(["-y", "install", "SampleApp"], timeout: nil) }
        #expect(await eventually { scriptPID() != nil })
        let pid = try #require(scriptPID())
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(isGone(pid))                                                        // not still holding the lock a second later
    }

    @Test func aProgramThatNeverStartedDoesNotMakeTheStopWait() async throws {
        let legendary = try stand("true")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: legendary.executable.path)    // can't be run
        let started = Date()
        await #expect(throws: ShellError.self) { _ = try await legendary.run(["-y", "list"]) }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func theProcessIsInTheFileWhileItRunsAndGoneFromItAfter() async throws {
        let legendary = try stand("echo $$ > '\(pidFileOfScript.path)'\nsleep 30")
        let task = Task { try await legendary.run(["-y", "install", "SampleApp"], timeout: nil) }
        #expect(await eventually { !PidFile.read(legendary.pidFile).isEmpty })
        #expect(PidFile.read(legendary.pidFile).count == 1)
        task.cancel()
        _ = try? await task.value
        #expect(PidFile.read(legendary.pidFile).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: legendary.pidFile.path))
    }

    @Test func aFinishedRunLeavesNothingInTheFile() async throws {
        let legendary = try stand("echo '{\"account\": \"x\"}'")
        _ = try await legendary.status()
        #expect(PidFile.read(legendary.pidFile).isEmpty)
    }

    // MARK: Leftovers of a crashed G-Player

    @Test func onlyAProcessThatRunsThisLegendaryIsEnded() throws {
        let legendary = try stand("true")
        try FileManager.default.createDirectory(at: legendary.configFolder, withIntermediateDirectories: true)
        PidFile.write([101, 102, 103, 104], to: legendary.pidFile)
        let paths: [Int32: String?] = [101: legendary.executable.path, 102: "/usr/bin/python3", 103: nil,
                                       104: legendary.executable.path + "-other"]
        final class Ended: @unchecked Sendable { var pids: [Int32] = [] }
        let ended = Ended()
        let count = legendary.endLeftovers(pathOf: { paths[$0] ?? nil }, terminate: { ended.pids.append($0) })
        #expect(count == 1 && ended.pids == [101])
        #expect(!FileManager.default.fileExists(atPath: legendary.pidFile.path))       // the list starts again empty
    }

    @Test func aRunOfThisAppIsNeverEndedAsALeftover() async throws {
        let legendary = try stand("echo $$ > '\(pidFileOfScript.path)'\nsleep 30")
        let task = Task { try await legendary.run(["-y", "install", "SampleApp"], timeout: nil) }
        #expect(await eventually { !PidFile.read(legendary.pidFile).isEmpty })
        let running = PidFile.read(legendary.pidFile)
        final class Ended: @unchecked Sendable { var pids: [Int32] = [] }
        let ended = Ended()
        let count = legendary.endLeftovers(pathOf: { _ in legendary.executable.path }, terminate: { ended.pids.append($0) })
        #expect(count == 0 && ended.pids.isEmpty)
        #expect(PidFile.read(legendary.pidFile) == running)                              // and it stays on the list
        task.cancel()
        _ = try? await task.value
    }

    @Test func aLeftoverIsReallyEndedWithWhatItStarted() async throws {
        // A program an earlier G-Player started (a shell with a child), which nothing waits for any more.
        let legendary = try stand("echo $$ > '\(pidFileOfScript.path)'\nsleep 60 &\nwait")
        let process = Process()
        process.executableURL = legendary.executable
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        #expect(await eventually { scriptPID() != nil })
        let pid = process.processIdentifier
        let children = Supervised.descendants(of: pid, in: Supervised.processTable())
        #expect(await eventually { !Supervised.descendants(of: pid, in: Supervised.processTable()).isEmpty } || !children.isEmpty)
        let tree = [pid] + Supervised.descendants(of: pid, in: Supervised.processTable())
        try FileManager.default.createDirectory(at: legendary.configFolder, withIntermediateDirectories: true)
        PidFile.write([pid], to: legendary.pidFile)
        // The process is a shell running a script, so what the system says it runs is the shell: the test says it is the stand-in.
        let ended = legendary.endLeftovers(pathOf: { $0 == pid ? legendary.executable.path : nil }, terminate: Legendary.terminateTree)
        #expect(ended == 1)
        #expect(await eventually { tree.allSatisfy { isGone($0) || !processIsAlive($0) } })
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        // A process that has ended but isn't collected yet (the test's own child) counts as gone.
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 && info.pbi_status != UInt32(SZOMB)
    }

    @Test func theProcessTableAnswersWhatAProcessRuns() async throws {
        let mine = try #require(Legendary.executablePath(of: getpid()))
        #expect(FileManager.default.isExecutableFile(atPath: mine))
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        #expect(Legendary.executablePath(of: sleeper.processIdentifier) == "/bin/sleep")
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        #expect(Legendary.executablePath(of: finished.processIdentifier) == nil)
    }

    @Test func aSymlinkToTheFileIsTheSameFile() throws {
        let legendary = try stand("true")
        let link = tmp.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: legendary.executable)
        #expect(Legendary.samePath(link.path, legendary.executable.path))
        #expect(!Legendary.samePath("/bin/sleep", legendary.executable.path))
    }

    @Test func withNothingRecordedNothingIsEnded() throws {
        let legendary = try stand("true")
        #expect(legendary.endLeftovers() == 0)
        try FileManager.default.createDirectory(at: legendary.configFolder, withIntermediateDirectories: true)
        try Data("garbage\n".utf8).write(to: legendary.pidFile)
        #expect(legendary.endLeftovers() == 0)
        #expect(!FileManager.default.fileExists(atPath: legendary.pidFile.path))
    }
}
