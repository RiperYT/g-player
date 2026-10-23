import Foundation

/// What a space's "Move to…?" question says: which engine, what it downloads, and whether it is a newer or an older
/// Wine than the space runs on now (a newer one updates the space's files, which an older one may not open afterwards).
/// Also what a space's page offers about its engine (`pageOffer`).
public enum EngineSwitch {
    public enum Age: Sendable, Equatable { case newer, older, same }

    /// What a space's page offers about its engine.
    public enum PageOffer: Sendable, Equatable {
        /// Nothing: the space is on G-Player Wine (any revision) and nobody asked to choose engines, or its engine is unknown.
        case nothing
        /// The engine menu, with this engine selected: the offered engine the space is on (a retired revision of G-Player Wine
        /// shows as G-Player Wine).
        case picker(selected: String)
        /// Plain words about the engine the space is on, and "Move to G-Player Wine…": it is on an engine new spaces don't
        /// use (Wine Staging, or Apple's toolkit, which the menu doesn't list).
        case move
    }

    /// What the page of a space on `engineID` offers. The engine menu is for those who turned on "Choose the Wine engine for
    /// each space" (`choosingEngines`); a space on Apple's toolkit has no place in it, so it gets the move either way.
    public static func pageOffer(engineID: String, choosingEngines: Bool) -> PageOffer {
        guard EngineCatalog.info(engineID) != nil else { return .nothing }
        let listed = EngineCatalog.all.first { EngineCatalog.isRevision(engineID, of: $0) }
        if choosingEngines, let listed { return .picker(selected: listed.id) }
        return listed?.id == EngineCatalog.defaultForNewSpaces.id ? .nothing : .move
    }

    /// A space made for a launcher that opens only on G-Player Wine (`AppPreset.needsGPlayerWine`) runs on another engine: its page
    /// offers the move whether or not the engine menus are on, and says why (`launcherMoveDetail`).
    public static func launcherNeedsMove(presetID: String?, engineID: String) -> Bool {
        AppPresets.preset(presetID)?.needsGPlayerWine == true && !EngineCatalog.isRevision(engineID, of: EngineCatalog.crossover)
    }

    /// The line under that offer, or nil for a space of another kind.
    public static func launcherMoveDetail(presetID: String?) -> String? {
        guard let preset = AppPresets.preset(presetID), preset.needsGPlayerWine else { return nil }
        return "\(preset.name) opens only on G-Player Wine. Moving asks first."
    }

    /// The Wine release an engine is made from: 11.18 for Wine Staging 11.18, 11.0 for G-Player Wine, 7.7 for Apple's toolkit.
    static func release(of info: EngineInfo) -> [Int] {
        if info.kind == .gptk { return [7, 7] }
        return info.version.split(separator: ".").compactMap { Int($0) }
    }

    /// Whether `target` is a newer or older Wine than `current`.
    public static func age(of target: EngineInfo, comparedTo current: EngineInfo) -> Age {
        let a = release(of: target), b = release(of: current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y ? .newer : .older }
        }
        return .same
    }

    public static func title(space: String, to target: EngineInfo) -> String {
        "Move “\(space)” to \(target.name)?"
    }

    /// The question's text. `current` is nil when the space's engine isn't one G-Player knows.
    public static func message(space: String, from current: EngineInfo?, to target: EngineInfo, downloadBytes: Int64) -> String {
        var text = "Every program in “\(space)” will run on \(label(target))"
        text += current.map { " instead of \(label($0))." } ?? "."
        if downloadBytes > 0 { text += " \(target.name) downloads first, about \(EngineCatalog.megabytes(downloadBytes)) MB." }
        switch current.map({ age(of: target, comparedTo: $0) }) {
        case .newer:
            text += " It's a newer Wine than the space has now, so the space's files are updated for it the first time it starts, and the older Wine may not open the space afterwards."
        case .older:
            text += " It's an older Wine than the space has now, and a space that a newer Wine has updated may not open on it."
        case .same, nil:
            break
        }
        return text
    }

    /// Why Switch is off while programs run in the space.
    public static func busyMessage(space: String) -> String {
        "Programs are running in “\(space)”. Stop them (Stop All, in the space) and switch then."
    }

    private static func label(_ info: EngineInfo) -> String {
        info.kind == .gptk ? info.shortName : info.displayName
    }
}
