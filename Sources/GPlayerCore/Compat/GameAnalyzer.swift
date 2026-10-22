import Foundation

/// Works out what a game is from its files: the engine, anti-cheat and launchers from file names (SteamDB's
/// detection rules, see `DetectionRules`), the graphics APIs from the PE import tables, the CPU and .NET from the
/// PE headers. Reads folder listings and a few headers, never whole files. Safe to call on any thread; it never
/// throws, and anything it can't read is simply left out.
public enum GameAnalyzer {
    /// Files listed per game, and how many folders deep. The listing goes level by level, so the files
    /// near the top, which say the most, are always there.
    static let maxFiles = 30_000
    static let maxDepth = 8

    /// `gameFolder` is the folder that holds the whole game. Without it, it is the program's own folder, or the
    /// folder above when the program sits inside the engine's binaries folder (Unreal's `Binaries/Win64`).
    public static func analyze(executable: URL, gameFolder: URL? = nil) -> GameAnalysis {
        let exe = executable.standardizedFileURL
        let root = gameFolder?.standardizedFileURL ?? gameRoot(forExecutable: exe)
        let files = listFiles(in: root)
        let found = DetectionRules.shared.match(files)

        var analysis = GameAnalysis()
        analysis.programPath = exe.path
        analysis.version = GameAnalysis.currentVersion
        if let pick = engine(in: found) {
            analysis.engineName = pick.name
            analysis.engine = pick.engine
        }
        analysis.antiCheat = names(found.matches["AntiCheat"])
        analysis.launchers = names(found.matches["Launcher"])
        analysis.graphics = graphics(of: exe, root: root, files: files)
        analysis.neededComponents = neededComponents(of: exe, files: files)
        if let details = PEInfo.details(ofExecutableAt: exe) {
            analysis.architecture = details.architecture
            analysis.isDotNet = details.isDotNet
        }
        return analysis
    }

    // MARK: Engine

    /// Engines G-Player has defaults for, most likely first. When a game matches several, the first wins.
    static let knownEngines: [(rule: String, engine: KnownEngine)] = [
        ("Unreal", .unreal), ("Unity", .unity), ("Godot", .godot), ("Source2", .source2), ("Source", .source),
        ("GameMaker", .gameMaker), ("RPGMaker", .rpgMaker), ("RenPy", .renPy),
    ]

    /// The engine to go by. A known engine from the `Engine` rules wins, then an engine only the second pass
    /// guessed, then Electron or NW.js (the browser a game runs in matters more than the framework on top of it),
    /// then any other engine (the first by name).
    static func engine(in found: DetectionRules.Result) -> (name: String, engine: KnownEngine)? {
        let direct = found.matches["Engine"] ?? []
        for known in knownEngines where direct.contains(known.rule) { return (known.rule, known.engine) }
        if let guess = found.deducedEngine, let known = knownEngines.first(where: { $0.rule == guess }) {
            return (known.rule, known.engine)
        }
        if found.matches["Container"]?.contains("Electron") == true { return ("Electron", .electron) }
        if found.matches["SDK"]?.contains("NWJS") == true { return ("NWJS", .nwjs) }
        if let other = direct.sorted().first ?? found.deducedEngine { return (displayName(other), .other) }
        return nil
    }

    /// Rule names use `_` for spaces ("Adobe_AIR").
    static func displayName(_ rule: String) -> String {
        rule.replacingOccurrences(of: "_", with: " ")
    }

    private static func names(_ rules: Set<String>?) -> [String] {
        (rules ?? []).map(displayName).sorted()
    }

    // MARK: Runtime components

    /// The components the program and the DLLs next to it import, minus DLLs the game brings along itself (many games
    /// ship their own openal32.dll or msvcr100.dll).
    static func neededComponents(of exe: URL, files: [String]) -> [String] {
        let shipped = Set(files.map { ($0 as NSString).lastPathComponent.lowercased() })
        let folder = exe.deletingLastPathComponent()
        let neighbours = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "dll" }.prefix(200)
        var imported = Set<String>()
        for url in [exe] + neighbours {
            for dll in PEImports.importedDLLs(ofExecutableAt: url) ?? [] { imported.insert(dll.lowercased()) }
        }
        return components(forImports: imported, shipped: shipped)
    }

    /// Imported DLL names → components to install, leaving out DLLs the game ships and what G-Player won't install
    /// by itself.
    static func components(forImports imported: Set<String>, shipped: Set<String>) -> [String] {
        let ids = imported.map { $0.lowercased() }.filter { !shipped.contains($0) }
            .compactMap(RuntimeCatalog.component(forDLL:)).map(RuntimeCatalog.canonicalID)
            .filter(RuntimeCatalog.installsByItself)
        return Array(Set(ids)).sorted()
    }

    // MARK: Graphics

    /// Graphics APIs from the program's imports, the engine runtime that holds the renderer, and the files.
    /// Games rarely import Direct3D in the .exe itself: a Unity .exe only starts `UnityPlayer.dll`, and an
    /// Unreal game starts from a small launcher while `…-Shipping.exe` holds the engine.
    static func graphics(of exe: URL, root: URL, files: [String]) -> [GraphicsAPI] {
        var apis = Set<GraphicsAPI>()
        func add(importsOf url: URL) {
            for dll in PEImports.importedDLLs(ofExecutableAt: url) ?? [] {
                if let api = graphicsAPI(forDLL: dll) { apis.insert(api) }
            }
        }
        add(importsOf: exe)
        let folder = relativeFolder(of: exe, in: root)
        if let player = nearest(files, to: folder, where: { $0.lowercased() == "unityplayer.dll" }) {
            add(importsOf: root.appendingPathComponent(player))
        }
        if !exe.lastPathComponent.lowercased().hasSuffix("-shipping.exe"),
           let shipping = nearest(files.filter { !$0.lowercased().hasPrefix("engine/") }, to: folder,
                                  where: { $0.lowercased().hasSuffix("-shipping.exe") }) {
            add(importsOf: root.appendingPathComponent(shipping))
        }
        // The DirectX 12 runtime ships next to games that can use it, whatever the .exe imports.
        if files.contains(where: { lastComponent($0).lowercased() == "d3d12core.dll" }) { apis.insert(.d3d12) }
        return apis.sorted()
    }

    /// The API a DLL belongs to. `dxgi.dll` is shared by Direct3D 10 to 12 and says nothing on its own.
    static func graphicsAPI(forDLL name: String) -> GraphicsAPI? {
        switch name {
        case "d3d8.dll": .d3d8
        case "d3d9.dll": .d3d9
        case "d3d11.dll": .d3d11
        case "d3d12.dll": .d3d12
        case "opengl32.dll": .opengl
        case "vulkan-1.dll": .vulkan
        default: name.hasPrefix("d3d10") && name.hasSuffix(".dll") ? .d3d10 : nil
        }
    }

    /// The folder of `exe` inside `root` as a relative path ("" for the root), or nil when it isn't inside.
    private static func relativeFolder(of exe: URL, in root: URL) -> String? {
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let folder = exe.deletingLastPathComponent().path + "/"
        guard folder.hasPrefix(base) else { return nil }
        return String(folder.dropFirst(base.count).dropLast())
    }

    /// The listed file that passes `test` (given its file name) and sits in `folder`, or else the one nearest the top.
    private static func nearest(_ files: [String], to folder: String?, where test: (String) -> Bool) -> String? {
        let candidates = files.filter { test(lastComponent($0)) }
        if let folder, let same = candidates.first(where: { parent(of: $0) == folder }) { return same }
        return candidates.min { a, b in
            let (x, y) = (a.split(separator: "/").count, b.split(separator: "/").count)
            return x != y ? x < y : a < b
        }
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
    }

    private static func parent(of path: String) -> String {
        path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
    }

    // MARK: Game folder

    /// The program's folder, or the folder two or three levels above it that has the whole game when the program
    /// sits inside engine binaries: `Game/Binaries/Win64/Game-Win64-Shipping.exe` under a folder with `Engine`, or a
    /// program under a folder with a Unity `<Name>_Data` folder. One level up is never taken: that is where a
    /// library of games would be.
    static func gameRoot(forExecutable exe: URL) -> URL {
        let start = exe.deletingLastPathComponent()
        if isGameRoot(start) { return start }
        var folder = start
        for level in 1...3 {
            let up = folder.deletingLastPathComponent()
            if up.path == folder.path { break }                                    // reached "/"
            folder = up
            if level >= 2, isGameRoot(folder) { return folder }
        }
        return start
    }

    private static let unityMarkers = ["globalgamemanagers", "data.unity3d", "app.info", "Managed", "il2cpp_data", "level0"]

    private static func isGameRoot(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        for entry in entries {
            let name = entry.lowercased()
            if name == "engine", ["Binaries", "Content", "Config"].contains(where: {
                fm.fileExists(atPath: folder.appendingPathComponent(entry).appendingPathComponent($0).path)
            }) { return true }
            if name.hasSuffix("_data"), unityMarkers.contains(where: {
                fm.fileExists(atPath: folder.appendingPathComponent(entry).appendingPathComponent($0).path)
            }) { return true }
        }
        return false
    }

    // MARK: Files

    private static let junkFolders: Set<String> = ["__macosx", "$recycle.bin", "system volume information", "node_modules",
                                                   "steamapps"]          // other games, when the program is Steam itself
    private static let junkFiles: Set<String> = ["thumbs.db", "desktop.ini"]

    /// Relative paths (with `/`) of the files under `root`, folder level by folder level, without hidden files,
    /// links, and folders of other things (`node_modules`, Steam's `steamapps`…).
    static func listFiles(in root: URL, maxFiles: Int = maxFiles, maxDepth: Int = maxDepth) -> [String] {
        var files: [String] = []
        var level = [""]                                                           // folders at this depth, relative
        var depth = 1
        while !level.isEmpty, depth <= maxDepth {
            var next: [String] = []
            for folder in level {
                guard let dir = opendir(folder.isEmpty ? root.path : root.path + "/" + folder) else { continue }
                defer { closedir(dir) }
                while let entry = readdir(dir) {
                    let name = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                    }
                    if name.hasPrefix(".") { continue }
                    let path = folder.isEmpty ? name : folder + "/" + name
                    var type = Int32(entry.pointee.d_type)
                    if type == DT_UNKNOWN {                                       // some network shares don't say
                        var info = stat()
                        if lstat(root.path + "/" + path, &info) == 0 {
                            type = info.st_mode & S_IFMT == S_IFDIR ? DT_DIR : info.st_mode & S_IFMT == S_IFREG ? DT_REG : DT_LNK
                        }
                    }
                    if type == DT_DIR {
                        if !junkFolders.contains(name.lowercased()) { next.append(path) }
                    } else if type == DT_REG, !junkFiles.contains(name.lowercased()) {
                        files.append(path)
                        if files.count >= maxFiles { return files }
                    }
                }
            }
            level = next
            depth += 1
        }
        return files
    }
}
