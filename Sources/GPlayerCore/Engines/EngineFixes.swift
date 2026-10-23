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
        /// Earlier versions of the fixed file that count as applied (the same code before it was signed with
        /// G-Player's Developer ID): an engine that has one is left as it is.
        public var alsoFixed: [String] = []
        /// Earlier fixed files this one replaces (an older version of the same fix). The engine's original stays the
        /// backup, so the file can still go back to it.
        public var replaces: [String] = []
        /// Files the fixed one needs in the engine (relative to the wine root), such as a library it loads: without them
        /// the engine's own file stays.
        public var requires: [String] = []
    }

    /// wow64cpu with the Rosetta 2 far-jump workaround: 32-bit programs stop crashing at random (WineHQ 60494).
    public static let wow64cpu = FileFix(
        engineID: EngineCatalog.wineStaging.id,
        path: "lib/wine/x86_64-windows/wow64cpu.dll",
        originalSHA256: "fcf772d27ed5f49d075e6e263aec855a358715f4e6f646895e58bc6fbed79709",
        fixedSHA256: "3b3137fc3bd3e136f2d6139ee721d863ed33d5287f242272306a7e4aa6fecec1",
        resource: "engine-fixes/wow64cpu.dll")

    /// MoltenVK 1.4.2 from the Khronos release, its code unchanged and signed with G-Player's Developer ID for notarization
    /// (scripts/fetch-moltenvk.sh). The engine's 1.4.0 refuses the
    /// host-memory buffers Wine makes so that 32-bit programs can reach Vulkan memory, so 32-bit DirectX 10/11 games
    /// couldn't start through DXVK.
    public static let moltenVK = FileFix(
        engineID: EngineCatalog.wineStaging.id,
        path: "lib/libMoltenVK.dylib",
        originalSHA256: "aac02fea75b00aa23fca5af9c19fc0d4b2e0f12dc0f78b3bee57b7b67fa5b61b",
        fixedSHA256: "d19a384ea38ab9fff1e64ee51967ff4401682476f91882804e2e81f3f11f68a7",
        resource: "engine-fixes/libMoltenVK.dylib",
        alsoFixed: ["aef00b13bcc808adf15b85bef9ae67393d92be7ed5dfe41cad16fa809e4a4c5f"])

    /// G-Player Wine 26.3.0-1's ntdll with tools/wine-patches/cx-nx-compat.patch; revision 2 is built with it. Wine made
    /// every readable page executable for a whole 32-bit process as soon as any DLL in it lacked the NX flag (old
    /// Microsoft DLLs such as xinput1_3 or d3dx9_30 don't have it), and Metal on macOS 26 then fails every frame with
    /// "Insufficient Memory": DXVK and DXMT both showed a black window. The patched ntdll decides from the program alone,
    /// as Windows does, and keeps no-execute on under Rosetta. Three files, built from the same source as the engine
    /// (scripts/build-engine-cx.sh).
    public static let ntdllNoExec = [
        FileFix(engineID: EngineCatalog.crossoverRevision1.id, path: "lib/wine/x86_64-unix/ntdll.so",
                originalSHA256: "ff9596b1a376f634b04be5ee9aa2b74520f8742a9534fee8228ffdd5ddcab50b",
                fixedSHA256: "b502e8d6a37a568965e2d13dd7028fb17167f7c6db9298d7e3c917e487a0743f",
                resource: "engine-fixes/cx-ntdll.so",
                alsoFixed: ["e007f39cb2145966eb895002587c8732fb7be6ea90411d2b497edfeab7b36673"]),
        FileFix(engineID: EngineCatalog.crossoverRevision1.id, path: "lib/wine/x86_64-windows/ntdll.dll",
                originalSHA256: "2d2b919c595771278823051ab6d8aaccc27381e93570bdaaf432241a8daaf072",
                fixedSHA256: "f2a0de442f64d5c2ff188ce82a3f1d683d7f5a454b43958d5429200a7071cb7f",
                resource: "engine-fixes/cx-ntdll-x86_64.dll"),
        FileFix(engineID: EngineCatalog.crossoverRevision1.id, path: "lib/wine/i386-windows/ntdll.dll",
                originalSHA256: "100234e83cca543a356d148c84303c0bb430b9218b352185e9b209c5c9ecaa2d",
                fixedSHA256: "c740fc89435451fed7d53a45a4769b56bada96189ea04d253125a057ec730aed",
                resource: "engine-fixes/cx-ntdll-i386.dll"),
    ]

    /// G-Player Wine 26.3.0-1's CoreAudio driver with tools/wine-patches/cx-coreaudio-stream-volume.patch; revision 2 is
    /// built with it. Wine wrote a game's own volume into the Mac's output device: on AirPods and the MacBook speakers
    /// that failed, so a game's volume setting did nothing, and on outputs where it worked it changed the Mac's volume.
    /// The patched driver scales the game's samples instead, as Wine's ALSA driver does, and leaves the Mac's volume to
    /// the user.
    public static let coreAudioVolume = FileFix(
        engineID: EngineCatalog.crossoverRevision1.id,
        path: "lib/wine/x86_64-unix/winecoreaudio.so",
        originalSHA256: "b2e5cd42b7b1300f01818212a4f16a5ec94118a7ddd5352a01efe729a1548132",
        fixedSHA256: "1c08e468be49c6019d270fd25887b1474ed8272e9052352bf13946786905cdba",
        resource: "engine-fixes/cx-winecoreaudio.so",
        // The first version wrapped 32-bit peaks around and didn't apply a program's capture volume.
        replaces: ["728e0db3d81eb021b76d60c052ee727d018d2c97b403b511111805f612850d6b"])

    /// G-Player Wine 26.3.0-2's wineserver built with libinotify (the same source and configuration, `--with-inotify`), so
    /// file change notifications work (ReadDirectoryChangesW): Epic's launcher waits for one before it installs a game, and
    /// never got it. It loads Gcenx's libinotify, which every install of the engine has among its runtime libraries.
    public static let wineserverNotifications = FileFix(
        engineID: EngineCatalog.crossover.id,
        path: "bin/wineserver",
        originalSHA256: "4b804a715b3083e9c9b11547a5aafcdf83dc6063ca57d8194cfe5cecbd517d33",
        fixedSHA256: "4036ee29fb73b92943d43067e6ca5336f4b0b6dd136c26576e7f3e85933c442a",
        resource: "engine-fixes/cx2-wineserver",
        requires: ["lib/libinotify.0.dylib"])

    public static let all = [wow64cpu, moltenVK] + ntdllNoExec + [coreAudioVolume, wineserverNotifications]

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
        if current == fix.fixedSHA256 || fix.alsoFixed.contains(current) { return .alreadyApplied }
        let upgrade = fix.replaces.contains(current)
        guard current == fix.originalSHA256 || upgrade else { return .unknownOriginal }
        guard let source = resources(fix.resource), (try? Files.sha256(of: source)) == fix.fixedSHA256,
              fix.requires.allSatisfy({ fm.fileExists(atPath: wineRoot.appendingPathComponent($0).path) }) else { return .unavailable }
        let backup = target.appendingPathExtension("gcenx")
        let staged = target.appendingPathExtension("gplayer-new")
        do {
            // The original is kept whole: a backup cut short by an earlier attempt is made again. An older fix in
            // place means the backup is already the original, and only then may it be replaced.
            if upgrade, (try? Files.sha256(of: backup)) != fix.originalSHA256 { return .unknownOriginal }
            if !upgrade, (try? Files.sha256(of: backup)) != fix.originalSHA256 {
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
            // As the engine's file was: a program (wineserver) stays executable.
            if let mode = try fm.attributesOfItem(atPath: target.path)[.posixPermissions] {
                try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path)
            }
            // A rename, so programs that have the old file open keep it and new ones get the fixed one.
            _ = try fm.replaceItemAt(target, withItemAt: staged)
            return .applied
        } catch {
            try? fm.removeItem(at: staged)
            return .unavailable
        }
    }
}
