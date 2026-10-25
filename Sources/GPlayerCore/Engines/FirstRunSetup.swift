import Foundation

/// The words of the first run, made from facts: how much G-Player Wine downloads and takes on disk, what G-Player is doing
/// while the library waits for it, and what to know before bringing bottles over. Pure, so tests hold the figures.
public enum FirstRunSetup {
    /// What the first run's engine needs on this disk: unpacked, with room for the files it downloads (they stay until it has
    /// installed) and for GStreamer's package while it is expanded.
    public static var diskBytes: Int64 { EngineCatalog.diskBytes(installing: EngineCatalog.firstRunInstalls) }
    /// The figure for G-Player Wine ("3.0 GB"); nothing once it is installed.
    public static func diskLabel(installed: [EngineInfo] = []) -> String {
        String(format: "%.1f GB", Double(EngineCatalog.firstRunDiskBytes(installed: installed)) / 1_000_000_000)
    }

    /// The engine step's size paragraph: the download, the disk, and that every file is checked. Nil when G-Player Wine is
    /// installed. With a Wine Staging that an earlier version installed, it says what is still to download (G-Player Wine
    /// takes its libraries from it), so the figure never looks like the whole.
    public static func engineSizes(installed: [EngineInfo]) -> String? {
        let left = EngineCatalog.firstRunBytes(installed: installed)
        guard left > 0 else { return nil }
        let mb = EngineCatalog.megabytes(left), disk = diskLabel(installed: installed)
        return left == EngineCatalog.firstRunBytes(installed: [])
            ? String(localized: "The download is about \(mb) MB, and G-Player Wine needs about \(disk) on this disk. G-Player checks every file before it uses it.")
            : String(localized: "\(mb) MB is still to download, and G-Player Wine needs about \(disk) on this disk. G-Player checks every file before it uses it.")
    }

    /// What Continue says on the location step, which starts the downloads. Nil when nothing is left to download.
    public static func continueNote(installed: [EngineInfo]) -> String? {
        let left = EngineCatalog.firstRunBytes(installed: installed)
        guard left > 0 else { return nil }
        let mb = EngineCatalog.megabytes(left)
        return left == EngineCatalog.firstRunBytes(installed: [])
            ? String(localized: "Continue downloads about \(mb) MB and needs about \(diskLabel(installed: installed)) on this disk.")
            : String(localized: "Continue downloads \(mb) MB more and needs about \(diskLabel(installed: installed)) on this disk.")
    }

    /// What the empty library says while the first run works: G-Player Wine downloading (with what is left to download),
    /// or the first spaces being made. Nil when it isn't working: an engine that failed to download and waits for the next
    /// start says nothing here.
    /// - Parameters:
    ///   - downloading: an engine is installing now.
    ///   - pendingSpaces: the first spaces not made yet (`"main"`, `"steam"`).
    public static func libraryStatus(installed: [EngineInfo], downloading: Bool, pendingSpaces: [String]) -> String? {
        let spaces = spaceNames(pendingSpaces)
        if downloading {
            let missing = EngineCatalog.firstRunInstalls.filter { engine in !installed.contains { $0.id == engine.id } }
            let mb = EngineCatalog.megabytes(EngineCatalog.firstRunBytes(installed: installed))
            let text = missing.first.map { String(localized: "G-Player is downloading \($0.name), about \(mb) MB.") }
                ?? String(localized: "G-Player Wine is almost ready.")
            return spaces.isEmpty ? text : text + " " + String(localized: "Then it sets up \(spaces).")
        }
        guard !pendingSpaces.isEmpty, EngineCatalog.firstRunEngine(installed: installed) != nil else { return nil }
        let steam = pendingSpaces.contains("steam"), main = pendingSpaces.contains("main")
        let slow = String(localized: "Steam downloads its own files too, so this takes a few minutes.")
        if main && steam { return String(localized: "G-Player is getting Windows ready for Main and installing Steam.") + " " + slow }
        if steam { return String(localized: "G-Player is installing Steam.") + " " + slow }
        return String(localized: "G-Player is getting Windows ready for Main. This takes about a minute.")
    }

    /// The note for a first run that waits because the user stopped a download: what is on hold and how it goes on. Nothing is
    /// made on an engine the user didn't want.
    public static func pausedNote(pendingSpaces: [String]) -> (title: String, text: String) {
        let names = spaceNames(pendingSpaces)
        return (String(localized: "Setup is on hold"),
                String(localized: "You stopped the download, so setting up \(names.isEmpty ? String(localized: "the first spaces") : names) is on hold.")
                + " " + String(localized: "It goes on once G-Player Wine is installed: download it in Settings › Engines, or it starts again the next time G-Player opens."))
    }

    /// "Main and Steam", for the spaces the first run still has to make.
    private static func spaceNames(_ keys: [String]) -> String {
        let names = keys.compactMap { ["main": "Main", "steam": "Steam"][$0] }
        return CompatResolver.list(names)
    }

    /// The one-time note for someone who updated: G-Player Wine is new, and spaces they have keep what they run on. It
    /// applies while some space runs on another engine and the note hasn't been closed. A space on an earlier revision of
    /// G-Player Wine already runs G-Player Wine.
    public static func upgradeNoteApplies(spaces: [Space], seen: Bool) -> Bool {
        !seen && spaces.contains { !EngineCatalog.isRevision($0.engineID, of: EngineCatalog.defaultForNewSpaces) }
    }

    /// What to know before bringing CrossOver or Whisky bottles over: G-Player Wine changes a bottle's files the first
    /// time it starts there, which that app may not like. Nil when none of `found` is such a bottle.
    public static func bottleWarning(for found: [FoundEnvironment]) -> String? {
        var apps: [String] = []
        for f in found where f.isAnotherAppsBottle && !apps.contains(f.originNote) { apps.append(f.originNote) }
        guard !apps.isEmpty else { return nil }
        let names = apps.count == 2 ? String(localized: "\(apps[0]) or \(apps[1])") : apps.joined(separator: ", ")
        return String(localized: "G-Player Wine updates a \(names) bottle's files the first time it starts there, and \(names) may not open the bottle afterwards. Make a copy first if you still use it there.")
    }
}

extension FoundEnvironment {
    /// A CrossOver or Whisky bottle: another app's own folder, which G-Player Wine (any revision of it) runs in place.
    public var isAnotherAppsBottle: Bool {
        (originNote == "CrossOver" || originNote == "Whisky") && EngineCatalog.isRevision(suggestedEngineID, of: EngineCatalog.crossover)
    }
}
