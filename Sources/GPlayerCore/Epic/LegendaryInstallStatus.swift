import Foundation

/// How far a Legendary install is, read from its log (stderr), line by line. Once a second, while it downloads, it writes
///
///     [DLManager] INFO: = Progress: 12.34% (123/1000), Running for 00:00:12, ETA: 00:01:23
///     [DLManager] INFO:  - Downloaded: 123.45 MiB, Written: 120.00 MiB
///
/// and before that, once, how big the game is (`installSize(in:)`).
public struct LegendaryInstallStatus: Equatable, Sendable {
    /// 0…1 once a progress line has come.
    public private(set) var fraction: Double?
    public private(set) var downloadedBytes: Int64?
    /// Seconds Legendary expects it still takes.
    public private(set) var remaining: TimeInterval?

    public init() {}

    /// Takes in one line of the log. True when something it shows changed.
    @discardableResult
    public mutating func take(_ line: String) -> Bool {
        let before = self
        if let progress = Self.progress(in: line) {
            fraction = progress.fraction
            remaining = progress.remaining
        } else if let bytes = Self.downloaded(in: line) {
            downloadedBytes = bytes
        }
        return self != before
    }

    /// What the sidebar says: "Preparing" until the download starts, then "12% · 123 MB · about 2 min left".
    public var message: String {
        guard let fraction else { return "Preparing" }
        var parts = ["\(Int((fraction * 100).rounded(.down)))%"]
        if let downloadedBytes, downloadedBytes > 0 { parts.append(downloadedBytes.formattedBytes) }
        if let remaining { parts.append(Self.duration(remaining) + " left") }
        return parts.joined(separator: " · ")
    }

    // MARK: Lines

    /// `= Progress: 12.34% (123/1000), Running for 00:00:12, ETA: 00:01:23`.
    static func progress(in line: String) -> (fraction: Double, remaining: TimeInterval?)? {
        guard let marker = line.range(of: "= Progress: ") else { return nil }
        let rest = line[marker.upperBound...]
        guard let percent = rest.firstIndex(of: "%"), let value = Double(rest[..<percent]), value >= 0 else { return nil }
        var remaining: TimeInterval?
        if let eta = rest.range(of: "ETA: ") { remaining = seconds(fromClock: rest[eta.upperBound...]) }
        return (min(value, 100) / 100, remaining)
    }

    /// ` - Downloaded: 123.45 MiB, Written: 120.00 MiB`.
    static func downloaded(in line: String) -> Int64? {
        guard let marker = line.range(of: "Downloaded: ") else { return nil }
        let rest = line[marker.upperBound...]
        guard let space = rest.firstIndex(of: " "), let mebibytes = Double(rest[..<space]), mebibytes >= 0,
              rest[rest.index(after: space)...].hasPrefix("MiB") else { return nil }
        return Int64(mebibytes * 1_048_576)
    }

    /// `[cli] INFO: Install size: 1234.56 MiB`: what the game takes on disk, which Legendary writes once it has worked out what to
    /// download and before it checks the room for it and starts.
    public static func installSize(in line: String) -> Int64? {
        guard let marker = line.range(of: "Install size: ") else { return nil }
        let rest = line[marker.upperBound...]
        guard let space = rest.firstIndex(of: " "), let mebibytes = Double(rest[..<space]), mebibytes > 0,
              rest[rest.index(after: space)...].hasPrefix("MiB") else { return nil }
        return Int64(mebibytes * 1_048_576)
    }

    /// `Found previously interrupted download. Download will be resumed if possible.`: this install goes on from one that was
    /// stopped. Legendary writes it while it works out what to download, before it says how big the game is.
    public static func isResuming(_ line: String) -> Bool { line.contains("Found previously interrupted download") }

    /// `01:23:45` or `00:01:23`: hours, minutes, seconds.
    static func seconds(fromClock text: Substring) -> TimeInterval? {
        let clock = text.prefix { $0.isNumber || $0 == ":" }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
    }

    /// "under a minute", "about 5 min", "about 1 h 20 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if seconds < 60 { return "under a minute" }
        if minutes < 60 { return "about \(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "about \(minutes / 60) h" : "about \(minutes / 60) h \(rest) min"
    }
}
