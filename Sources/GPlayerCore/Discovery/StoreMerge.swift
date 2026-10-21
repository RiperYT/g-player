import Foundation

/// Brings a space's store games (Steam, Epic) in line with what the stores report.
public enum StoreMerge {
    /// - Parameters:
    ///   - existing: every game in the library; only the ones in `spaceID` can change.
    ///   - found: every game the stores list for this space, installed or not. A game that is being updated
    ///     or whose manifest says "incomplete" is listed but not installed.
    ///   - hiddenKeys: the old `hiddenStoreKeys`. A key whose game turns up with no entry becomes an entry with
    ///     `hidden` set, and leaves the returned keys.
    /// - Returns: the new games, the remaining keys, and whether anything changed.
    ///
    /// A new entry appears only once its game is installed. An entry stays as long as the stores list its game
    /// at all, so an update in progress keeps its title, playtime and `hidden`. An entry is dropped when its
    /// game is no longer listed; a hidden one puts its key back into the returned keys, so the game comes back
    /// hidden if it is installed again.
    public static func merge(existing: [Game], found: [StoreGame], hiddenKeys: Set<String>, spaceID: UUID)
        -> (games: [Game], hiddenKeys: Set<String>, changed: Bool) {
        var games = existing
        var keys = hiddenKeys
        var listed = Set<String>()
        var changed = false
        for store in found {
            guard let key = Game.storeKey(for: store.source) else { continue }
            listed.insert(key)
            guard store.installed, !games.contains(where: { $0.spaceID == spaceID && $0.storeKey == key }) else { continue }
            var game = Game(title: store.title, spaceID: spaceID, source: store.source)
            if keys.remove(key) != nil { game.hidden = true }
            games.append(game)
            changed = true
        }
        let before = games.count
        games.removeAll { game in
            guard game.spaceID == spaceID, let key = game.storeKey, !listed.contains(key) else { return false }
            if game.isHidden { keys.insert(key) }
            return true
        }
        return (games, keys, changed || games.count != before)
    }
}
