import Foundation

/// What "Share What Worked" says about a game that runs well: the Mac, the engine, the graphics, the settings and what the
/// game is, as `Key: value` lines. It is built here, from plain values, so what may leave the app is decided in one place
/// and tests can check it. It never holds the game's name or anything that points at the user's files: no paths, no user
/// name, no logs, and no store IDs unless asked for.
public struct WorkedReport: Sendable, Equatable {
    public var lines: [String]
    public var text: String { lines.joined(separator: "\n") }

    /// What the app and the Mac say about themselves. No serial number, model identifier or name.
    public struct Machine: Sendable, Equatable {
        public var appVersion: String
        /// "15.4" or "15.4.1".
        public var macOSVersion: String
        /// "Apple M2 Pro". Nil when the Mac gives nothing that looks like a chip name.
        public var chip: String?

        public init(appVersion: String, macOSVersion: String, chip: String? = nil) {
            self.appVersion = appVersion; self.macOSVersion = macOSVersion; self.chip = chip
        }

        public static func current() -> Machine {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return Machine(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build",
                           macOSVersion: osVersion(version.majorVersion, version.minorVersion, version.patchVersion),
                           chip: chipFamily(from: brandString()))
        }

        static func osVersion(_ major: Int, _ minor: Int, _ patch: Int) -> String {
            "\(major).\(minor)" + (patch > 0 ? ".\(patch)" : "")
        }

        /// The chip family from the CPU brand string: only a plain "Apple M2 Pro", never a clock speed or anything else.
        public static func chipFamily(from brand: String?) -> String? {
            guard let brand = brand?.trimmingCharacters(in: .whitespacesAndNewlines), brand.hasPrefix("Apple "), brand.count <= 40,
                  brand.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == " " }) else { return nil }
            return brand
        }

        /// `sysctl machdep.cpu.brand_string`.
        private static func brandString() -> String? {
            var size = 0
            guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
    }

    /// What must never reach a report: the user's home folder and the names they go by.
    public struct Redaction: Sendable, Equatable {
        public var homeFolder: String
        public var names: [String]

        public init(homeFolder: String, names: [String]) { self.homeFolder = homeFolder; self.names = names }

        /// This user: the home folder, the account name, the home folder's own name and the full name.
        public static var current: Redaction {
            let home = NSHomeDirectory()
            var names: [String] = []
            for name in [NSUserName(), (home as NSString).lastPathComponent, NSFullUserName()]
            where !name.isEmpty && !names.contains(name) {
                names.append(name)
            }
            return Redaction(homeFolder: home, names: names)
        }

        /// `text` points at a file (a path always has a separator, the home folder's included) or holds one of the names.
        func hides(_ text: String) -> Bool {
            text.contains("/") || text.contains("\\")
                || names.contains { !$0.isEmpty && text.range(of: $0, options: .caseInsensitive) != nil }
        }

        /// Text the user typed, with their home folder written as "~".
        func scrubbing(_ text: String) -> String {
            homeFolder.count > 1 ? text.replacingOccurrences(of: homeFolder, with: "~") : text
        }
    }

    /// A game that has run well: Automatic wrote its graphics down as working, or it has been played for as long as that
    /// takes (`GraphicsRetry.secondsToWork`). Games Automatic doesn't learn from (Compatible, Custom, Epic) count by play time.
    public static func mayShare(_ game: Game) -> Bool {
        game.kind == .game && (game.autoGraphics?.worked != nil || game.secondsPlayed >= GraphicsRetry.secondsToWork)
    }

    /// `PEArchitecture.displayName` in English: the report is English whatever the app's language.
    private static func englishName(_ architecture: PEArchitecture) -> String {
        switch architecture {
        case .x86: "32-bit"
        case .x64: "64-bit"
        case .arm64: "ARM64"
        case .other: "Unknown"
        }
    }

    /// The graphics that worked, never Automatic: what Automatic learned on this engine when it did, else what a launch uses
    /// now (`planned`, the profile's pick), resolved on the engine.
    public static func workedBackend(of game: Game, on engine: EngineInfo, planned: GraphicsBackend) -> GraphicsBackend {
        if game.graphicsAreAutomatic, let worked = game.autoGraphics?.current(on: engine.id).worked { return worked }
        return engine.resolve(planned)
    }

    /// - Parameters:
    ///   - planned: the backend a launch would use now (`CompatPlan.backend`).
    ///   - components: Windows components in the game's space beyond the ones every space gets.
    ///   - includesSteamAppID: the user ticked the box. Nothing else about a store game's identity is ever included.
    public init(game: Game, engine: EngineInfo, planned: GraphicsBackend, components: [String], machine: Machine,
                redaction: Redaction, includesSteamAppID: Bool = false) {
        var lines = ["G-Player: \(machine.appVersion)", "macOS: \(machine.macOSVersion)"]
        if let chip = machine.chip { lines.append("Mac: \(chip)") }
        lines.append("Engine: \(engine.englishName)")
        lines.append("Engine ID: \(engine.id)")
        let backend = Self.workedBackend(of: game, on: engine, planned: planned)
        lines.append("Graphics backend: \(backend == .auto ? "Automatic" : backend.displayName)")      // English: the others are product names
        let options = game.launchOptions
        lines.append("Profile: \(options.profile.effective(on: engine).rawValue.capitalized)")
        var switches: [String] = []
        switch options.windowMode {
        case .windowed: switches.append("windowed")
        case .fullscreen: switches.append("fullscreen")
        case .automatic: break
        }
        if options.retina { switches.append("Retina") }
        // Only how many: a fix's id can hold a Steam app ID.
        if !options.useKnownFixes {
            switches.append("known fixes off")
        } else if !options.disabledFixIDs.isEmpty {
            let count = options.disabledFixIDs.count
            switches.append("\(count) known fix\(count == 1 ? "" : "es") off")
        }
        if !switches.isEmpty { lines.append("Options: " + switches.joined(separator: ", ")) }
        let arguments = game.arguments.filter { !$0.isEmpty }
            .map { redaction.hides($0) ? "(hidden)" : Self.oneLine($0) }
        if !arguments.isEmpty { lines.append("Arguments: " + arguments.joined(separator: " ")) }
        let variables = game.environment.sorted { $0.key < $1.key }
            .filter { Self.isName($0.key) && !redaction.hides($0.key) }
            .map { redaction.hides($0.value) ? "\($0.key)=…(hidden)" : "\($0.key)=\(Self.oneLine($0.value))" }
        if !variables.isEmpty { lines.append("Environment: " + variables.joined(separator: ", ")) }
        let extras = Set(components.filter(Self.isName)).sorted()
        if !extras.isEmpty { lines.append("Windows components: " + extras.joined(separator: ", ")) }
        if let a = game.analysis {
            if let name = a.engineName { lines.append("Game engine: \(name)") }
            if let graphics = a.graphicsLabel { lines.append("Game graphics: \(graphics)") }
            let program = [a.architecture.map(Self.englishName), a.isDotNet ? ".NET" : nil].compactMap { $0 }
            if !program.isEmpty { lines.append("Game program: " + program.joined(separator: ", ")) }
        }
        switch game.source {
        case .steam(let appID):
            lines.append("Store: Steam")
            if includesSteamAppID, !appID.isEmpty, appID.allSatisfy({ $0.isASCII && $0.isNumber }) {
                lines.append("Steam app ID: \(appID)")
            }
        case .epic, .legendary:
            lines.append("Store: Epic")
        case .executable:
            lines.append("Store: Added .exe")
            let launchers = game.analysis?.launchers.map { $0.replacingOccurrences(of: "_", with: " ") } ?? []
            if !launchers.isEmpty { lines.append("Launchers: " + launchers.joined(separator: ", ")) }
        }
        self.lines = lines
    }

    /// An environment variable, component or similar: a plain name, never a path or a sentence.
    static func isName(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    /// One short line: line breaks become spaces, backticks apostrophes (they would end the code block of the Markdown
    /// copy), and a long value is cut.
    static func oneLine(_ text: String, limit: Int = 100) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ").replacingOccurrences(of: "`", with: "'")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
