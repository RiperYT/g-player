import Foundation
import Security

/// Apple's D3DMetal (DirectX 11 and 12 on Metal), copied from the user's own Game Porting Toolkit into G-Player's
/// library and from there into G-Player Wine. Apple's license allows passing it on only for non-commercial purposes,
/// so G-Player never ships or downloads it: it takes it, byte for byte and only when Apple's signature checks out,
/// from a toolkit the user installed or downloaded themselves, after they turned Apple's toolkit on in Settings.
///
/// Adapted from MaPC's MacadeKit `D3DMetalStore` (Copyright 2026 Steale LLC, Apache-2.0).
public struct D3DMetalStore: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case notFound, notSignedByApple(String), missingModule(String), couldNotOpen, copyFailed(String)
        public var errorDescription: String? {
            switch self {
            case .notFound: String(localized: "That doesn't contain D3DMetal. Choose Apple's Game Porting Toolkit download or the toolkit you installed.")
            case .notSignedByApple(let item): String(localized: "\(item) isn't signed by Apple, so G-Player won't use it.")
            case .missingModule(let name): String(localized: "This Game Porting Toolkit is missing \(name).")
            case .couldNotOpen: String(localized: "Couldn't open the disk image, most likely because Apple's license has to be accepted first. Open it in Finder, agree to the license, then choose it again (or the opened disk).")
            case .copyFailed(let message): String(localized: "Couldn't copy D3DMetal. \(message)")
            }
        }
    }

    public struct Info: Codable, Sendable, Equatable {
        public var version: String
        public var source: String
        public var importedAt: Date
    }

    /// Windows modules that come with D3DMetal. Direct3D 9 and the rest stay Wine's.
    static let modules = ["d3d10", "d3d11", "d3d12", "dxgi", "atidxx64", "nvapi64", "nvngx", "nvngx-on-metalfx"]
    static let requiredModules = ["d3d11", "d3d12", "dxgi"]
    /// In an engine's `lib/external`: the version linked there.
    static let marker = ".gplayer-d3dmetal"

    /// The toolkit Gcenx's Homebrew cask installs, which carries Apple's D3DMetal.
    public static let installedToolkit = URL(fileURLWithPath: "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/lib")

    public let paths: LibraryPaths
    public init(paths: LibraryPaths) { self.paths = paths }

    var root: URL { paths.d3dMetal }
    var infoFile: URL { root.appendingPathComponent("D3DMETAL.json") }

    /// The imported D3DMetal, if any.
    public var installed: Info? {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("external/libd3dshared.dylib").path),
              let data = try? Data(contentsOf: infoFile) else { return nil }
        return try? JSONDecoder.iso.decode(Info.self, from: data)
    }

    // MARK: Import

    /// Copies D3DMetal out of `source`: the installed toolkit's `lib` folder, Apple's `.dmg` (and the evaluation
    /// image inside it), an opened toolkit disk, or a folder in one. Replaces an earlier import only once the new
    /// copy is complete and checked.
    @discardableResult
    public func importD3DMetal(from source: URL) async throws -> Info {
        let fm = FileManager.default
        try paths.createFolders()
        let staging = paths.root.appendingPathComponent(".d3dmetal-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let info: Info
        if source.pathExtension.lowercased() == "dmg" {
            info = try await copy(fromImage: source, to: staging, nested: 1)
        } else {
            let label = source.standardizedFileURL == Self.installedToolkit.standardizedFileURL ? "Game Porting Toolkit" : source.lastPathComponent
            do { info = try copy(from: source, to: staging, label: label) }
            catch Failure.notFound {
                guard let inner = Self.nestedImage(in: source) else { throw Failure.notFound }
                info = try await copy(fromImage: inner, to: staging, nested: 0)
            }
        }
        let old = paths.root.appendingPathComponent(".d3dmetal-old-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: root.path) { try fm.moveItem(at: root, to: old) }
        do { try fm.moveItem(at: staging, to: root) }
        catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: root) }
            throw Failure.copyFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: old)
        return info
    }

    private func copy(fromImage image: URL, to staging: URL, nested: Int) async throws -> Info {
        // An image the user already opened in Finder (where Apple's license is accepted) is used where it is mounted.
        if let mounted = await Self.mountPoint(of: image) {
            do { return try copy(from: mounted, to: staging, label: image.lastPathComponent) }
            catch Failure.notFound where nested > 0 {
                guard let inner = Self.nestedImage(in: mounted) else { throw Failure.notFound }
                return try await copy(fromImage: inner, to: staging, nested: nested - 1)
            }
        }
        let mount = try await Self.attach(image)
        let result: Result<Info, Error>
        do { result = .success(try copy(from: mount, to: staging, label: image.lastPathComponent)) }
        catch Failure.notFound where nested > 0 {
            // Since Game Porting Toolkit 3.0, Apple's download holds another image ("Evaluation environment for
            // Windows games"), which is where D3DMetal is.
            if let inner = Self.nestedImage(in: mount) {
                do { result = .success(try await copy(fromImage: inner, to: staging, nested: nested - 1)) }
                catch { result = .failure(error) }
            } else {
                result = .failure(Failure.notFound)
            }
        } catch {
            result = .failure(error)
        }
        await Self.detach(mount)                 // the inner image, if any, is already detached
        return try result.get()
    }

    private func copy(from source: URL, to staging: URL, label: String) throws -> Info {
        let fm = FileManager.default
        guard let lib = Self.locate(in: source) else { throw Failure.notFound }
        let windows = lib.appendingPathComponent("wine/x86_64-windows")
        for module in Self.requiredModules where !fm.fileExists(atPath: windows.appendingPathComponent("\(module).dll").path) {
            throw Failure.missingModule("\(module).dll")
        }
        do {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging.appendingPathComponent("x86_64-windows"), withIntermediateDirectories: true)
            try fm.copyItem(at: lib.appendingPathComponent("external"), to: staging.appendingPathComponent("external"))
            for module in Self.modules {
                let dll = windows.appendingPathComponent("\(module).dll")
                if fm.fileExists(atPath: dll.path) {
                    try fm.copyItem(at: dll, to: staging.appendingPathComponent("x86_64-windows/\(module).dll"))
                }
            }
        } catch {
            throw Failure.copyFailed(error.localizedDescription)
        }
        // The copies are checked, not the source: these are the bytes that will run.
        let framework = staging.appendingPathComponent("external/D3DMetal.framework")
        for item in [framework, staging.appendingPathComponent("external/libd3dshared.dylib")] where !Self.isSignedByApple(item) {
            throw Failure.notSignedByApple(item.lastPathComponent)
        }
        // Copies from a downloaded image carry its quarantine mark; Apple's signature, checked above, replaces it.
        if let walker = fm.enumerator(at: staging, includingPropertiesForKeys: nil) {
            for case let item as URL in walker { removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW) }
        }
        let license = framework.appendingPathComponent("Versions/A/Resources/LICENSE")
        if fm.fileExists(atPath: license.path) { try? fm.copyItem(at: license, to: staging.appendingPathComponent("LICENSE.txt")) }
        let bundle = Bundle(url: framework)
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let info = Info(version: version, source: label, importedAt: Date())
        do { try JSONEncoder.iso.encode(info).write(to: staging.appendingPathComponent("D3DMETAL.json")) }
        catch { throw Failure.copyFailed(error.localizedDescription) }
        return info
    }

    // MARK: Engines

    /// What `link` put into an engine, in `lib/external/.gplayer-d3dmetal`: the import it came from and the modules it
    /// replaced, so `unlink` knows them even if a later toolkit stops marking its DLLs.
    struct Linked: Codable, Equatable {
        var version: String
        var importedAt: Date
        var modules: [String]
    }

    /// The D3DMetal version linked into `engine`, once `link` finished.
    public static func linkedVersion(in engine: Engine) -> String? {
        linked(in: engine)?.version
    }

    static func linked(in engine: Engine) -> Linked? {
        let file = engine.externalLibraries.appendingPathComponent(marker)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder.iso.decode(Linked.self, from: data)
    }

    /// Puts the imported D3DMetal into a G-Player Wine engine, unless it already has this import: `lib/external`, and
    /// Apple's DLLs in place of Wine's builtins, each with its unix side pointing at `libd3dshared`. Wine's own copies
    /// are kept in `lib/wine-d3d` so `unlink` can put them back. The marker goes in last, so the engine only counts as
    /// having D3DMetal once everything is in place.
    public func link(into engine: Engine) throws {
        guard engine.info.kind == .crossover, let info = installed else { return }
        let fm = FileManager.default
        let lib = engine.wineRoot.appendingPathComponent("lib")
        let external = lib.appendingPathComponent("external")
        if let now = Self.linked(in: engine), now.version == info.version, now.importedAt == info.importedAt { return }
        do {
            try? fm.removeItem(at: external.appendingPathComponent(Self.marker))
            let fresh = lib.appendingPathComponent("external.gplayer-new")
            try? fm.removeItem(at: fresh)
            try fm.copyItem(at: root.appendingPathComponent("external"), to: fresh)
            try? fm.removeItem(at: external)
            try fm.moveItem(at: fresh, to: external)

            let windows = lib.appendingPathComponent("wine/x86_64-windows")
            let unix = lib.appendingPathComponent("wine/x86_64-unix")
            let stash = lib.appendingPathComponent("wine-d3d/x86_64-windows")
            try fm.createDirectory(at: stash, withIntermediateDirectories: true)
            try fm.createDirectory(at: unix, withIntermediateDirectories: true)
            var replaced: [String] = []
            for module in Self.modules {
                let dll = root.appendingPathComponent("x86_64-windows/\(module).dll")
                guard fm.fileExists(atPath: dll.path) else { continue }
                let target = windows.appendingPathComponent("\(module).dll")
                let kept = stash.appendingPathComponent("\(module).dll")
                if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: kept.path), !Self.isApples(target) {
                    try fm.copyItem(at: target, to: kept)
                }
                try? fm.removeItem(at: target)
                try fm.copyItem(at: dll, to: target)
                // D3DMetal's DLLs call into Metal through libd3dshared, which Wine loads as each module's unix side.
                // A unix side of Wine's own (none of these modules has one today) is kept with the DLL.
                let so = unix.appendingPathComponent("\(module).so")
                if (try? fm.destinationOfSymbolicLink(atPath: so.path)) != nil { try fm.removeItem(at: so) }
                else if fm.fileExists(atPath: so.path) { try fm.moveItem(at: so, to: stash.appendingPathComponent("\(module).so")) }
                try fm.createSymbolicLink(atPath: so.path, withDestinationPath: "../../external/libd3dshared.dylib")
                replaced.append(module)
            }
            let record = Linked(version: info.version, importedAt: info.importedAt, modules: replaced)
            try JSONEncoder.iso.encode(record).write(to: external.appendingPathComponent(Self.marker), options: .atomic)
        } catch {
            throw Failure.copyFailed(error.localizedDescription)
        }
    }

    /// Takes D3DMetal out of an engine again: Wine's own DLLs back from `lib/wine-d3d`, the links and `lib/external`
    /// removed. For when the user turns Apple's toolkit off; also cleans up after a `link` that stopped halfway.
    public func unlink(from engine: Engine) throws {
        guard engine.info.kind == .crossover else { return }
        let fm = FileManager.default
        let lib = engine.wineRoot.appendingPathComponent("lib")
        let external = lib.appendingPathComponent("external")
        let windows = lib.appendingPathComponent("wine/x86_64-windows")
        let unix = lib.appendingPathComponent("wine/x86_64-unix")
        let stash = lib.appendingPathComponent("wine-d3d/x86_64-windows")
        let listed = Set(Self.linked(in: engine)?.modules ?? [])
        guard fm.fileExists(atPath: external.path) || !listed.isEmpty
                || Self.modules.contains(where: { Self.isApples(windows.appendingPathComponent("\($0).dll")) }) else { return }
        for module in Self.modules {
            let target = windows.appendingPathComponent("\(module).dll")
            let kept = stash.appendingPathComponent("\(module).dll")
            if fm.fileExists(atPath: kept.path), listed.contains(module) || Self.isApples(target) {
                try? fm.removeItem(at: target)
                try fm.copyItem(at: kept, to: target)
            } else if Self.isApples(target) {
                try fm.removeItem(at: target)                     // Wine has no builtin of this one (nvapi64, nvngx…)
            }
            let so = unix.appendingPathComponent("\(module).so")
            if (try? fm.destinationOfSymbolicLink(atPath: so.path)) != nil { try fm.removeItem(at: so) }
            let keptSo = stash.appendingPathComponent("\(module).so")
            if fm.fileExists(atPath: keptSo.path), !fm.fileExists(atPath: so.path) { try fm.copyItem(at: keptSo, to: so) }
        }
        if fm.fileExists(atPath: external.path) { try fm.removeItem(at: external) }
    }

    /// Removes the copy in the library (after `unlink` took it out of the engines).
    public func removeImported() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    /// The installed toolkit's `lib` folder when it carries D3DMetal. Looks at two files only.
    public static var toolkitSource: URL? { isLib(installedToolkit) ? installedToolkit : nil }

    /// True for one of Apple's D3DMetal DLLs (they say so inside).
    static func isApples(_ dll: URL) -> Bool {
        (try? Data(contentsOf: dll, options: .mappedIfSafe))?.range(of: Data("D3DMetalDLLs".utf8)) != nil
    }

    // MARK: Helpers

    /// The `lib` folder holding `external/libd3dshared.dylib` (Apple's image keeps it in `redist/lib`).
    static func isLib(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("external/libd3dshared.dylib").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("external/D3DMetal.framework").path)
    }

    static func locate(in source: URL) -> URL? {
        let fm = FileManager.default
        for candidate in [source, source.appendingPathComponent("lib")] where isLib(candidate) { return candidate }
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return nil }
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if item.lastPathComponent == "lib", isLib(item) { return item }
            if walker.level >= 6 || item.pathExtension == "framework" || item.pathExtension == "app" && walker.level > 1 {
                walker.skipDescendants()
            }
        }
        return nil
    }

    /// A disk image at the top of `folder`, Apple's evaluation environment first.
    static func nestedImage(in folder: URL) -> URL? {
        let images = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "dmg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return images.first { $0.lastPathComponent.localizedCaseInsensitiveContains("evaluation") } ?? images.first
    }

    /// True only for code Apple itself signed (not a third-party Developer ID), with every nested item intact.
    static func isSignedByApple(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }

    /// Where `image` is mounted already, if it is (`hdiutil info`).
    static func mountPoint(of image: URL) async -> URL? {
        guard let r = try? await Shell.run(Shell.tool("hdiutil"), ["info", "-plist"]), r.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        let wanted = image.resolvingSymlinksInPath().path
        for entry in images where (entry["image-path"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == wanted {
            let entities = entry["system-entities"] as? [[String: Any]] ?? []
            if let point = entities.compactMap({ $0["mount-point"] as? String }).first { return URL(fileURLWithPath: point) }
        }
        return nil
    }

    /// Mounts a disk image read-only and hidden from Finder.
    static func attach(_ image: URL) async throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("gplayer-gptk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let r = try await Shell.run(Shell.tool("hdiutil"),
                                    ["attach", image.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path])
        guard r.succeeded else { try? FileManager.default.removeItem(at: mount); throw Failure.couldNotOpen }
        return mount
    }

    static func detach(_ mount: URL) async {
        let hdiutil = Shell.tool("hdiutil")
        if (try? await Shell.run(hdiutil, ["detach", mount.path]))?.succeeded != true {
            _ = try? await Shell.run(hdiutil, ["detach", mount.path, "-force"])
        }
        try? FileManager.default.removeItem(at: mount)
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
