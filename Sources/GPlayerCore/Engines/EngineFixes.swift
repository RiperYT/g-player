import Foundation

/// Fixes G-Player puts into the Wine it downloads, built from Wine's source (see tools/wine-patches).
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

    public static let all = [wow64cpu]

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

    static func apply(_ fix: FileFix, wineRoot: URL, resources: (String) -> URL?) -> Outcome {
        let fm = FileManager.default
        let target = wineRoot.appendingPathComponent(fix.path)
        guard let current = try? Files.sha256(of: target) else { return .unavailable }
        if current == fix.fixedSHA256 { return .alreadyApplied }
        guard current == fix.originalSHA256 else { return .unknownOriginal }
        guard let source = resources(fix.resource), (try? Files.sha256(of: source)) == fix.fixedSHA256 else { return .unavailable }
        let backup = target.appendingPathExtension("gcenx")
        let staged = target.appendingPathExtension("gplayer-new")
        do {
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: target, to: backup) }
            try? fm.removeItem(at: staged)
            try fm.copyItem(at: source, to: staged)
            // A rename, so programs that have the old file open keep it and new ones get the fixed one.
            _ = try fm.replaceItemAt(target, withItemAt: staged)
            return .applied
        } catch {
            try? fm.removeItem(at: staged)
            return .unavailable
        }
    }
}
