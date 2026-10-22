import Foundation

/// Checks made before work that fills a disk, so a full disk is a message at the start and not an error halfway.
public enum DiskSpace {
    /// `url`, or the nearest folder above it that exists: what a disk question is asked about when `url` is still to be made.
    private static func existing(_ url: URL) -> URL {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return probe
    }

    /// Bytes free for the user on the disk that holds `url`. Counts what macOS frees by itself when it needs room, as
    /// Finder does. Nil when it can't be told.
    public static func available(at url: URL) -> Int64? {
        (try? existing(url).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// Nil when `available` covers `needed` (or isn't known), else why not, for the user.
    public static func problem(needing needed: Int64, available: Int64?, for what: String) -> String? {
        guard let available, needed > 0, available < needed else { return nil }
        return "\(what) needs about \(needed.formattedBytes) free, and this disk has \(available.formattedBytes). "
            + "Free some space, then try again."
    }

    /// True when both places are on the same disk (a move there is a rename, and a copy can be a clone).
    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let x = try? existing(a).resourceValues(forKeys: keys).volumeIdentifier as? NSObject,
              let y = try? existing(b).resourceValues(forKeys: keys).volumeIdentifier as? NSObject else { return false }
        return x.isEqual(y)
    }

    /// True when copies inside the disk that holds `url` are clones (APFS): they take no room until one of the two changes.
    public static func clonesCopies(on url: URL) -> Bool {
        (try? existing(url).resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning == true
    }
}
