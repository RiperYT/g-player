import Foundation
import Testing
@testable import GPlayerCore

@Suite struct ExecutableScannerTests {
    @Test func unityGameBeatsItsCrashHandler() {
        let tmp = TempFolder()
        tmp.file("Hollow/Hollow.exe", bytes: 600_000)
        tmp.dir("Hollow/Hollow_Data")
        tmp.file("Hollow/UnityCrashHandler64.exe", bytes: 1_500_000)
        let best = ExecutableScanner.scan(tmp.url.appendingPathComponent("Hollow")).first
        #expect(best?.name == "Hollow.exe")
        #expect(best?.hint == "Unity game")
    }

    @Test func uninstallersAndRedistsComeLast() {
        let tmp = TempFolder()
        tmp.file("G/unins000.exe", bytes: 3_000_000)
        tmp.file("G/_Redist/vcredist_x64.exe", bytes: 9_000_000)
        tmp.file("G/bin/MyGame.exe", bytes: 200_000)
        let names = ExecutableScanner.scan(tmp.url.appendingPathComponent("G"), title: "My Game").map(\.name)
        #expect(names.first == "MyGame.exe")
    }

    @Test func electronGameIsRecognised() {
        let tmp = TempFolder()
        tmp.file("M/Game.exe", bytes: 1000)
        tmp.dir("M/resources/app")
        let exe = tmp.url.appendingPathComponent("M/Game.exe")
        #expect(ExecutableScanner.scan(tmp.url.appendingPathComponent("M")).first?.hint == "Electron game")
        #expect(ExecutableCandidate.chromiumArguments(for: exe).contains("--in-process-gpu"))
    }

    @Test func folderWithOnlyASetupIsAnInstaller() {
        let tmp = TempFolder()
        tmp.file("I/setup.exe", bytes: 5000)
        tmp.file("I/data1.bin")
        #expect(ExecutableScanner.looksLikeInstaller(tmp.url.appendingPathComponent("I"))?.lastPathComponent == "setup.exe")
        tmp.file("P/Game.exe"); tmp.file("P/Editor.exe")
        #expect(ExecutableScanner.looksLikeInstaller(tmp.url.appendingPathComponent("P")) == nil)
    }

    @Test func suggestedTitlesAreClean() {
        #expect(ImportSource.archive(URL(fileURLWithPath: "/d/Hollow_Knight_1.5.rar")).suggestedTitle == "Hollow Knight 1.5")
        #expect(ImportSource.program(URL(fileURLWithPath: "/d/setup_hollow_knight.exe")).suggestedTitle == "hollow knight")
        #expect(ImportSource.archive(URL(fileURLWithPath: "/d/Game.tar.gz")).suggestedTitle == "Game")
    }

    @Test func archivesUnpackIntoOneGameFolder() async throws {
        let tmp = TempFolder()
        tmp.file("src/Inner/Game.exe")
        let zip = tmp.url.appendingPathComponent("g.zip")
        let r = try await Shell.run(Shell.tool("ditto"), ["-c", "-k", "--keepParent",
                                                          tmp.url.appendingPathComponent("src/Inner").path, zip.path])
        #expect(r.succeeded)
        let out = try await ArchiveExtractor.extract(zip, into: tmp.dir("dest"), name: "My Game")
        #expect(out.lastPathComponent == "My Game")
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Game.exe").path))
    }
}

@Suite struct ChromiumWrapperTests {
    let wrapper = Data("MZ wrapper macade-chromium-wrapper/2 end".utf8)

    @Test func wrapsOnceAndKeepsTheOriginal() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("S"))
        let original = Data(repeating: 7, count: 2000)
        tmp.file("S/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper.exe", contents: original)
        let pattern = AppPresets.steam.chromiumHelpers
        #expect(try ChromiumHelperWrapper.apply(helpers: pattern, in: s, wrapper: wrapper).count == 1)
        #expect(try ChromiumHelperWrapper.apply(helpers: pattern, in: s, wrapper: wrapper).isEmpty)
        let dir = s.driveC.appendingPathComponent("Program Files (x86)/Steam/bin/cef/cef.win64")
        #expect(FileManager.default.contents(atPath: dir.appendingPathComponent("steamwebhelper_real.exe").path) == original)
        #expect(FileManager.default.contents(atPath: dir.appendingPathComponent("steamwebhelper.exe").path) == wrapper)
    }

    @Test func rewrapsAfterAnUpdateRestoredTheHelper() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("S"))
        let helper = "S/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper.exe"
        tmp.file(helper, contents: Data(repeating: 1, count: 100))
        try ChromiumHelperWrapper.apply(helpers: AppPresets.steam.chromiumHelpers, in: s, wrapper: wrapper)
        let updated = Data(repeating: 2, count: 300)
        tmp.file(helper, contents: updated)                       // Steam updated itself
        try ChromiumHelperWrapper.apply(helpers: AppPresets.steam.chromiumHelpers, in: s, wrapper: wrapper)
        let real = s.driveC.appendingPathComponent("Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper_real.exe")
        #expect(FileManager.default.contents(atPath: real.path) == updated)
    }

    @Test func refusesAFileThatIsNotTheWrapper() {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("S"))
        #expect(throws: (any Error).self) {
            try ChromiumHelperWrapper.apply(helpers: ["x.exe"], in: s, wrapper: Data("nope".utf8))
        }
    }

    @Test func theBundledWrapperIsTheRealOne() throws {
        let url = try #require(ChromiumHelperWrapper.wrapperURL)
        #expect(ChromiumHelperWrapper.isWrapper(try Data(contentsOf: url)))
    }
}
