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
        try Files.writePrivately(JSONEncoder().encode(games), to: listFile(in: paths))
    }

    /// Signing out takes the account's list with it.
    public static func forgetList(in paths: LibraryPaths) { try? FileManager.default.removeItem(at: listFile(in: paths)) }

    // MARK: What may happen at the same time

    /// Why a game can't be uninstalled right now (for the button's help), or nil. A running game has its files open and a starting
    /// one is about to; and Legendary does one thing at a time (`busy` says what it does).
    public static func uninstallBlock(gameIsRunning: Bool, gameIsStarting: Bool, busy: String?) -> String? {
        if gameIsRunning { return "Quit the game first." }
        if gameIsStarting { return "The game is starting. Wait for it, then quit it." }
        if let busy { return "Epic Games is busy (\(busy)). Wait for it to finish." }
        return nil
    }

    /// Why a game can't be started right now: it is being uninstalled.
    public static func playBlock(appName: String, uninstalling: String?) -> String? {
        uninstalling == appName ? "It is being uninstalled." : nil
    }

    // MARK: In the library

    /// True when `merged` has an Epic game `existing` doesn't. The library written then can't be read by a G-Player from before
    /// Epic Games, so a copy of the file as it is goes first (`LibraryStore.keepBeforeEpic`).
    public static func addsGames(_ merged: [Game], to existing: [Game]) -> Bool {
        func names(_ games: [Game]) -> Set<String> {
            Set(games.compactMap { game in if case .legendary(let name) = game.source { name } else { nil } })
        }
        return !names(merged).subtracting(names(existing)).isEmpty
    }

    /// Brings the library's Epic games of `space` in line with `installed`, what Legendary lists. A new game with its program on the
    /// disk becomes a library entry; one that is already there keeps its title, playtime, settings and `hidden`, and learns again what
    /// it is if its program moved. Nothing leaves: a game whose files aren't found (the library moved, a disk is away) or that
    /// Legendary no longer lists stays, marked by `health`, until the user removes it (`removing`) or fixes what is wrong; a look
    /// that came at a bad moment must never cost anyone a game's playtime and settings.
    /// - Parameter isPresent: whether a file is on the disk.
    public static func merge(existing: [Game], installed: [LegendaryInstalledGame], space: Space,
                             isPresent: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
        -> (games: [Game], changed: Bool) {
        var games = existing
        var changed = false
        for installedGame in installed {
            guard let program = installedGame.executableURL, isPresent(program) else { continue }
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
        return (games, changed)
    }

    /// `games` without the Epic game `appName` of `spaceID`: what happens once Legendary has uninstalled it or forgotten it.
    public static func removing(appName: String, of spaceID: UUID, from games: [Game]) -> [Game] {
        games.filter { !($0.spaceID == spaceID && $0.source == .legendary(appName: appName)) }
    }

    // MARK: Whether the files are where Legendary says

    /// How a library entry stands with what Legendary has recorded.
    public enum Health: Equatable, Sendable {
        case ok
        /// Legendary's record points at a place where the game's program isn't. `repairBase` is set when the program is in the
        /// Epic space at the same place below `drive_c` (the library moved, so the record still holds the old path): it is the
        /// folder to give Legendary (`Legendary.relink`).
        case filesNotFound(repairBase: URL?)
        /// Legendary has no record of the game: it can't be started from here, and the entry can only go.
        case notRecorded
    }

    /// - Parameters:
    ///   - record: what Legendary's list has for the game, nil when it has nothing.
    ///   - recordsKnown: Legendary's list has been read in this run; before that nothing is known, and nothing is wrong.
    ///   - isPresent: whether a file is on the disk.
    public static func health(record: LegendaryInstalledGame?, recordsKnown: Bool, space: Space,
                              isPresent: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Health {
        guard recordsKnown else { return .ok }
        guard let record else { return .notRecorded }
        if let program = record.executableURL, isPresent(program) { return .ok }
        let base = installBase(in: space)
        let folder = base.appendingPathComponent(URL(fileURLWithPath: record.installPath).lastPathComponent, isDirectory: true)
        let here = LegendaryOutput.executableURL(folder: folder.path, executable: record.executable)
        guard let here, !Legendary.samePath(folder.path, record.installPath), isPresent(here) else { return .filesNotFound(repairBase: nil) }
        return .filesNotFound(repairBase: base)
    }

    /// What to tell the user about a game that isn't `ok`, and what removing it means.
    public struct Note: Equatable, Sendable {
        /// A few words for a label: "Files not found".
        public let title: String
        /// What happened and what can be done.
        public let detail: String
        /// The question before the entry is removed, which says that no file is deleted.
        public let removal: String
    }

    public static func note(for health: Health, title: String) -> Note? {
        switch health {
        case .ok:
            return nil
        case .filesNotFound(.some):
            return Note(title: "Files not found",
                        detail: "Legendary's record of “\(title)” points at its old place, but its files are in this library's Epic Games space. Repair points the record at them.",
                        removal: "Legendary forgets that “\(title)” is installed and it leaves the library. No file is deleted. You can install it again from Epic Games.")
        case .filesNotFound(nil):
            return Note(title: "Files not found",
                        detail: "“\(title)” isn't where Epic Games installed it. If you moved its files, put them back, or remove it and install it again.",
                        removal: "Legendary forgets that “\(title)” is installed and it leaves the library. No file is deleted. You can install it again from Epic Games.")
        case .notRecorded:
            return Note(title: "Not installed",
                        detail: "Legendary has no record of “\(title)” any more. Remove it from the library, then install it again from Epic Games.",
                        removal: "“\(title)” leaves the library. Legendary has no record of it, and no file is deleted.")
        }
    }
}
