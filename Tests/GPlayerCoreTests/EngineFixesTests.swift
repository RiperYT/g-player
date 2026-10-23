import Foundation
import Testing
@testable import GPlayerCore

@Suite struct EngineFixesTests {
    private func fix(original: Data, fixed: Data) -> EngineFixes.FileFix {
        EngineFixes.FileFix(engineID: "e", path: "lib/x.dll", originalSHA256: sha(original), fixedSHA256: sha(fixed), resource: "fixed.dll")
    }
    private func sha(_ data: Data) -> String {
        let tmp = TempFolder()
        return try! Files.sha256(of: tmp.file("d", contents: data))
    }

    @Test func theKnownOriginalIsReplacedAndKept() throws {
        let tmp = TempFolder()
        let original = Data("gcenx".utf8), fixed = Data("fixed".utf8)
        let root = tmp.url.appendingPathComponent("wine")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try original.write(to: root.appendingPathComponent("lib/x.dll"))
        let source = tmp.file("fixed.dll", contents: fixed)
        let f = fix(original: original, fixed: fixed)

        #expect(EngineFixes.apply(f, wineRoot: root, resources: { _ in source }) == .applied)
        #expect(try Data(contentsOf: root.appendingPathComponent("lib/x.dll")) == fixed)
        #expect(try Data(contentsOf: root.appendingPathComponent("lib/x.dll.gcenx")) == original)
        #expect(EngineFixes.apply(f, wineRoot: root, resources: { _ in source }) == .alreadyApplied)
    }

    /// The fixed wineserver loads libinotify: an engine without it keeps its own wineserver, and the fixed one stays
    /// executable.
    @Test func aFixThatNeedsAnotherFileWaitsForItAndKeepsTheFileExecutable() throws {
        let tmp = TempFolder()
        let original = Data("server".utf8), fixed = Data("server+inotify".utf8)
        let root = tmp.url.appendingPathComponent("wine")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let target = root.appendingPathComponent("lib/x.dll")
        try original.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let source = tmp.file("fixed.dll", contents: fixed)
        var f = fix(original: original, fixed: fixed)
        f.requires = ["lib/libinotify.0.dylib"]

        #expect(EngineFixes.apply(f, wineRoot: root, resources: { _ in source }) == .unavailable)
        #expect(try Data(contentsOf: target) == original)
        try Data("lib".utf8).write(to: root.appendingPathComponent("lib/libinotify.0.dylib"))
        #expect(EngineFixes.apply(f, wineRoot: root, resources: { _ in source }) == .applied)
        #expect(try Data(contentsOf: target) == fixed)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    @Test func anOlderFixIsReplacedAndTheOriginalStaysTheBackup() throws {
        let tmp = TempFolder()
        let original = Data("gcenx".utf8), older = Data("fixed v1".utf8), fixed = Data("fixed v2".utf8)
        let root = tmp.url.appendingPathComponent("wine")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try older.write(to: root.appendingPathComponent("lib/x.dll"))
        try original.write(to: root.appendingPathComponent("lib/x.dll.gcenx"))
        let source = tmp.file("fixed.dll", contents: fixed)
        var f = fix(original: original, fixed: fixed)
        #expect(EngineFixes.apply(f, wineRoot: root, resources: { _ in source }) == .unknownOriginal)
        f.replaces = [sha(older)]
        #expect(EngineFixes.apply(f, wineRoot: root, resources: { _ in source }) == .applied)
        #expect(try Data(contentsOf: root.appendingPathComponent("lib/x.dll")) == fixed)
        #expect(try Data(contentsOf: root.appendingPathComponent("lib/x.dll.gcenx")) == original)
    }

    @Test func anOlderFixWithoutTheOriginalBackupIsLeftAlone() throws {
        let tmp = TempFolder()
        let older = Data("fixed v1".utf8)
        let root = tmp.url.appendingPathComponent("wine")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try older.write(to: root.appendingPathComponent("lib/x.dll"))
        let source = tmp.file("fixed.dll", contents: Data("fixed v2".utf8))
        var f = fix(original: Data("gcenx".utf8), fixed: Data("fixed v2".utf8))
        f.replaces = [sha(older)]
        #expect(EngineFixes.apply(f, wineRoot: root, resources: { _ in source }) == .unknownOriginal)
        #expect(try Data(contentsOf: root.appendingPathComponent("lib/x.dll")) == older)
    }

    @Test func theSameCodeSignedDifferentlyCountsAsApplied() throws {
        let tmp = TempFolder()
        let unsigned = Data("fixed, unsigned".utf8)
        let root = tmp.url.appendingPathComponent("wine")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try unsigned.write(to: root.appendingPathComponent("lib/x.dll"))
        var f = fix(original: Data("gcenx".utf8), fixed: Data("fixed, signed".utf8))
        f.alsoFixed = [sha(unsigned)]
        #expect(EngineFixes.apply(f, wineRoot: root, resources: { _ in nil }) == .alreadyApplied)
    }

    @Test func anUnknownFileIsLeftAlone() throws {
        let tmp = TempFolder()
        let root = tmp.url.appendingPathComponent("wine")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data("another build".utf8).write(to: root.appendingPathComponent("lib/x.dll"))
        let source = tmp.file("fixed.dll", contents: Data("fixed".utf8))
        let f = fix(original: Data("gcenx".utf8), fixed: Data("fixed".utf8))
        #expect(EngineFixes.apply(f, wineRoot: root, resources: { _ in source }) == .unknownOriginal)
        #expect(try Data(contentsOf: root.appendingPathComponent("lib/x.dll")) == Data("another build".utf8))
    }

    @Test func aDamagedFixedCopyIsNotUsed() throws {
        let tmp = TempFolder()
        let original = Data("gcenx".utf8)
        let root = tmp.url.appendingPathComponent("wine")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try original.write(to: root.appendingPathComponent("lib/x.dll"))
        let source = tmp.file("fixed.dll", contents: Data("tampered".utf8))
        let f = fix(original: original, fixed: Data("fixed".utf8))
        #expect(EngineFixes.apply(f, wineRoot: root, resources: { _ in source }) == .unavailable)
        #expect(try Data(contentsOf: root.appendingPathComponent("lib/x.dll")) == original)
    }

    @Test func aBackupCutShortIsMadeAgain() throws {
        let tmp = TempFolder()
        let original = Data("gcenx original".utf8), fixed = Data("fixed".utf8)
        let root = tmp.url.appendingPathComponent("wine")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try original.write(to: root.appendingPathComponent("lib/x.dll"))
        try Data("gcenx".utf8).write(to: root.appendingPathComponent("lib/x.dll.gcenx"))     // an earlier copy that stopped
        let source = tmp.file("fixed.dll", contents: fixed)

        #expect(EngineFixes.apply(fix(original: original, fixed: fixed), wineRoot: root, resources: { _ in source }) == .applied)
        #expect(try Data(contentsOf: root.appendingPathComponent("lib/x.dll.gcenx")) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/x.dll.gplayer-new").path))
    }

    @Test func revisionTwoHasTheWineFixesBuiltInSoOnlyRevisionOneGetsThem() {
        func fixes(for engine: EngineInfo) -> [String] { EngineFixes.all.filter { $0.engineID == engine.id }.map(\.path) }
        // The ntdll and CoreAudio patches are built into G-Player Wine 26.3.0-2: their fixed files are for -1 only.
        #expect(fixes(for: EngineCatalog.crossoverRevision1).sorted() == [
            "lib/wine/i386-windows/ntdll.dll", "lib/wine/x86_64-unix/ntdll.so", "lib/wine/x86_64-unix/winecoreaudio.so",
            "lib/wine/x86_64-windows/ntdll.dll"])
        // Revision 2 gets only its wineserver with file change notifications.
        #expect(fixes(for: EngineCatalog.crossover) == ["bin/wineserver"])
        #expect(EngineFixes.ntdllNoExec.allSatisfy { $0.engineID == "wine-cx-26.3.0-1" } && EngineFixes.coreAudioVolume.engineID == "wine-cx-26.3.0-1")
        // Wine Staging keeps its two.
        #expect(fixes(for: EngineCatalog.wineStaging).sorted() == ["lib/libMoltenVK.dylib", "lib/wine/x86_64-windows/wow64cpu.dll"])
        #expect(fixes(for: EngineCatalog.gptk).isEmpty)
        // Every fix belongs to an engine G-Player knows, retired ones included.
        #expect(EngineFixes.all.allSatisfy { EngineCatalog.info($0.engineID) != nil })
    }

    @Test(arguments: EngineFixes.all.map(\.resource))
    func theBundledFilesMatchTheirPins(resource: String) throws {
        let fix = try #require(EngineFixes.all.first { $0.resource == resource })
        let url = try #require(CoreResources.url(fix.resource))
        #expect(try Files.sha256(of: url) == fix.fixedSHA256)
    }

    @Test func theFixedFileLosesTheAppsQuarantineMark() throws {
        // A file copied out of a downloaded app keeps its quarantine mark, and dyld won't load a marked MoltenVK.
        let tmp = TempFolder()
        let original = Data("gcenx".utf8), fixed = Data("fixed".utf8)
        let root = tmp.url.appendingPathComponent("wine")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try original.write(to: root.appendingPathComponent("lib/x.dll"))
        let source = tmp.file("fixed.dll", contents: fixed)
        let mark = "0081;00000000;Safari;"
        #expect(setxattr(source.path, "com.apple.quarantine", mark, mark.utf8.count, 0, 0) == 0)

        #expect(EngineFixes.apply(fix(original: original, fixed: fixed), wineRoot: root, resources: { _ in source }) == .applied)
        #expect(getxattr(root.appendingPathComponent("lib/x.dll").path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
    }
}
