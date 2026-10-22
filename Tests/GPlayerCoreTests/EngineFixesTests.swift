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

    @Test func theBundledWow64cpuMatchesItsPin() throws {
        let url = try #require(CoreResources.url(EngineFixes.wow64cpu.resource))
        #expect(try Files.sha256(of: url) == EngineFixes.wow64cpu.fixedSHA256)
    }
}
