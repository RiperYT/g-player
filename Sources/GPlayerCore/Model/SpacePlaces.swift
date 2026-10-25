import Foundation

/// A folder inside a space worth jumping to, such as its Games folder.
public struct SpacePlace: Hashable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case drive, games, programFiles, programFilesX86, documents, appData, spaceFolder }

    public let kind: Kind
    public let title: String
    public let url: URL
    /// The folder is a symlink that leads out of the space, such as Documents pointing at the Mac's own
    /// Documents folder. Files saved there land on the Mac, not in the space.
    public let linksToMac: Bool
    public var id: Kind { kind }

    /// What the sidebar shows: "Documents (Mac)" when the folder lives on the Mac.
    public var label: String { linksToMac ? String(localized: "\(title) (Mac)") : title }
}

public enum SpacePlaces {
    /// The quick places that exist in `space`, in the order the Files view lists them.
    public static func find(in space: Space, userName: String = NSUserName()) -> [SpacePlace] {
        let c = space.driveC
        var candidates: [(SpacePlace.Kind, String, URL?)] = [
            (.drive, String(localized: "C: Drive"), c),
            (.games, "Games", c.appendingPathComponent("Games", isDirectory: true)),
            (.programFiles, "Program Files", c.appendingPathComponent("Program Files", isDirectory: true)),
            (.programFilesX86, "Program Files (x86)", c.appendingPathComponent("Program Files (x86)", isDirectory: true)),
        ]
        let user = windowsUserFolder(in: space, userName: userName)
        candidates += [
            (.documents, "Documents", user?.appendingPathComponent("Documents", isDirectory: true)),
            (.appData, "AppData", user?.appendingPathComponent("AppData", isDirectory: true)),
            (.spaceFolder, String(localized: "Space Folder"), space.url),
        ]
        let root = space.url.resolvingSymlinksInPath()
        return candidates.compactMap { kind, title, url in
            guard let url, Files.isDirectory(url) else { return nil }
            let leaves = Files.relativePath(of: url.resolvingSymlinksInPath(), to: root) == nil
            return SpacePlace(kind: kind, title: title, url: url, linksToMac: leaves)
        }
    }

    /// `drive_c/users/<Mac user>` if it exists, otherwise the first folder there that isn't "Public".
    public static func windowsUserFolder(in space: Space, userName: String = NSUserName()) -> URL? {
        let users = space.driveC.appendingPathComponent("users", isDirectory: true)
        let own = users.appendingPathComponent(userName, isDirectory: true)
        if !userName.isEmpty, Files.isDirectory(own) { return own }
        let others = (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return others
            .filter { $0.lastPathComponent.caseInsensitiveCompare("Public") != .orderedSame && Files.isDirectory($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first
    }
}
