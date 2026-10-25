import Foundation

/// What went wrong in a launch, in words, with the one thing to try next.
public struct Diagnosis: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case missingComponent, graphics, antiCheat, crash, closedRightAway }
    public enum Remedy: Hashable, Sendable {
        case installComponents([String])
        case useProfile(LaunchProfile)
        case none
    }

    public var id: String { kind.rawValue + title }
    public let kind: Kind
    public let title: String
    public let detail: String
    public let remedy: Remedy

    public init(kind: Kind, title: String, detail: String, remedy: Remedy) {
        self.kind = kind; self.title = title; self.detail = detail; self.remedy = remedy
    }
}

/// Reads a launch log (G-Player's header plus Wine's output) after a game quits.
public enum LogDiagnosis {
    static let graphicsFailures = [
        "failed to create device and context",
        "failed to create d3d11 device", "failed to create d3d12 device", "d3d11createdevice failed",
        "initializeenginegraphics failed", "failed to initialize player", "unable to create direct3d device",
        "dx11 feature level 10.0 is required", "a d3d11-compatible gpu", "failed to create the d3d device",
        "could not create direct3d", "vkcreateinstance failed", "unable to initialize vulkan",
        // Unity's Player.log, when its graphics don't start: "d3d11: failed to create device (80004005)" and the line
        // after it (the first one is also written with "and context", which the entry above has).
        "d3d11: failed to create device", "failed to initialize graphics",
    ]
    static let antiCheatFailures = ["easyanticheat", "easy anti-cheat", "battleye", "be_service", "vanguard"]

    /// - Parameters:
    ///   - log: the launch log text (only the last part is needed; pass up to a few hundred KB).
    ///   - exitStatus: the Wine process's exit status.
    ///   - seconds: how long the game ran.
    ///   - profile: the profile it ran with, so the advice moves on to the next one.
    ///   - installed: the components already in the space, so the common set is offered only while some are missing.
    public static func diagnose(log: String, exitStatus: Int32, seconds: Double, profile: LaunchProfile,
                                installed: Set<String> = []) -> [Diagnosis] {
        let lower = withoutHeader(log).lowercased()
        var results: [Diagnosis] = []

        // err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\…\\Game.exe") not found
        var missing: [String] = []
        for line in lower.split(separator: "\n") where line.contains("import_dll") && line.contains("not found") {
            if let r = line.range(of: "library "), let end = line[r.upperBound...].firstIndex(of: " ") {
                missing.append(String(line[r.upperBound..<end]))
            }
        }
        let components = Array(Set(missing.compactMap { dll in
            RuntimeCatalog.component(forDLL: dll)
        })).sorted()
        if !components.isEmpty {
            let dlls = Array(Set(missing)).sorted().prefix(4).joined(separator: ", ")
            results.append(Diagnosis(kind: .missingComponent, title: String(localized: "Missing Windows components"),
                                     detail: String(localized: "The game needs \(dlls), which isn't in this space."),
                                     remedy: .installComponents(components)))
        } else if !missing.isEmpty {
            let dlls = Array(Set(missing)).sorted().prefix(4).joined(separator: ", ")
            results.append(Diagnosis(kind: .missingComponent, title: String(localized: "A file the game needs is missing"),
                                     detail: String(localized: "Wine couldn't find \(dlls). Reinstalling the game or adding the file next to its .exe can help."),
                                     remedy: .none))
        }

        if antiCheatFailures.contains(where: lower.contains) && seconds < 60 {
            results.append(Diagnosis(kind: .antiCheat, title: String(localized: "Anti-cheat stopped the game"),
                                     detail: String(localized: "Kernel anti-cheat doesn't run under Wine on macOS. Online modes won't work."),
                                     remedy: .none))
        }

        if graphicsFailures.contains(where: lower.contains) {
            // MoltenVK before 1.4.1 refuses the host-memory buffers and images Wine makes for 32-bit programs. (Newer
            // ones still have a similar vkAllocateMemory message, "handle types", which means something else.)
            if lower.contains("vkcreatebuffer(): only external memory handle type ")
                || lower.contains("vkcreateimage(): only external memory handle type ") {
                results.append(Diagnosis(kind: .graphics, title: String(localized: "This engine can't run 32-bit DirectX 11"),
                                         detail: CompatResolver.oldMoltenVK, remedy: .none))
            } else {
                results.append(Diagnosis(kind: .graphics, title: String(localized: "Graphics didn't start"),
                                         detail: String(localized: "The game couldn't create its graphics device."),
                                         remedy: profile == .compatible ? .none : .useProfile(.compatible)))
            }
        }

        let crashed = lower.contains("unhandled page fault") || lower.contains("unhandled exception")
            || lower.contains("caused an access violation")
        if results.isEmpty && crashed {
            results.append(Diagnosis(kind: .crash, title: String(localized: "The game crashed"),
                                     detail: String(localized: "Wine reported a crash while the game was starting."),
                                     remedy: nextStep(profile: profile, installed: installed)))
        }

        if results.isEmpty && seconds < 15 && exitStatus != 0 {
            results.append(closedRightAway(seconds: seconds, profile: profile, installed: installed))
        }
        return results
    }

    /// The newest Unity `Player.log` in the space written since `since` by the game in `gameFolder`: a Unity game started by
    /// Steam writes its log there (AppData/LocalLow/<company>/<product>), while its console output goes to Steam. Other
    /// Unity games write there too, so a log counts only if its first lines name the game's folder. Nil without a folder.
    public static func unityLog(in space: Space, gameFolder: URL?, since: Date) -> URL? {
        guard let gameFolder else { return nil }
        let fm = FileManager.default
        let users = space.driveC.appendingPathComponent("users", isDirectory: true)
        var best: (URL, Date)?
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            let low = user.appendingPathComponent("AppData/LocalLow", isDirectory: true)
            for company in (try? fm.contentsOfDirectory(at: low, includingPropertiesForKeys: nil)) ?? [] {
                for product in (try? fm.contentsOfDirectory(at: company, includingPropertiesForKeys: nil)) ?? [] {
                    let log = product.appendingPathComponent("Player.log")
                    guard let date = (try? fm.attributesOfItem(atPath: log.path))?[.modificationDate] as? Date,
                          date >= since, date > (best?.1 ?? .distantPast),
                          unityLog(head(of: log), belongsToGameIn: gameFolder, in: space) else { continue }
                    best = (log, date)
                }
            }
        }
        return best?.0
    }

    /// True when the start of a Unity `Player.log` names the folder of the game in `folder`: "Mono path[0] =
    /// 'C:/…/Game/Game_Data/Managed'", or any other path under it (IL2CPP games have no Mono path, but name their data
    /// folder just as well). A folder whose name only starts the same ("Game 2") doesn't count.
    public static func unityLog(_ head: String, belongsToGameIn folder: URL, in space: Space) -> Bool {
        func slashed(_ text: String) -> String { text.replacingOccurrences(of: "\\", with: "/").lowercased() }
        var path = slashed(space.windowsPath(for: folder))
        while path.hasSuffix("/") { path.removeLast() }
        return !path.isEmpty && slashed(head).contains(path + "/")
    }

    /// The first 16 KB of a file: where Unity writes the paths it was started with.
    static func head(of url: URL, bytes: Int = 16_384) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        return String(decoding: (try? h.read(upToCount: bytes)) ?? Data(), as: UTF8.self)
    }

    /// A game that quit within seconds without a log that says why (a store game's output goes to its launcher, so
    /// G-Player only sees it come and go).
    public static func closedRightAway(seconds: Double, profile: LaunchProfile, installed: Set<String>) -> Diagnosis {
        Diagnosis(kind: .closedRightAway, title: String(localized: "The game closed right away"),
                  detail: String(localized: "It quit after \(max(1, Int(seconds))) seconds without saying why."),
                  remedy: nextStep(profile: profile, installed: installed))
    }

    /// `found` with the graphics that were tried said in the first diagnosis, for a launch that ran out of backends.
    /// Nothing is added when only one was tried: there is nothing to tell then.
    public static func mentioning(tried: [GraphicsBackend], in found: [Diagnosis]) -> [Diagnosis] {
        guard tried.count > 1, let first = found.first else { return found }
        var result = found
        result[0] = Diagnosis(kind: first.kind, title: first.title,
                              detail: first.detail + " " + String(localized: "Graphics tried: \(CompatResolver.list(tried.map(\.displayName)))."),
                              remedy: first.remedy)
        return result
    }

    /// What to try when nothing says what went wrong: the common runtimes first (they are cheap and often the cause),
    /// then the Compatible profile.
    static func nextStep(profile: LaunchProfile, installed: Set<String>) -> Diagnosis.Remedy {
        let missing = RuntimeCatalog.commonSet.filter { !installed.contains($0) }
        if !missing.isEmpty { return .installComponents(missing) }
        return profile == .compatible ? .none : .useProfile(.compatible)
    }

    /// The log without G-Player's own header. `WineLauncher.start` begins every log with "G-Player launch", the engine, the
    /// space, the backend, the command line and the DLL overrides, then an empty line. Those lines hold paths and titles
    /// the user chose, so a game called "BattlEye Tester" must not look like an anti-cheat failure. The header is the lines
    /// up to the first empty line, when every one of them is a line G-Player writes; text that doesn't start that way (the
    /// tail of a long log, or a log from elsewhere) is returned as it is, empty lines and all.
    static func withoutHeader(_ log: String) -> Substring {
        var rest = log[...]
        var headerLines = 0
        while !rest.isEmpty {
            let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            let line = rest[rest.startIndex..<end]
            rest = end == rest.endIndex ? "" : rest[rest.index(after: end)...]
            if line.isEmpty { return headerLines > 0 ? rest : log[...] }                          // the empty line that ends the header
            guard headerPrefixes.contains(where: line.hasPrefix) else { return log[...] }
            headerLines += 1
        }
        return headerLines > 0 ? "" : log[...]                                                   // a header and nothing else
    }

    /// How the lines of G-Player's header start (`WineLauncher.start`).
    static let headerPrefixes = ["G-Player launch", "engine:", "space:", "backend:", "command:", "WINEDLLOVERRIDES="]

    /// The last `bytes` of a log file, decoded leniently.
    public static func tail(of url: URL, bytes: Int = 400_000) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
