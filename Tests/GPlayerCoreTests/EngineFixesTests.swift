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
