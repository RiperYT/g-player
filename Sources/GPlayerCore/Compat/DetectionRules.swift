import Foundation

/// SteamDB's file detection rules: regular expressions over the relative paths of a game's files that say which
/// engine, anti-cheat, launcher or SDK it uses. The rules are `steamdb-rules.ini` from
/// SteamDatabase/FileDetectionRuleSets (MIT, see NOTICE), matched the way that project does:
///   - a path is relative to the game folder and uses `/`, e.g. `game/bin/win64/dota2.exe`;
///   - every rule is case insensitive and runs on the whole path;
///   - a rule that ends in a plain `.ext` only runs on files with that extension (SteamDB's speed-up);
///   - `Engine` rules are strong signs; `Evidence` rules only feed a second pass (`deduceEngine`) that names
///     engines hard to see from one file: Godot, GameMaker, idTech, RAGE and a few others.
/// The rules are compiled once. Matching is thread safe.
public final class DetectionRules: @unchecked Sendable {
    /// The rules in `Resources/steamdb-rules.ini` plus `gplayerRules`.
    public static let shared: DetectionRules = {
        let steamDB = CoreResources.url("steamdb-rules.ini").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return DetectionRules(iniText: steamDB + "\n" + gplayerRules)
    }()

    /// G-Player's own additions, in the same syntax, so that `steamdb-rules.ini` stays exactly as upstream has it.
    /// SteamDB finds Electron by `LICENSE.electron.txt`, which many packaged games leave out; the app folder
    /// (`resources/app`, `resources/app.asar`) is what the Electron runtime itself looks for.
    static let gplayerRules = """
    [Container]
    Electron[] = (?:^|/)resources/(?:app\\.asar|electron\\.asar|default_app\\.asar|app/package\\.json)$
    """

    /// How many rules each section has (`Engine`, `AntiCheat`…), counting every `Name[]` line.
    public let ruleCounts: [String: Int]
    /// `Section.Name` of rules that could not be compiled and are ignored. Empty for the bundled file.
    public let rejected: [String]

    private let sections: [Section]

    // MARK: Matching

    /// Section → rule names that match any of the paths, e.g. `["Engine": ["Unity"], "AntiCheat": ["BattlEye"]]`.
    /// Includes the engine the second pass deduces; leaves out the `Evidence` section.
    public func matches(relativePaths: [String]) -> [String: Set<String>] {
        var result = match(relativePaths)
        if let engine = result.deducedEngine { result.matches["Engine", default: []].insert(engine) }
        result.matches["Evidence"] = nil
        return result.matches.filter { !$0.value.isEmpty }
    }

    struct Result {
        /// Every section, `Evidence` included, without the deduced engine.
        var matches: [String: Set<String>] = [:]
        /// The engine the second pass guessed, if it did.
        var deducedEngine: String?
    }

    func match(_ paths: [String]) -> Result {
        var found: [String: Set<String>] = [:]
        var exhausted = Set<Int>()                          // matchers whose rules have all been found
        for path in paths where !path.isEmpty {
            let range = NSRange(location: 0, length: path.utf16.count)
            let ext = Self.fileExtension(of: path).lowercased()
            func run(_ matchers: [Matcher], in section: String) {
                for matcher in matchers where !exhausted.contains(matcher.id) {
                    guard matcher.combined.firstMatch(in: path, range: range) != nil else { continue }
                    // The combined expression only says "something matched"; the members say what.
                    var allFound = true
                    for member in matcher.members {
                        if found[section]?.contains(member.name) == true { continue }
                        if member.regex.firstMatch(in: path, range: range) != nil {
                            found[section, default: []].insert(member.name)
                        } else {
                            allFound = false
                        }
                    }
                    if allFound { exhausted.insert(matcher.id) }
                }
            }
            for section in sections {
                if let matchers = section.byExtension[ext] { run(matchers, in: section.name) }
                run(section.anyExtension, in: section.name)
            }
        }
        return Result(matches: found, deducedEngine: found.isEmpty ? nil : Self.deduceEngine(paths: paths, found: found))
    }

    // MARK: Second pass (a port of SteamDB's FileDetector::TryDeduceEngine)

    static func deduceEngine(paths: [String], found: [String: Set<String>]) -> String? {
        func has(_ evidence: String) -> Bool { found["Evidence"]?.contains(evidence) == true }
        let dosbox = found["Emulator"]?.contains("DOSBOX") == true
        let lime = found["Engine"]?.contains("Lime_OR_OpenFL") == true

        if has("ARC") && has("TAB") { return "ApexEngine" }
        if has("RPF") && has("METADATA_DAT") { return "RAGE" }
        if has("HDLL") && !lime { return "Heaps" }
        if dosbox {
            if has("Build") { return "Build" }
            if has("VSWAP") || (has("CFG") && has("WAD")) { return "idTech" }
        }
        // `.u` files only turn up in idTech0 and Unreal games; idTech0 was ruled out above.
        if has("U") && !dosbox { return "Unreal" }
        if has("BIF") && has("TLK") { return has("RIM") || has("TGA") ? "Aurora" : "Infinity" }
        // Any two of options.ini, data.win and snd_<name>.ogg make a GameMaker game.
        if [has("OPTIONS_INI"), has("DATA_WIN"), has("SND_OGG")].filter({ $0 }).count > 1 { return "GameMaker" }
        if has("SIERRA_EXE") && has("SCR") { return "SCI" }
        if has("PCK") && isGodot(paths) { return "Godot" }
        if has("PK3") { return "idTech" }
        return nil
    }

    /// Godot's .pck files are too generic to trust alone. Godot has either a single `data.pck` and no other .pck,
    /// or a .pck named like each program next to it (`Game.exe` + `Game.pck`).
    static func isGodot(_ paths: [String]) -> Bool {
        var packs: [String] = []
        var programs = Set<String>()                        // the .pck path each program would have
        for path in paths {
            var file = path.uppercased()
            let ext = fileExtension(of: file)
            if ext == "PCK" { packs.append(file); continue }
            if ext.isEmpty {                                // Mac and Linux programs have no extension
                if let slash = file.lastIndex(of: "/"), file[..<slash].hasSuffix("/MACOS") {
                    file = file.replacingOccurrences(of: "/MACOS/", with: "/RESOURCES/")    // the .pck is in Resources
                }
                programs.insert(file + ".PCK")
            } else if ["EXE", "X86", "X86_32", "X86_64"].contains(ext) {
                programs.insert(String(file.dropLast(ext.count)) + "PCK")
            }
        }
        guard !packs.isEmpty else { return false }
        var onlyDataPck = true
        for pack in packs {
            if pack.split(separator: "/", omittingEmptySubsequences: false).last != "DATA.PCK" { onlyDataPck = false }
            if programs.contains(pack) { return true }
        }
        return onlyDataPck
    }

    /// The text after the last dot of the file name ("" without one), like PHP's `pathinfo`.
    static func fileExtension(of path: String) -> String {
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dot)...])
    }

    // MARK: Compiling

    private struct Section {
        let name: String
        /// Matchers for rules that end in `\.ext$`, by lower-case extension.
        let byExtension: [String: [Matcher]]
        /// Matchers for every other rule; they run on every file.
        let anyExtension: [Matcher]
    }

    /// Rules that share a section, an extension and a way of starting, tried as one expression.
    private struct Matcher {
        let id: Int
        /// All the rules as one alternation without capture groups, which is fast to reject.
        let combined: NSRegularExpression
        let members: [Member]
    }

    private struct Member {
        let name: String
        let regex: NSRegularExpression
    }

    /// How a rule is anchored. Rules that start at a folder boundary share one `(?:^|/)`, so a path is only
    /// examined where a name begins; rules that start with `^` are only tried at the start.
    private enum Anchor: CaseIterable {
        case folder, start, loose

        static let folderPrefix = "(?:^|/)"

        func split(_ pattern: String) -> String? {
            switch self {
            case .folder: pattern.hasPrefix(Self.folderPrefix) ? String(pattern.dropFirst(Self.folderPrefix.count)) : nil
            case .start: pattern.hasPrefix("^") && !pattern.hasPrefix("^|") ? String(pattern.dropFirst()) : nil
            case .loose: pattern
            }
        }

        func combine(_ bodies: [String]) -> String {
            let alternatives = bodies.map { "(?:\($0))" }.joined(separator: "|")
            switch self {
            case .folder: return Self.folderPrefix + "(?:\(alternatives))"
            case .start: return "^(?:\(alternatives))"
            case .loose: return alternatives
            }
        }
    }

    /// `\.ext$` or `\.(?:ext1|ext2)$` at the end of a rule, as SteamDB detects simple extensions.
    private static let simpleExtension = try! NSRegularExpression(pattern: #"\\\.(?:(\w+)|\(\?:([\w|]+)\))\$$"#)

    public convenience init(iniText: String) {
        self.init(rules: Self.parse(iniText))
    }

    private init(rules: [ParsedRule]) {
        var counts: [String: Int] = [:]
        var rejected: [String] = []
        // section → extension ("" for none) → anchor → [(rule, body)]
        var grouped: [String: [String: [Anchor: [(ParsedRule, NSRegularExpression, String)]]]] = [:]
        var sectionOrder: [String] = []

        for rule in rules {
            counts[rule.section, default: 0] += 1
            // Rules must not have capture groups: nothing here reads them.
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]),
                  regex.numberOfCaptureGroups == 0,
                  let anchor = Anchor.allCases.first(where: { $0.split(rule.pattern) != nil }),
                  let body = anchor.split(rule.pattern) else { rejected.append("\(rule.section).\(rule.name)"); continue }
            if grouped[rule.section] == nil { sectionOrder.append(rule.section) }
            let lowered = rule.pattern.lowercased()
            let whole = NSRange(location: 0, length: lowered.utf16.count)
            var extensions = [""]
            if let hit = Self.simpleExtension.firstMatch(in: lowered, range: whole) {
                let single = hit.range(at: 1), multi = hit.range(at: 2)
                let list = single.location != NSNotFound ? (lowered as NSString).substring(with: single)
                                                         : (lowered as NSString).substring(with: multi)
                extensions = list.split(separator: "|").map(String.init)
            }
            for ext in extensions {
                grouped[rule.section, default: [:]][ext, default: [:]][anchor, default: []].append((rule, regex, body))
            }
        }

        var nextID = 0
        var sections: [Section] = []
        for name in sectionOrder {
            var byExtension: [String: [Matcher]] = [:]
            var anyExtension: [Matcher] = []
            for (ext, anchors) in grouped[name] ?? [:] {
                for anchor in Anchor.allCases {
                    guard let entries = anchors[anchor] else { continue }
                    // Longer rules first, as SteamDB does, so a short rule doesn't hide a long one.
                    let sorted = entries.enumerated().sorted {
                        $0.element.0.pattern.count != $1.element.0.pattern.count
                            ? $0.element.0.pattern.count > $1.element.0.pattern.count : $0.offset < $1.offset
                    }.map(\.element)
                    guard let combined = try? NSRegularExpression(pattern: anchor.combine(sorted.map(\.2)), options: [.caseInsensitive]) else {
                        rejected += sorted.map { "\($0.0.section).\($0.0.name)" }
                        continue
                    }
                    let matcher = Matcher(id: nextID, combined: combined,
                                          members: sorted.map { Member(name: $0.0.name, regex: $0.1) })
                    nextID += 1
                    if ext.isEmpty { anyExtension.append(matcher) } else { byExtension[ext, default: []].append(matcher) }
                }
            }
            sections.append(Section(name: name, byExtension: byExtension, anyExtension: anyExtension))
        }
        self.sections = sections
        self.ruleCounts = counts
        self.rejected = rejected
    }

    // MARK: INI

    struct ParsedRule {
        let section: String
        let name: String
        let pattern: String
    }

    /// Reads `[Section]` headers and `Name = regex` / `Name[] = regex` lines the way PHP's `parse_ini_file` does in
    /// raw mode: `;` starts a comment, quotes around a whole value are dropped, a repeated `Name[]` adds another
    /// rule for the same name and a repeated plain `Name` replaces the earlier one.
    static func parse(_ text: String) -> [ParsedRule] {
        var order: [(section: String, name: String)] = []
        var patterns: [String: [String]] = [:]              // "section\nname" → regexes
        var section = ""
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                section = String(line[line.index(after: line.startIndex)..<close])
                continue
            }
            guard let equals = line.firstIndex(of: "="), !section.isEmpty else { continue }
            var key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...]
            if let comment = value.firstIndex(of: ";") { value = value[..<comment] }
            var pattern = value.trimmingCharacters(in: .whitespaces)
            if pattern.count >= 2, let quote = pattern.first, quote == "\"" || quote == "'", pattern.last == quote {
                pattern = String(pattern.dropFirst().dropLast())
            }
            guard !key.isEmpty, !pattern.isEmpty else { continue }
            let isList = key.hasSuffix("[]")
            if isList { key = String(key.dropLast(2)) }
            let id = "\(section)\n\(key)"
            if patterns[id] == nil { order.append((section, key)) }
            if isList { patterns[id, default: []].append(pattern) } else { patterns[id] = [pattern] }
        }
        return order.flatMap { entry in
            (patterns["\(entry.section)\n\(entry.name)"] ?? []).map { ParsedRule(section: entry.section, name: entry.name, pattern: $0) }
        }
    }
}
