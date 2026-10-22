import Foundation

/// Known fixes for single games: seeded from umu-protonfixes (BSD-2-Clause) plus G-Player's own curated entries.
/// The data is `Resources/GameFixes.json`, built by `tools/compat-db/import_umu.py`.
public struct GameFixDatabase: Sendable {
    public enum LoadError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    static let supportedVersion = 1

    public var fixes: [GameFix] { didSet { index = Index(fixes) } }
    private var index: Index

    public init(fixes: [GameFix] = []) {
        self.fixes = fixes
        self.index = Index(fixes)
    }

    public static func load(from url: URL) throws -> GameFixDatabase {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard file.version == supportedVersion else { throw LoadError.unsupportedVersion(file.version) }
        return GameFixDatabase(fixes: file.fixes)
    }

    /// The database shipped with the app. Empty (never a crash) when the file is missing or unreadable.
    public static let bundled: GameFixDatabase = {
        guard let url = CoreResources.url("GameFixes.json"), let database = try? load(from: url) else {
            return GameFixDatabase()
        }
        return database
    }()

    public func fix(id: String) -> GameFix? { index.byID[id] }

    /// Fixes for a game: those for its Steam app first, then those for its program's file name (any case,
    /// with or without a path). Each fix appears once.
    public func fixes(steamAppID: String?, exeName: String?) -> [GameFix] {
        var result: [GameFix] = []
        var seen = Set<String>()
        func add(_ matches: [GameFix]?) {
            for fix in matches ?? [] where seen.insert(fix.id).inserted { result.append(fix) }
        }
        if let steamAppID { add(index.bySteamAppID[steamAppID]) }
        if let name = Self.fileName(exeName) { add(index.byExeName[name]) }
        return result
    }

    private static func fileName(_ path: String?) -> String? {
        path?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last?.lowercased()
    }

    private struct File: Decodable {
        var version: Int
        var fixes: [GameFix]
    }

    /// Dictionaries built once, so lookups don't scan. The first fix with an id wins.
    private struct Index: Sendable {
        var byID: [String: GameFix] = [:]
        var bySteamAppID: [String: [GameFix]] = [:]
        var byExeName: [String: [GameFix]] = [:]

        init(_ fixes: [GameFix]) {
            for fix in fixes where byID[fix.id] == nil {
                byID[fix.id] = fix
                for appID in Set(fix.steamAppIDs) { bySteamAppID[appID, default: []].append(fix) }
                for name in Set(fix.exeNames.compactMap { GameFixDatabase.fileName($0) }) {
                    byExeName[name, default: []].append(fix)
                }
            }
        }
    }
}
