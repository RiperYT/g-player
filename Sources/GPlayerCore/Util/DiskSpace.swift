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
    /// `english`: the text for a log, in English whatever the app's language.
    public static func problem(needing needed: Int64, available: Int64?, for what: LocalizedStringResource,
                               english: Bool = false) -> String? {
        guard let available, needed > 0, available < needed else { return nil }
        var phrase = what, message: LocalizedStringResource
        if english {
            phrase.locale = Locale(identifier: "en")
            message = LocalizedStringResource("\(String(localized: phrase)) needs about \(needed.englishBytes) free, and this disk has \(available.englishBytes). Free some space, then try again.",
                                              comment: "What is about to be done, as a phrase (“Installing G-Player Wine”, “Adding “Game””), comes first")
            message.locale = Locale(identifier: "en")
        } else {
            message = LocalizedStringResource("\(String(localized: phrase)) needs about \(needed.formattedBytes) free, and this disk has \(available.formattedBytes). Free some space, then try again.",
                                              comment: "What is about to be done, as a phrase (“Installing G-Player Wine”, “Adding “Game””), comes first")
        }
        return String(localized: message)
    }

    /// An error for a message from `problem`, with its English for a log.
    public static func error(needing needed: Int64, available: Int64?, for what: LocalizedStringResource) -> ShellError? {
        guard let text = problem(needing: needed, available: available, for: what),
              let english = problem(needing: needed, available: available, for: what, english: true) else { return nil }
        return .translated(text, english: english)
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
