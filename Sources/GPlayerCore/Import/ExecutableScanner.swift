import Foundation

/// A Windows program found in a folder, with a guess at how likely it is to be "the game".
public struct ExecutableCandidate: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let score: Int
    /// Short reason shown next to the best guess ("Unity game", "Same name as the folder").
    public let hint: String?

    public var name: String { url.lastPathComponent }

    public init(url: URL, size: Int64, score: Int, hint: String?) {
        self.url = url; self.size = size; self.score = score; self.hint = hint
    }
}

public enum ExecutableScanner {
    /// Helpers that are almost never what the user wants to start.
    static let helperWords = ["unins", "uninstall", "vcredist", "vc_redist", "dxsetup", "dxwebsetup", "directx",
                              "crashhandler", "crashreport", "crashpad", "crash_reporter", "unitycrashhandler",
                              "ue4prereq", "ueprereq", "prereq", "redist", "dotnet", "ndp4", "physx", "easyanticheat",
                              "battleye", "be_service", "cefsharp", "notification_helper", "webhelper", "_real.exe",
                              "elevate", "updater", "dxdiag", "oalinst", "xnafx", "touchup", "quicksfv", "7z", "unrar"]
    static let installerWords = ["setup", "install", "installer"]

    public static func isHelper(_ name: String) -> Bool {
        let n = name.lowercased()
        return helperWords.contains { n.contains($0) }
    }

    public static func isInstallerName(_ name: String) -> Bool {
        let n = name.lowercased()
        return installerWords.contains { n.contains($0) } && !n.contains("uninstall")
    }

    /// Every .exe under `folder`, best guess first. Skips Wine's own `windows` folder.
    public static func scan(_ folder: URL, title: String? = nil, maxDepth: Int = 6) -> [ExecutableCandidate] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                         options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        let base = folder.standardizedFileURL.pathComponents.count
        var found: [ExecutableCandidate] = []
        for case let url as URL in walker {
            let depth = url.standardizedFileURL.pathComponents.count - base
            if Files.isDirectory(url) {
                let n = url.lastPathComponent.lowercased()
                if depth >= maxDepth || (depth == 1 && n == "windows") || n == "__macosx" { walker.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            found.append(rate(url, root: folder, depth: depth, title: title ?? folder.lastPathComponent))
        }
        return found.sorted { $0.score != $1.score ? $0.score > $1.score : $0.size > $1.size }
    }

    static func rate(_ url: URL, root: URL, depth: Int, title: String) -> ExecutableCandidate {
        let fm = FileManager.default
        let name = url.deletingPathExtension().lastPathComponent
        let lower = name.lowercased()
        let dir = url.deletingLastPathComponent()
        let size = Files.size(of: url)
        var score = 0
        var hint: String?

        if isHelper(url.lastPathComponent) { score -= 100 }
        if isInstallerName(lower) { score -= 40 }
        score -= depth * 4
        score += min(30, Int(size / 3_000_000))                     // bigger binaries tend to be the game

        if fm.fileExists(atPath: dir.appendingPathComponent("\(name)_Data").path) {
            score += 60; hint = String(localized: "Unity game")
        } else if lower.hasSuffix("-shipping") || lower.hasSuffix("-win64-shipping") {
            score += 25; hint = String(localized: "Unreal Engine game")
        } else if fm.fileExists(atPath: dir.appendingPathComponent("resources/app").path)
                    || fm.fileExists(atPath: dir.appendingPathComponent("resources/app.asar").path) {
            score += 45; hint = String(localized: "Electron game")
        } else if fm.fileExists(atPath: dir.appendingPathComponent("www/js").path)
                    || fm.fileExists(atPath: dir.appendingPathComponent("package.nw").path) {
            score += 45; hint = String(localized: "RPG Maker game")
        }
        let simpleTitle = simplify(title)
        if !simpleTitle.isEmpty, simplify(name) == simpleTitle || simpleTitle.hasPrefix(simplify(name)) && name.count > 3 {
            score += 35; hint = hint ?? String(localized: "Same name as the game")
        }
        if ["game", "start", "play", "launcher"].contains(lower) { score += 15 }
        if lower.contains("launcher") { score += 5 }
        if depth == 1 { score += 10 }
        return ExecutableCandidate(url: url, size: size, score: score, hint: hint)
    }

    static func simplify(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// True when a folder looks like an installer rather than a ready game: few programs, one of them a setup.
    public static func looksLikeInstaller(_ folder: URL) -> URL? {
        let exes = scan(folder, maxDepth: 2)
        let setups = exes.filter { isInstallerName($0.name) }
        let realGames = exes.filter { !isInstallerName($0.name) && !isHelper($0.name) }
        if let setup = setups.max(by: { $0.size < $1.size }), realGames.count <= 1 { return setup.url }
        return nil
    }
}

extension ExecutableCandidate {
    /// Chromium-based games (Electron, NW.js) need the same flags as Steam's helper to draw under Wine.
    public static func chromiumArguments(for exe: URL) -> [String] {
        let dir = exe.deletingLastPathComponent(), fm = FileManager.default
        let isChromium = fm.fileExists(atPath: dir.appendingPathComponent("resources/app").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("resources/app.asar").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("chrome_100_percent.pak").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("nw.pak").path)
        return isChromium ? ["--no-sandbox", "--in-process-gpu", "--disable-gpu-sandbox"] : []
    }
}
