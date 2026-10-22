import Foundation

/// How long the path of a Wine prefix may be.
///
/// Wine runs `Z:\<prefix>\drive_c\windows\system32\…`, and a Windows path stops at 260 characters (MAX_PATH). With a
/// prefix path of 262 characters `explorer.exe /desktop` never came up, and every Wine program then started another
/// one: thousands of processes within minutes, until macOS refused to start any. So G-Player never makes or adopts a
/// prefix whose path is over `maxLength`, which leaves about 80 characters inside the prefix for the game's own path.
public enum PrefixPath {
    /// The longest prefix path G-Player accepts, in UTF-16 units (how Windows counts).
    public static let maxLength = 150
    /// The shortest space folder name the library folder has to leave room for.
    static let shortestName = 24
    /// Room kept for the " 2" … " 999" that `Files.uniqueURL` adds to a name already taken.
    static let suffixRoom = 4

    /// Length of a path as Wine gets it. Paths under /var, /tmp and /etc are counted by their longer /private form.
    public static func length(of path: String) -> Int {
        let units = path.utf16.count
        return ["/var/", "/tmp/", "/etc/"].contains(where: path.hasPrefix) ? units + "/private".utf16.count : units
    }

    /// Characters left for a space's folder name inside `spaces` (the library's Spaces folder).
    static func nameRoom(in spaces: URL) -> Int { maxLength - length(of: spaces.path) - 1 - suffixRoom }

    /// The longest library folder path that still leaves room for a space folder name of `shortestName` characters.
    public static var maxLibraryRootLength: Int {
        let spacesFolder = LibraryPaths(root: URL(fileURLWithPath: "/")).spaces.lastPathComponent
        return maxLength - suffixRoom - shortestName - 2 - spacesFolder.utf16.count
    }

    /// The longest folder name for a new space in `spaces`: the usual limit, or less where the path is long.
    public static func folderNameLimit(in spaces: URL) -> Int {
        min(Files.defaultNameLength, nameRoom(in: spaces))
    }

    /// Why a library folder can't be used, for the user, or nil when it is fine.
    public static func libraryRootProblem(_ root: URL) -> String? {
        let n = length(of: LibraryPaths(root: root).root.path)
        guard n > maxLibraryRootLength else { return nil }
        return "The library folder's path is \(n) characters long; the limit is \(maxLibraryRootLength). Wine can't start programs "
            + "from a path that long, and keeps trying until the Mac runs out of processes. "
            + "Choose a folder closer to the top of a disk, such as your home folder."
    }

    /// Why no new space can be made in a library that already exists, for the user, or nil when its folder is fine. An older
    /// G-Player allowed a longer path, so this is how that library's owner learns about the limit: where it comes from, that
    /// what is there keeps working, and how to move the folder (`LibraryStore.libraryFolder` finds it again, and
    /// `LibraryState.movingLibrary` points its spaces at the new place).
    public static func existingLibraryProblem(_ root: URL) -> String? {
        let folder = LibraryPaths(root: root).root
        let n = length(of: folder.path)
        guard n > maxLibraryRootLength else { return nil }
        return "New spaces can't be made in this library: its folder's path is \(n) characters long and the limit is "
            + "\(maxLibraryRootLength). Windows paths stop at 260 characters, and Wine runs programs from inside a space, so a "
            + "longer path makes Wine fail to start programs and keep trying until the Mac runs out of processes. "
            + "The spaces already in the library keep working.\n\n"
            + "To move the library: quit G-Player, move the folder “\(folder.lastPathComponent)” closer to the top of a disk, "
            + "such as your home folder, then open G-Player and choose Locate… on the screen that appears."
    }

    /// Why a Wine prefix at `url` can't be used, for the user, or nil when it is fine.
    public static func problem(forPrefix url: URL) -> String? {
        let n = length(of: url.standardizedFileURL.path)
        guard n > maxLength else { return nil }
        return "Its path is \(n) characters long; the limit is \(maxLength). Wine can't start programs "
            + "from a path that long, and keeps trying until the Mac runs out of processes. "
            + "Move it closer to the top of a disk, such as your home folder."
    }
}

public extension FoundEnvironment {
    /// Why this prefix can't be added as a space (`PrefixPath`), or nil.
    var pathProblem: String? { PrefixPath.problem(forPrefix: url) }
}
