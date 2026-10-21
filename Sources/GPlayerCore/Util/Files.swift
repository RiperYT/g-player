import CryptoKit
import Foundation

public enum Files {
    /// SHA-256 of a file, read in 4 MB chunks.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Total size of a folder in bytes, following no symlinks.
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                          options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    public static func size(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    /// A folder name that is safe on macOS and inside Wine (no slashes, colons or reserved characters).
    public static func safeName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))
    }

    /// `base`, or `base 2`, `base 3`… so nothing existing is overwritten.
    public static func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(n)"); n += 1
        }
        return candidate
    }

    /// Removes Gatekeeper's quarantine flag from downloaded engine files.
    public static func clearQuarantine(_ url: URL) async {
        _ = try? await Shell.run(Shell.tool("xattr"), ["-dr", "com.apple.quarantine", url.path])
    }

    /// Path of `url` relative to `base`, or nil when it is not inside it.
    public static func relativePath(of url: URL, to base: URL) -> String? {
        let path = url.standardizedFileURL.path, root = base.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
