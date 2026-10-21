import Foundation

/// A Windows environment that already exists on this Mac (CrossOver bottle, Whisky bottle, a hand-made prefix).
public struct FoundEnvironment: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public let name: String
    public let url: URL
    public let originNote: String
    public let suggestedEngineID: String
    public let presetID: String?
    public let games: [FoundGame]
    public let size: Int64?
}

public struct FoundGame: Sendable, Hashable {
    public let title: String
    public let executable: URL
    public let arguments: [String]
}

public enum EnvironmentFinder {
    /// Places other tools keep their prefixes.
    static func searchRoots(home: URL) -> [(URL, String, Int)] {
        [
            (home.appendingPathComponent("Library/Application Support/CrossOver/Bottles"), "CrossOver", 1),
            (home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/Bottles"), "Whisky", 1),
            (home.appendingPathComponent("Games"), "~/Games", 2),
        ]
    }

    /// Finds prefixes, skipping G-Player's own library and those already added.
    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            excluding: [URL] = [], gptkInstalled: Bool) -> [FoundEnvironment] {
        let fm = FileManager.default
        let skip = Set(excluding.map { $0.standardizedFileURL.path })
        var found: [FoundEnvironment] = []
        var seen = Set<String>()
        for (root, note, depth) in searchRoots(home: home) where fm.fileExists(atPath: root.path) {
            for url in candidates(in: root, depth: depth) {
                let path = url.standardizedFileURL.path
                guard SpaceManager.isPrefix(url), seen.insert(path).inserted,
                      !skip.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                let scripts = LegacyScripts.games(forPrefix: url, scriptsFolder: url.deletingLastPathComponent(), home: home)
                let hasSteam = fm.fileExists(atPath: url.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe").path)
                let engine: String = {
                    if note == "CrossOver" || note == "Whisky" || hasSteam { return EngineCatalog.wineStaging.id }
                    if let e = scripts.engineID { return e }
                    return gptkInstalled ? EngineCatalog.gptk.id : EngineCatalog.wineStaging.id
                }()
                found.append(FoundEnvironment(name: url.lastPathComponent, url: url, originNote: note,
                                              suggestedEngineID: engine, presetID: hasSteam ? "steam" : nil,
                                              games: scripts.games, size: nil))
            }
        }
        return found
    }

    static func candidates(in root: URL, depth: Int) -> [URL] {
        let fm = FileManager.default
        var level = [root], all: [URL] = []
        for _ in 0..<depth {
            level = level.flatMap { dir in
                ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                    .filter { Files.isDirectory($0) }
            }
            all += level
        }
        return all
    }
}

/// Reads launcher scripts made by hand (or by an earlier guide) to find which game a prefix runs.
/// Understands `WINEPREFIX="…"`, `wine-run.sh <Name> "<exe>"` and `GAME="…"` lines.
public enum LegacyScripts {
    public struct Result: Sendable { public var games: [FoundGame] = []; public var engineID: String? }

    public static func games(forPrefix prefix: URL, scriptsFolder: URL, home: URL) -> Result {
        let fm = FileManager.default
        var result = Result()
        let scripts = ((try? fm.contentsOfDirectory(at: scriptsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "sh" }
        for script in scripts {
            guard let text = try? String(contentsOf: script, encoding: .utf8) else { continue }
            let vars = variables(in: text, home: home)
            let prefixPath = vars["WINEPREFIX"] ?? wineRunPrefix(in: text, scriptsFolder: scriptsFolder)
            guard let prefixPath, URL(fileURLWithPath: prefixPath).standardizedFileURL.path == prefix.standardizedFileURL.path
            else { continue }
            if text.contains("Wine Staging") { result.engineID = EngineCatalog.wineStaging.id }
            else if text.contains("Game Porting Toolkit") || text.contains("wine-run.sh") { result.engineID = result.engineID ?? EngineCatalog.gptk.id }
            guard let exe = vars["GAME"], exe.lowercased().hasSuffix(".exe"), fm.fileExists(atPath: exe) else { continue }
            let url = URL(fileURLWithPath: exe)
            let title = script.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "play-", with: "").replacingOccurrences(of: "-", with: " ")
            let niceTitle = url.deletingPathExtension().lastPathComponent.lowercased() == "game"
                ? title.capitalized : url.deletingPathExtension().lastPathComponent
            result.games.append(FoundGame(title: niceTitle, executable: url,
                                          arguments: ExecutableCandidate.chromiumArguments(for: url)))
        }
        return result
    }

    /// `NAME="value"` assignments with `$HOME`, `${HOME}`, `~` and earlier variables expanded.
    static func variables(in text: String, home: URL) -> [String: String] {
        var vars = ["HOME": home.path]
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let eq = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let name = String(line[..<eq])
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            // ${VAR:-default} → default when VAR is not set by the script itself
            if value.hasPrefix("${"), let colon = value.range(of: ":-"), value.hasSuffix("}") {
                let v = String(value[value.index(value.startIndex, offsetBy: 2)..<colon.lowerBound])
                value = vars[v] ?? String(value[colon.upperBound..<value.index(before: value.endIndex)])
            }
            vars[name] = expand(value, vars)
        }
        return vars
    }

    static func expand(_ value: String, _ vars: [String: String]) -> String {
        var v = value
        if v.hasPrefix("~/") { v = (vars["HOME"] ?? "") + v.dropFirst() }
        for (k, val) in vars.sorted(by: { $0.key.count > $1.key.count }) {
            v = v.replacingOccurrences(of: "${\(k)}", with: val).replacingOccurrences(of: "$\(k)", with: val)
        }
        return v
    }

    /// `"$HOME/Games/wine-run.sh" MyGame "$GAME"` → `<scriptsFolder>/MyGame`.
    static func wineRunPrefix(in text: String, scriptsFolder: URL) -> String? {
        guard let range = text.range(of: "wine-run.sh\"? +([A-Za-z0-9_.-]+)", options: .regularExpression) else { return nil }
        let name = text[range].split(whereSeparator: { $0 == " " }).last.map(String.init) ?? ""
        return name.isEmpty ? nil : scriptsFolder.appendingPathComponent(name).path
    }
}
