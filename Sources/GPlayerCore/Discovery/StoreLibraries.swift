import Foundation

/// A game a store installed inside a space.
public struct StoreGame: Sendable, Hashable {
    public let source: Game.Source
    public let title: String
    public let installed: Bool
    public let installFolder: URL?
}

/// Reads Steam's own files inside a space: library folders and `appmanifest_<id>.acf`.
public enum SteamLibrary {
    static let ignoredAppIDs: Set<String> = ["228980"]          // Steamworks Common Redistributables
    static let ignoredPrefixes = ["Steamworks", "Proton", "Steam Linux Runtime", "SteamVR"]

    public static func steamFolder(in space: Space) -> URL {
        space.driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
    }

    public static func coverURL(appID: String) -> URL? {
        URL(string: "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/\(appID)/library_600x900.jpg")
    }

    /// The Steam client finished its first download (UI and helper present), so `-noverifyfiles` is safe.
    public static func isClientReady(in space: Space) -> Bool {
        let fm = FileManager.default, dir = steamFolder(in: space)
        let core = fm.fileExists(atPath: dir.appendingPathComponent("steamclient64.dll").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("steamclient.dll").path)
        let ui = fm.fileExists(atPath: dir.appendingPathComponent("clientui").path)
        let helpers = ChromiumHelperWrapper.expand("Program Files (x86)/Steam/bin/cef/cef.*/steamwebhelper.exe", in: space.driveC)
        return core && ui && !helpers.isEmpty
    }

    public static func libraryFolders(in space: Space) -> [URL] {
        let steamapps = steamFolder(in: space).appendingPathComponent("steamapps")
        var dirs = [steamapps]
        if let text = try? String(contentsOf: steamapps.appendingPathComponent("libraryfolders.vdf"), encoding: .utf8),
           let root = try? VDF.parse(text) {
            for (_, folder) in root["libraryfolders"]?.entries ?? [] {
                if let p = folder["path"]?.string, let url = space.macURL(forWindowsPath: p) {
                    dirs.append(url.appendingPathComponent("steamapps"))
                }
            }
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public static func scan(_ space: Space) -> [StoreGame] {
        var games: [StoreGame] = []
        for dir in libraryFolders(in: space) {
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                if let text = try? String(contentsOf: file, encoding: .utf8), let g = parseManifest(text, steamapps: dir) {
                    games.append(g)
                }
            }
        }
        return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public static func parseManifest(_ text: String, steamapps: URL) -> StoreGame? {
        guard let state = (try? VDF.parse(text))?["AppState"], let id = state["appid"]?.string,
              let name = state["name"]?.string, !ignoredAppIDs.contains(id),
              !ignoredPrefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
        let flags = Int(state["StateFlags"]?.string ?? "") ?? 0
        let folder = state["installdir"]?.string.map { steamapps.appendingPathComponent("common/\($0)") }
        return StoreGame(source: .steam(appID: id), title: name, installed: flags & 4 != 0, installFolder: folder)
    }
}

/// Reads the Epic Games Launcher's install manifests (`ProgramData/Epic/EpicGamesLauncher/Data/Manifests/*.item`).
public enum EpicLibrary {
    struct Manifest: Decodable {
        let DisplayName: String?
        let AppName: String?
        let CatalogNamespace: String?
        let CatalogItemId: String?
        let InstallLocation: String?
        let bIsIncompleteInstall: Bool?
        let bIsApplication: Bool?
    }

    public static func manifestsFolder(in space: Space) -> URL {
        space.driveC.appendingPathComponent("ProgramData/Epic/EpicGamesLauncher/Data/Manifests")
    }

    public static func scan(_ space: Space) -> [StoreGame] {
        let files = (try? FileManager.default.contentsOfDirectory(at: manifestsFolder(in: space), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "item" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let m = try? JSONDecoder().decode(Manifest.self, from: data),
                  let app = m.AppName, let ns = m.CatalogNamespace, let item = m.CatalogItemId,
                  m.bIsApplication != false else { return nil }
            let uri = "com.epicgames.launcher://apps/\(ns)%3A\(item)%3A\(app)?action=launch&silent=true"
            return StoreGame(source: .epic(appName: app, launchURI: uri), title: m.DisplayName ?? app,
                             installed: m.bIsIncompleteInstall != true,
                             installFolder: m.InstallLocation.flatMap { space.macURL(forWindowsPath: $0) })
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
