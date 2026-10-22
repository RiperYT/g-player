import Foundation
@testable import GPlayerCore

/// A throwaway folder, removed when the test ends.
final class TempFolder {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("gplayer-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ path: String, bytes: Int = 16, contents: Data? = nil) -> URL {
        let f = url.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! (contents ?? Data(repeating: 0x41, count: bytes)).write(to: f)
        return f
    }

    @discardableResult
    func dir(_ path: String) -> URL {
        let d = url.appendingPathComponent(path, isDirectory: true)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A folder that passes `SpaceManager.isPrefix`.
    func prefix(_ path: String) -> URL {
        dir("\(path)/drive_c/windows/system32"); file("\(path)/system.reg")
        return url.appendingPathComponent(path)
    }
}

func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
}

func space(at url: URL, preset: String? = nil) -> Space {
    Space(name: url.lastPathComponent, path: url.path, engineID: EngineCatalog.wineStaging.id, origin: .managed, presetID: preset)
}

func fakeEngine(_ info: EngineInfo = EngineCatalog.wineStaging) -> Engine {
    let root = URL(fileURLWithPath: "/tmp/engine/wine")
    // DXVK counts as there, as in an installed Wine Staging.
    return Engine(info: info, wineRoot: root, wine: root.appendingPathComponent("bin/wine"),
                  dxvk: info.backends.contains(.dxvk) ? URL(fileURLWithPath: "/tmp/engine/dxvk") : nil)
}
