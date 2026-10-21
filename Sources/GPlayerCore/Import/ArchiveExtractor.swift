import Foundation

/// Unpacks game archives with macOS's own `bsdtar` (libarchive): zip, rar (including RAR5), 7z, tar, gz, xz, bz2.
public enum ArchiveExtractor {
    public static let extensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "xz", "txz", "bz2", "tbz", "tbz2"]

    public static func isArchive(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Extracts `archive` into a new folder inside `destinationParent` and returns the game folder.
    /// When the archive holds one top-level folder, that folder is the result.
    public static func extract(_ archive: URL, into destinationParent: URL, name: String) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        let temp = destinationParent.appendingPathComponent(".extract-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let result = try await Shell.run(Shell.tool("bsdtar"), ["-xf", archive.path, "-C", temp.path])
        guard result.succeeded else {
            try? fm.removeItem(at: temp)
            let reason = result.stderr.split(separator: "\n").first.map(String.init) ?? "unknown error"
            throw ShellError.failed("Couldn't unpack \(archive.lastPathComponent): \(reason)")
        }
        let visible = ((try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        let content: URL = (visible.count == 1 && Files.isDirectory(visible[0])) ? visible[0] : temp
        let target = Files.uniqueURL(in: destinationParent, name: Files.safeName(name))
        try fm.moveItem(at: content, to: target)
        try? fm.removeItem(at: temp)
        return target
    }
}
