import Foundation
import Testing
@testable import GPlayerCore

@Suite struct InstallLogTests {
    @Test func progressWithinAStepIsOneLine() {
        let log = InstallLog(title: "Update G-Player Wine")
        for m in ["Starting", "Downloading 1 of 446 MB", "Downloading 2 of 446 MB", "Checking engine.tar.xz",
                  "Unpacking engine.tar.xz", "Downloading 300 of 446 MB"] { log.record(m) }
        let lines = log.text(outcome: "Ready").split(separator: "\n").map(String.init)
        // The title, each step once in turn (a step that comes back later is a new line), then the outcome; every line
        // after the title starts with the time since the start ("[00:00] ").
        #expect(lines.first == "Update G-Player Wine")
        #expect(lines.dropFirst().map { String($0.dropFirst(8)) } == ["Starting", "Downloading 1 of 446 MB",
            "Checking engine.tar.xz", "Unpacking engine.tar.xz", "Downloading 300 of 446 MB", "Ready"])
    }

    @Test func aStepIsTheWordsBeforeTheFirstNumber() {
        #expect(InstallLog.step(of: "Downloading 41 of 98 MB") == "Downloading")
        #expect(InstallLog.step(of: "Unpacking gstreamer-1.0-1.28.8-universal.pkg") == "Unpacking gstreamer-1.0-1.28.8-universal.pkg")
    }

    @Test func itIsWrittenToTheLogsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("installlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = InstallLog(title: "Install G-Player Wine")
        log.record("Downloading 1 of 2 MB")
        log.write(outcome: InstallLog.failure(URLError(.timedOut)), to: folder)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 1 && files[0].hasPrefix("Install G-Player Wine "))
        let text = try String(contentsOf: folder.appendingPathComponent(files[0]), encoding: .utf8)
        #expect(text.contains("Failed:") && text.contains("Downloading 1 of 2 MB"))
    }
}
