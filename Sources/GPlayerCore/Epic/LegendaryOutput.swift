import Foundation

/// Who Legendary says is signed in.
public struct LegendaryStatus: Equatable, Sendable {
    /// The account's display name, nil when nobody is signed in.
    public let account: String?
    public var isSignedIn: Bool { account != nil }
}

/// A game the account owns and Legendary can install. Only what G-Player shows is kept; this is also what is cached, so the
/// list is there at the next start without asking Epic.
public struct EpicGame: Codable, Hashable, Sendable, Identifiable {
    /// Legendary's name for the game ("SampleApp"), what every command takes.
    public let appName: String
    public let title: String
    /// Box art, from Epic's CDN.
    public let coverURL: URL?
    public var id: String { appName }

    public init(appName: String, title: String, coverURL: URL? = nil) {
        self.appName = appName; self.title = title; self.coverURL = coverURL
    }
}

/// A game Legendary has installed (`list-installed --json`).
public struct LegendaryInstalledGame: Hashable, Sendable {
    public let appName: String
    public let title: String
    public let version: String
    /// The game's folder on the Mac.
    public let installPath: String
    /// The program that starts it, relative to the folder, as Epic writes it (backslashes possible).
    public let executable: String
    public let installSize: Int64

    /// The program on the Mac. Nil when its path would leave the game's folder.
    public var executableURL: URL? { LegendaryOutput.executableURL(folder: installPath, executable: executable) }
    public var folder: URL { URL(fileURLWithPath: installPath, isDirectory: true) }
}

/// How to start a game, from `legendary launch --json`. It holds a one-time code that logs the game in as the user for a few
/// minutes, so it is used at once and never written down: `description` hides what `LaunchSecrets` hides.
public struct LegendaryLaunch: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let gameDirectory: String
    public let gameExecutable: String
    public let workingDirectory: String
    /// Arguments Epic's data gives the game, and the ones the user's Legendary settings add (none here).
    public let gameParameters: [String]
    public let userParameters: [String]
    /// Epic's sign-in arguments, among them `-AUTH_PASSWORD=<exchange code>`.
    public let eglParameters: [String]
    /// What Legendary adds to the game's environment: only the names in `LegendaryOutput.gameVariables`, and never one of
    /// G-Player's (`LegendaryOutput.isProtected`).
    public let environment: [String: String]

    public var executableURL: URL? { LegendaryOutput.executableURL(folder: gameDirectory, executable: gameExecutable) }

    /// The folder to start the program in: the one Legendary names, or the program's own.
    public var workingDirectoryURL: URL? {
        if workingDirectory.hasPrefix("/") { return URL(fileURLWithPath: workingDirectory, isDirectory: true) }
        return executableURL?.deletingLastPathComponent()
    }

    public var description: String {
        let all = LaunchSecrets.masked(gameParameters + userParameters + eglParameters).joined(separator: " ")
        return "LegendaryLaunch(\(gameDirectory)/\(gameExecutable) \(all))"
    }

    public var debugDescription: String { description }
}

/// Reads what Legendary prints with `--json`. Lenient: a field that isn't there or has another shape means "not known", and
/// only a whole answer that isn't JSON (or isn't the kind of JSON expected) is nil.
public enum LegendaryOutput {
    /// The variables of Legendary's launch environment that may reach a game, by name. Legendary sets none for a game by itself
    /// but `CX_BOTTLE` (it points at CrossOver, which G-Player doesn't use) and `WINEPREFIX` (the space is G-Player's choice);
    /// anything else comes from `[<game>.env]` sections of its config.ini, which G-Player doesn't write. So nothing passes: a
    /// name goes in here only when a game is found to need it.
    public static let gameVariables: Set<String> = []

    /// Names that are G-Player's to set (Wine, the graphics layers, the search path, the user's home), which no answer of
    /// Legendary may set, even when the name is in `gameVariables`.
    static func isProtected(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["WINE", "GST_", "DXVK_", "MVK_", "D3DM_", "CX_", "DYLD_", "LD_", "ROSETTA_"].contains(where: upper.hasPrefix)
            || ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG"].contains(upper) || upper.hasPrefix("LC_")
    }

    /// The part of Legendary's environment that may reach the game: the names in `allowed` that aren't protected.
    static func environment(from object: Any?, allowing allowed: Set<String>) -> [String: String] {
        var environment: [String: String] = [:]
        for (key, value) in (object as? [String: Any]) ?? [:] where allowed.contains(key) && !isProtected(key) {
            if let text = value as? String { environment[key] = text }
        }
        return environment
    }

    /// The JSON in Legendary's output: all of it, or from the first line that starts it when log lines came before.
    static func json(_ output: String) -> Any? {
        func parse(_ text: String) -> Any? { text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let whole = parse(trimmed) { return whole }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where line.hasPrefix("{") || line.hasPrefix("[") {
            if let found = parse(lines[index...].joined(separator: "\n")) { return found }
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // MARK: Status

    /// `status --offline --json`: `{"account": "<display name>", …}`, or `"<not logged in>"` as the account.
    public static func status(_ output: String) -> LegendaryStatus? {
        guard let object = json(output) as? [String: Any], let account = object["account"] as? String else { return nil }
        let name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        return LegendaryStatus(account: name.isEmpty || name == "<not logged in>" ? nil : name)
    }

    // MARK: Library

    /// `list --platform Windows --json`: the games to install, by title. Add-ons (DLC) and games another store installs
    /// (EA, Ubisoft: Legendary can't install them) are left out.
    public static func library(_ output: String) -> [EpicGame]? {
        guard let items = json(output) as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        let games: [EpicGame] = items.compactMap { item in
            guard let name = string(item["app_name"]), LegendaryCommand.isAppName(name), seen.insert(name).inserted else { return nil }
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            if metadata["mainGameItem"] is [String: Any] { return nil }
            if thirdPartyStore(metadata) != nil { return nil }
            return EpicGame(appName: name, title: string(item["app_title"]) ?? name, coverURL: coverURL(metadata))
        }
        return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The store that has to install a game ("Origin", "ubisoftconnect"), from its custom attributes.
    static func thirdPartyStore(_ metadata: [String: Any]) -> String? {
        let attributes = metadata["customAttributes"] as? [String: Any] ?? [:]
        for key in ["ThirdPartyManagedApp", "ThirdPartyManagedProvider"] {
            if let value = string((attributes[key] as? [String: Any])?["value"]) { return value }
        }
        return nil
    }

    /// Image types of Epic's catalog, the best cover first: tall box art suits G-Player's covers.
    static let coverTypes = ["DieselGameBoxTall", "OfferImageTall", "DieselStoreFrontTall", "Thumbnail", "DieselGameBox"]

    static func coverURL(_ metadata: [String: Any]) -> URL? {
        let images = (metadata["keyImages"] as? [[String: Any]]) ?? []
        for type in coverTypes {
            for image in images where image["type"] as? String == type {
                if let text = string(image["url"]), let url = URL(string: text), url.scheme?.lowercased() == "https" { return url }
            }
        }
        return nil
    }

    // MARK: Installed

    /// `list-installed --json`: the games with a program to start. Add-ons and games for another platform are left out.
    public static func installed(_ output: String) -> [LegendaryInstalledGame]? {
        guard let items = json(output) as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let name = string(item["app_name"]), LegendaryCommand.isAppName(name),
                  let path = string(item["install_path"]), path.hasPrefix("/"),
                  let executable = string(item["executable"]),
                  (item["is_dlc"] as? Bool) != true,
                  (string(item["platform"]) ?? "Windows").hasPrefix("Win") else { return nil }
            return LegendaryInstalledGame(appName: name, title: string(item["title"]) ?? name,
                                          version: string(item["version"]) ?? "", installPath: path, executable: executable,
                                          installSize: (item["install_size"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// The program of a game on the Mac: `executable` is relative to `folder`, with `/` or `\`. Nil when it isn't, or leaves the
    /// folder (a `..`).
    static func executableURL(folder: String, executable: String) -> URL? {
        guard folder.hasPrefix("/") else { return nil }
        let parts = executable.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts.reduce(URL(fileURLWithPath: folder, isDirectory: true)) { $0.appendingPathComponent($1) }
    }

    // MARK: Launch

    /// `launch --json`. Nil when it names no game folder or program.
    public static func launch(_ output: String, allowing allowed: Set<String> = gameVariables) -> LegendaryLaunch? {
        guard let object = json(output) as? [String: Any],
              let directory = string(object["game_directory"]), directory.hasPrefix("/"),
              let executable = string(object["game_executable"]) else { return nil }
        func list(_ key: String) -> [String] { (object[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
        return LegendaryLaunch(gameDirectory: directory, gameExecutable: executable,
                               workingDirectory: string(object["working_directory"]) ?? "",
                               gameParameters: list("game_parameters"), userParameters: list("user_parameters"),
                               eglParameters: list("egl_parameters"),
                               environment: environment(from: object["environment"], allowing: allowed))
    }
}
