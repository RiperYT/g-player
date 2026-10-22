import Foundation

/// Unpacks game archives with macOS's own `bsdtar` (libarchive): zip, rar (including RAR5), 7z, tar, gz, xz, bz2.
public enum ArchiveExtractor {
    public static let extensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "xz", "txz", "bz2", "tbz", "tbz2"]

    public static func isArchive(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Extracts `archive` into a new folder inside `destinationParent` and returns the game folder.
    /// When the archive holds one top-level folder, that folder is the result.
    /// - Parameters:
    ///   - expectedBytes: what the archive holds unpacked (`uncompressedBytes`), 0 when not known.
    ///   - progress: bytes unpacked so far and `expectedBytes`, about once a second.
    ///
    /// Cancelling the calling task stops `bsdtar` and removes what it had unpacked; `CancellationError` is thrown.
    public static func extract(_ archive: URL, into destinationParent: URL, name: String, expectedBytes: Int64 = 0,
                               progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        let temp = destinationParent.appendingPathComponent(".extract-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let watcher = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { progress(Files.logicalSize(of: temp), expectedBytes) }
            }
        }
        defer { watcher.cancel() }
        let result: ProcessResult
        do { result = try await Shell.runStoppable(Shell.tool("bsdtar"), ["-xf", archive.path, "-C", temp.path]) }
        catch { try? fm.removeItem(at: temp); throw error }
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

    /// What `archive` holds once unpacked, from its listing; nil when that can't be told. Only zip, rar and 7z are listed:
    /// they keep their file list apart, while a .tar.gz would be read through in full, as long as unpacking it takes.
    public static func uncompressedBytes(of archive: URL) async -> Int64? {
        guard ["zip", "rar", "7z"].contains(archive.pathExtension.lowercased()),
              let listing = try? await Shell.runStoppable(Shell.tool("bsdtar"), ["-tvf", archive.path]), listing.succeeded else { return nil }
        let total = uncompressedBytes(fromListing: listing.stdout)
        return total > 0 ? total : nil
    }

    /// The sizes in `bsdtar -tv` output, added up: "-rw-r--r--  0 user group  12345 Oct 23 12:00 dir/file.exe".
    static func uncompressedBytes(fromListing listing: String) -> Int64 {
        var total: Int64 = 0
        for line in listing.split(separator: "\n") where line.hasPrefix("-") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 9, let size = Int64(fields[4]) { total += size }
        }
        return total
    }
}
