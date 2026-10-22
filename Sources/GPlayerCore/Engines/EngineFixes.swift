import Foundation

/// Fixes G-Player puts into the Wine it downloads: files built from Wine's source (see tools/wine-patches), and
/// newer releases of the libraries Wine ships with.
public enum EngineFixes {
    /// One replaced file: where it goes in the engine, the exact file it replaces, and the fixed one.
    public struct FileFix: Sendable {
        public let engineID: String
        /// Relative to the engine's wine root (`…/Contents/Resources/wine`).
        public let path: String
        /// SHA-256 of the file the engine ships. Anything else is left alone: G-Player only replaces what it knows.
        public let originalSHA256: String
        public let fixedSHA256: String
        /// The fixed file inside GPlayerCore/Resources.
        public let resource: String
    }

    /// wow64cpu with the Rosetta 2 far-jump workaround: 32-bit programs stop crashing at random (WineHQ 60494).
    public static let wow64cpu = FileFix(
        engineID: EngineCatalog.wineStaging.id,
        path: "lib/wine/x86_64-windows/wow64cpu.dll",
        originalSHA256: "fcf772d27ed5f49d075e6e263aec855a358715f4e6f646895e58bc6fbed79709",
        fixedSHA256: "3b3137fc3bd3e136f2d6139ee721d863ed33d5287f242272306a7e4aa6fecec1",
        resource: "engine-fixes/wow64cpu.dll")

    /// MoltenVK 1.4.2 from the Khronos release, unchanged (scripts/fetch-moltenvk.sh). The engine's 1.4.0 refuses the
    /// host-memory buffers Wine makes so that 32-bit programs can reach Vulkan memory, so 32-bit DirectX 10/11 games
    /// couldn't start through DXVK.
    public static let moltenVK = FileFix(
        engineID: EngineCatalog.wineStaging.id,
        path: "lib/libMoltenVK.dylib",
        originalSHA256: "aac02fea75b00aa23fca5af9c19fc0d4b2e0f12dc0f78b3bee57b7b67fa5b61b",
        fixedSHA256: "aef00b13bcc808adf15b85bef9ae67393d92be7ed5dfe41cad16fa809e4a4c5f",
        resource: "engine-fixes/libMoltenVK.dylib")

    /// G-Player Wine's ntdll with tools/wine-patches/cx-nx-compat.patch. Wine made every readable page executable for
    /// a whole 32-bit process as soon as any DLL in it lacked the NX flag (old Microsoft DLLs such as xinput1_3 or
    /// d3dx9_30 don't have it), and Metal on macOS 26 then fails every frame with "Insufficient Memory": DXVK and DXMT
    /// both showed a black window. The patched ntdll decides from the program alone, as Windows does, and keeps
    /// no-execute on under Rosetta. Three files, built from the same source as the engine (scripts/build-engine-cx.sh).
    public static let ntdllNoExec = [
        FileFix(engineID: EngineCatalog.crossover.id, path: "lib/wine/x86_64-unix/ntdll.so",
                originalSHA256: "ff9596b1a376f634b04be5ee9aa2b74520f8742a9534fee8228ffdd5ddcab50b",
                fixedSHA256: "e007f39cb2145966eb895002587c8732fb7be6ea90411d2b497edfeab7b36673",
                resource: "engine-fixes/cx-ntdll.so"),
        FileFix(engineID: EngineCatalog.crossover.id, path: "lib/wine/x86_64-windows/ntdll.dll",
                originalSHA256: "2d2b919c595771278823051ab6d8aaccc27381e93570bdaaf432241a8daaf072",
                fixedSHA256: "f2a0de442f64d5c2ff188ce82a3f1d683d7f5a454b43958d5429200a7071cb7f",
                resource: "engine-fixes/cx-ntdll-x86_64.dll"),
        FileFix(engineID: EngineCatalog.crossover.id, path: "lib/wine/i386-windows/ntdll.dll",
                originalSHA256: "100234e83cca543a356d148c84303c0bb430b9218b352185e9b209c5c9ecaa2d",
                fixedSHA256: "c740fc89435451fed7d53a45a4769b56bada96189ea04d253125a057ec730aed",
                resource: "engine-fixes/cx-ntdll-i386.dll"),
    ]

    public static let all = [wow64cpu, moltenVK] + ntdllNoExec

    public enum Outcome: Equatable, Sendable {
        /// The fixed file was put in place; the original is kept next to it as `<name>.gcenx`.
        case applied
        case alreadyApplied
        /// The engine's file isn't the one the fix was made for (another Wine build): left as it is.
        case unknownOriginal
        /// The file isn't in the engine, or G-Player's fixed copy is missing or damaged.
        case unavailable
    }

    /// Applies every fix meant for the engine. Safe to call often: files already fixed are only checksummed.
    @discardableResult
    public static func apply(to engine: Engine, resources: (String) -> URL? = CoreResources.url) -> [Outcome] {
        all.filter { $0.engineID == engine.info.id }.map { apply($0, wineRoot: engine.wineRoot, resources: resources) }
    }

    /// One fix at a time: the app applies them after an engine install and at start, and both share the staging files.
    private static let lock = NSLock()

    static func apply(_ fix: FileFix, wineRoot: URL, resources: (String) -> URL?) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let target = wineRoot.appendingPathComponent(fix.path)
        guard let current = try? Files.sha256(of: target) else { return .unavailable }
        if current == fix.fixedSHA256 { return .alreadyApplied }
        guard current == fix.originalSHA256 else { return .unknownOriginal }
        guard let source = resources(fix.resource), (try? Files.sha256(of: source)) == fix.fixedSHA256 else { return .unavailable }
        let backup = target.appendingPathExtension("gcenx")
        let staged = target.appendingPathExtension("gplayer-new")
        do {
            // The original is kept whole: a backup cut short by an earlier attempt is made again.
            if (try? Files.sha256(of: backup)) != fix.originalSHA256 {
                try? fm.removeItem(at: staged)
                try fm.copyItem(at: target, to: staged)
                guard try Files.sha256(of: staged) == fix.originalSHA256 else { throw CocoaError(.fileWriteUnknown) }
                if fm.fileExists(atPath: backup.path) { _ = try fm.replaceItemAt(backup, withItemAt: staged) }
                else { try fm.moveItem(at: staged, to: backup) }
            }
            try? fm.removeItem(at: staged)
            try fm.copyItem(at: source, to: staged)
            // The copy carries the downloaded app's quarantine mark, and dyld won't load a marked library into Wine.
            // The file's checksum was checked against the pin above, and is checked again on the copy.
            if removexattr(staged.path, "com.apple.quarantine", 0) != 0 && errno != ENOATTR && errno != ENOTSUP {
                throw CocoaError(.fileWriteNoPermission)
            }
            guard try Files.sha256(of: staged) == fix.fixedSHA256 else { throw CocoaError(.fileWriteUnknown) }
            // A rename, so programs that have the old file open keep it and new ones get the fixed one.
            _ = try fm.replaceItemAt(target, withItemAt: staged)
            return .applied
        } catch {
            try? fm.removeItem(at: staged)
            return .unavailable
        }
    }
}
