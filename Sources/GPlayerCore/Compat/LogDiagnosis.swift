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
    /// Windows DLL → the runtime component that provides it.
    static let componentForDLL: [(prefix: String, component: String)] = [
        ("msvcp140", "vcrun2022"), ("vcruntime140", "vcrun2022"), ("concrt140", "vcrun2022"), ("vcomp140", "vcrun2022"),
        ("mfc140", "mfc140"),
        ("msvcp120", "vcrun2013"), ("msvcr120", "vcrun2013"),
        ("msvcp110", "vcrun2012"), ("msvcr110", "vcrun2012"),
        ("msvcp100", "vcrun2010"), ("msvcr100", "vcrun2010"),
        ("msvcp90", "vcrun2008"), ("msvcr90", "vcrun2008"),
        ("d3dx9_", "d3dx9"), ("d3dx10_", "d3dx10"), ("d3dx11_", "d3dx11_43"),
        ("d3dcompiler_43", "d3dcompiler_43"), ("d3dcompiler_47", "d3dcompiler_47"),
        ("xinput1_", "xinput"), ("xaudio2_", "xact"), ("x3daudio1_", "xact"), ("xactengine", "xact"),
        ("physxloader", "physx"), ("physx3", "physx"), ("physxcudart", "physx"),
        ("openal32", "openal"), ("mscoree", "dotnet48"), ("xnafx40", "xna40"),
    ]

    static let graphicsFailures = [
        "failed to create d3d11 device", "failed to create d3d12 device", "d3d11createdevice failed",
        "initializeenginegraphics failed", "failed to initialize player", "unable to create direct3d device",
        "dx11 feature level 10.0 is required", "a d3d11-compatible gpu", "failed to create the d3d device",
        "could not create direct3d", "vkcreateinstance failed", "unable to initialize vulkan",
    ]
    static let antiCheatFailures = ["easyanticheat", "easy anti-cheat", "battleye", "be_service", "vanguard"]

    /// - Parameters:
    ///   - log: the launch log text (only the last part is needed; pass up to a few hundred KB).
    ///   - exitStatus: the Wine process's exit status.
    ///   - seconds: how long the game ran.
    ///   - profile: the profile it ran with, so the advice moves on to the next one.
    public static func diagnose(log: String, exitStatus: Int32, seconds: Double, profile: LaunchProfile) -> [Diagnosis] {
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
            componentForDLL.first { dll.hasPrefix($0.prefix) }?.component
        })).sorted()
        if !components.isEmpty {
            let dlls = Array(Set(missing)).sorted().prefix(4).joined(separator: ", ")
            results.append(Diagnosis(kind: .missingComponent, title: "Missing Windows components",
                                     detail: "The game needs \(dlls), which isn't in this space.",
                                     remedy: .installComponents(components)))
        } else if !missing.isEmpty {
            let dlls = Array(Set(missing)).sorted().prefix(4).joined(separator: ", ")
            results.append(Diagnosis(kind: .missingComponent, title: "A file the game needs is missing",
                                     detail: "Wine couldn't find \(dlls). Reinstalling the game or adding the file next to its .exe can help.",
                                     remedy: .none))
        }

        if antiCheatFailures.contains(where: lower.contains) && seconds < 60 {
            results.append(Diagnosis(kind: .antiCheat, title: "Anti-cheat stopped the game",
                                     detail: "Kernel anti-cheat doesn't run under Wine on macOS. Online modes won't work.",
                                     remedy: .none))
        }

        if graphicsFailures.contains(where: lower.contains) {
            results.append(Diagnosis(kind: .graphics, title: "Graphics didn't start",
                                     detail: "The game couldn't create its graphics device.",
                                     remedy: profile == .compatible ? .none : .useProfile(.compatible)))
        }

        let crashed = lower.contains("unhandled page fault") || lower.contains("unhandled exception")
            || lower.contains("caused an access violation")
        if results.isEmpty && crashed {
            results.append(Diagnosis(kind: .crash, title: "The game crashed",
                                     detail: "Wine reported a crash while the game was starting.",
                                     remedy: profile == .compatible ? .none : .useProfile(.compatible)))
        }

        if results.isEmpty && seconds < 15 && exitStatus != 0 {
            results.append(Diagnosis(kind: .closedRightAway, title: "The game closed right away",
                                     detail: "It quit after \(Int(seconds)) seconds without saying why.",
                                     remedy: profile == .compatible ? .none : .useProfile(.compatible)))
        }
        return results
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
