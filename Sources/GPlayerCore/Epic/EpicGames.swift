import Foundation

/// Epic games G-Player installs with Legendary, and how they sit in the library: in a space of their own, on G-Player Wine,
/// each as a game with the source `.legendary`.
public enum EpicGames {
    /// The space they are installed in, made the first time one is, and found again by its `presetID`.
    public static let spaceName = "Epic Games"
    /// Matches no `AppPreset`: this space has no launcher to start or wrap, only games.
    public static let presetID = "legendary"
    /// Where the page of the account and its games is, for messages that send people there: it opens from the Epic Games card in
    /// Get Apps, and from the Epic Games space's page.
    public static let libraryPlace = String(localized: "Get Apps › Epic Games")

    public static func space(in spaces: [Space]) -> Space? {
        spaces.first { isGamesSpace($0) && $0.origin == .managed }
    }

    /// The space is the one Legendary installs into (by its `presetID`): its page links to Epic's.
    public static func isGamesSpace(_ space: Space) -> Bool { space.presetID == presetID }

    /// What the buttons that open the page of the account and its games say: the second way on Get Apps' Epic Games card, and the
    /// link on the Epic Games space's page. It is a place, not an action that needs more input, so no ellipsis.
    public static let libraryTitle = String(localized: "Your Epic Library")

    /// Where Legendary puts the games of the space (it makes a folder for each): `C:\Games\Epic`.
    public static func installBase(in space: Space) -> URL {
        space.driveC.appendingPathComponent("Games/Epic", isDirectory: true)
    }

    /// The file name of a game's cover in the library's Covers folder, or nil for a name that isn't Legendary's.
    public static func coverFileName(appName: String) -> String? {
        LegendaryCommand.isAppName(appName) ? "epic-\(appName).jpg" : nil
    }

    /// The engine of the Epic Games space: the installed G-Player Wine (the current revision, or a retired one that moves later), else
    /// G-Player Wine itself, which then downloads. Never Wine Staging, which `EngineCatalog.engineForNewSpace` gives when that is
    /// all there is: Epic's games are run on G-Player Wine.
    public static func engineForSpace(installed: [EngineInfo]) -> EngineInfo {
        EngineCatalog.installedGPlayerWine(in: installed) ?? EngineCatalog.defaultForNewSpaces
    }

    // MARK: Before an install

    /// What the install question tells: where the game goes, what G-Player has to fetch first, how much room it takes.
    public struct InstallDetails: Equatable, Sendable {
        public let lines: [String]
        /// Why it can't be installed (the disk is too small), or nil.
        public let problem: String?
    }

    /// - Parameters:
    ///   - sizeBytes: what the game takes once installed, from Legendary; nil when not known (yet).
    ///   - availableBytes: free room on the disk, nil when it can't be told.
    ///   - spaceExists: the Epic Games space is there; otherwise it is made first.
    ///   - engineDownloadBytes: what G-Player Wine still has to download first, nil when it is installed.
    public static func installDetails(sizeBytes: Int64?, availableBytes: Int64?, spaceExists: Bool,
                                      engineDownloadBytes: Int64?) -> InstallDetails {
        var lines: [String] = []
        if let sizeBytes { lines.append(String(localized: "It takes about \(sizeBytes.formattedBytes) on disk.")) }
        lines.append(spaceExists ? String(localized: "It goes into the “\(spaceName)” space.")
                                 : String(localized: "It goes into the “\(spaceName)” space, which G-Player makes first."))
        if let engineDownloadBytes {
            lines.append(String(localized: "G-Player Wine isn't installed yet, so G-Player downloads it first (about \(EngineCatalog.megabytes(engineDownloadBytes)) MB)."))
        }
        let problem = sizeBytes.flatMap { DiskSpace.problem(needing: $0, available: availableBytes, for: String(localized: "It", comment: "Starts “It needs about 5 GB free, and this disk has …”")) }
        return InstallDetails(lines: lines, problem: problem)
    }

    // MARK: Starting

    /// What the game's tile says while Legendary is asked how to start it (a few seconds, and up to `Legendary.Limits` when Epic is slow).
    public static let askingEpic = String(localized: "Asking Epic for the launch parameters…")

    /// The one line for a game that was started without Epic's login, since Epic couldn't be reached.
    public static func offlineNote(reason: String) -> String { String(localized: "Started offline: \(reason)") }

    // MARK: What is kept between runs

    /// What is kept on disk about the account, so the page has it at the next start, offline too: who was signed in (a look
    /// that fails then doesn't make the page look signed out) and the games Epic said it owns. It lives next to Legendary's own
    /// files (`Tools`), apart from `library.json`, readable by the user only: it is a copy of what Epic knows, not something the
    /// user made.
    public struct Cache: Codable, Equatable, Sendable {
        public var account: String?
        public var games: [EpicGame]
        public init(account: String? = nil, games: [EpicGame] = []) { self.account = account; self.games = games }
    }

    public static func cacheFile(in paths: LibraryPaths) -> URL { paths.tools.appendingPathComponent("epic-library.json") }

    /// What was kept; empty when there is nothing or it can't be read. A game with a name that isn't Legendary's is dropped.
    public static func loadCache(in paths: LibraryPaths) -> Cache {
        guard let data = try? Data(contentsOf: cacheFile(in: paths)), var cache = try? JSONDecoder().decode(Cache.self, from: data) else { return Cache() }
        cache.games = cache.games.filter { LegendaryCommand.isAppName($0.appName) }
        return cache
    }

    public static func saveCache(_ cache: Cache, in paths: LibraryPaths) throws {
        try Files.writePrivately(JSONEncoder().encode(cache), to: cacheFile(in: paths))
    }

    /// Signing out takes the account's name and list with it.
    public static func forgetCache(in paths: LibraryPaths) { try? FileManager.default.removeItem(at: cacheFile(in: paths)) }

    // MARK: What the page shows

    /// The account the page shows after a look at Legendary: what the look says when it could ask (nobody, when Legendary says
    /// "not logged in"), and what it was before when it couldn't. A look that fails says nothing about being signed out.
    public static func account(afterLook look: Result<LegendaryStatus, Error>, was previous: String?) -> String? {
        switch look {
        case .success(let status): status.account
        case .failure: previous
        }
    }

    /// The line for a look that failed.
    public static func lookFailureLine(_ error: Error) -> String { String(localized: "Couldn't reach Legendary: \(error.localizedDescription)") }

    /// Which of the page's states is shown: the account and its games, the sign-in card, a wait, or only the failure.
    public enum Page: Equatable, Sendable { case signedIn, signedOut, checking, failed }

    public static func page(account: String?, looked: Bool, lookFailed: Bool) -> Page {
        if account != nil { return .signedIn }                 // also with a failed look: what was known stays, with the failure above
        if lookFailed { return .failed }                       // nothing known, and nothing can be said about it
        return looked ? .signedOut : .checking
    }

    /// What the list of games shows.
    public enum ListContent: Equatable, Sendable { case games, loading, empty, failureOnly }

    /// A list that is there (kept from the last time) is shown whatever happened since: a failed fetch is a line above it.
    public static func listContent(hasGames: Bool, fetched: Bool, fetchFailed: Bool) -> ListContent {
        if hasGames { return .games }
        if fetchFailed { return .failureOnly }
        return fetched ? .empty : .loading
    }

    // MARK: What may happen at the same time

    /// Why a game can't be uninstalled right now (for the button's help), or nil. A running game has its files open and a starting
    /// one is about to; and Legendary does one thing at a time (`busy` says what it does).
    public static func uninstallBlock(gameIsRunning: Bool, gameIsStarting: Bool, busy: String?) -> String? {
        if gameIsRunning { return String(localized: "Quit the game first.") }
        if gameIsStarting { return String(localized: "The game is starting. Wait for it, then quit it.") }
        if let busy { return String(localized: "Epic Games is busy (\(busy)). Wait for it to finish.") }
        return nil
    }

    /// Why a game can't be started right now: it is being uninstalled.
    public static func playBlock(appName: String, uninstalling: String?) -> String? {
        uninstalling == appName ? String(localized: "It is being uninstalled.") : nil
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
            return Note(title: String(localized: "Files not found"),
                        detail: String(localized: "Legendary's record of “\(title)” points at its old place, but its files are in this library's Epic Games space. Repair points the record at them."),
                        removal: String(localized: "Legendary forgets that “\(title)” is installed and it leaves the library. No file is deleted. You can install it again from \(libraryPlace)."))
        case .filesNotFound(nil):
            return Note(title: String(localized: "Files not found"),
                        detail: String(localized: "“\(title)” isn't where Epic Games installed it. If you moved its files, put them back, or remove it and install it again."),
                        removal: String(localized: "Legendary forgets that “\(title)” is installed and it leaves the library. No file is deleted. You can install it again from \(libraryPlace)."))
        case .notRecorded:
            return Note(title: String(localized: "Not installed"),
                        detail: String(localized: "Legendary has no record of “\(title)” any more. Remove it from the library, then install it again from \(libraryPlace)."),
                        removal: String(localized: "“\(title)” leaves the library. Legendary has no record of it, and no file is deleted."))
        }
    }
}
