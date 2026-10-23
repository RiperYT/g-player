import Foundation

/// Epic games G-Player installs with Legendary, and how they sit in the library: in a space of their own, on G-Player Wine,
/// each as a game with the source `.legendary`.
public enum EpicGames {
    /// The space they are installed in, made the first time one is, and found again by its `presetID`.
    public static let spaceName = "Epic Games"
    /// Matches no `AppPreset`: this space has no launcher to start or wrap, only games.
    public static let presetID = "legendary"

    public static func space(in spaces: [Space]) -> Space? {
        spaces.first { $0.presetID == presetID && $0.origin == .managed }
    }

    /// Where Legendary puts the games of the space (it makes a folder for each): `C:\Games\Epic`.
    public static func installBase(in space: Space) -> URL {
        space.driveC.appendingPathComponent("Games/Epic", isDirectory: true)
    }

    /// The file name of a game's cover in the library's Covers folder, or nil for a name that isn't Legendary's.
    public static func coverFileName(appName: String) -> String? {
        LegendaryCommand.isAppName(appName) ? "epic-\(appName).jpg" : nil
    }

    // MARK: The list of owned games, kept between runs

    /// What Epic last said the account owns, so the page has it at the next start, offline too. It lives next to Legendary's
    /// own files (`Tools`), apart from `library.json`: it is a copy of what Epic knows, not something the user made.
    public static func listFile(in paths: LibraryPaths) -> URL { paths.tools.appendingPathComponent("epic-library.json") }

    /// The kept list; empty when there is none or it can't be read. A name that isn't Legendary's is dropped.
    public static func loadList(in paths: LibraryPaths) -> [EpicGame] {
        guard let data = try? Data(contentsOf: listFile(in: paths)),
              let games = try? JSONDecoder().decode([EpicGame].self, from: data) else { return [] }
        return games.filter { LegendaryCommand.isAppName($0.appName) }
    }

    public static func saveList(_ games: [EpicGame], in paths: LibraryPaths) throws {
        try FileManager.default.createDirectory(at: paths.tools, withIntermediateDirectories: true)
        try JSONEncoder().encode(games).write(to: listFile(in: paths), options: .atomic)
    }

    /// Signing out takes the account's list with it.
    public static func forgetList(in paths: LibraryPaths) { try? FileManager.default.removeItem(at: listFile(in: paths)) }

    // MARK: In the library

    /// Brings the library's Epic games of `space` in line with `installed`, which is everything Legendary has installed (not a
    /// partial list: a game missing from it is taken out). A new game becomes a library entry; one that is already there keeps
    /// its title, playtime, settings and `hidden`, and learns again what it is if its program moved; one that Legendary no longer
    /// lists, or whose program is gone from the disk, leaves.
    /// - Parameter isPresent: whether a file is on the disk.
    public static func merge(existing: [Game], installed: [LegendaryInstalledGame], space: Space,
                             isPresent: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
        -> (games: [Game], changed: Bool) {
        var games = existing
        var changed = false
        var kept = Set<String>()
        for installedGame in installed {
            guard let program = installedGame.executableURL, isPresent(program) else { continue }
            kept.insert(installedGame.appName)
            let path = Game.storedPath(for: program, in: space)
            let source = Game.Source.legendary(appName: installedGame.appName)
            if let index = games.firstIndex(where: { $0.spaceID == space.id && $0.source == source }) {
                guard games[index].executablePath != path else { continue }
                games[index].executablePath = path
                games[index].analysis = nil                 // another program: look at it again
                games[index].autoGraphics = nil
                changed = true
            } else {
                games.append(Game(title: installedGame.title, spaceID: space.id, source: source, executablePath: path))
                changed = true
            }
        }
        let before = games.count
        games.removeAll { game in
            guard game.spaceID == space.id, case .legendary(let name) = game.source else { return false }
            return !kept.contains(name)
        }
        return (games, changed || games.count != before)
    }
}
