import Foundation

/// What the library screen says (`LibraryProblem`): what is wrong, what each button does, and what Start Empty costs. Here
/// and not in the view so tests hold the promises the words make.
extension LibraryProblem {
    /// "G-Player can't read your library at ~/Games/G-Player"
    public var title: String {
        String(localized: "G-Player can't read your library at \(root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
    }

    /// What is wrong. A file the system won't open is not called damaged: nothing is wrong with it.
    public var explanation: String {
        switch kind {
        case .folderMissing:
            return String(localized: "The folder isn't there. If your library is on an external disk, connect it. If you moved or renamed the folder, it has to be found again. Nothing has been changed.")
        case .fileMissing:
            return String(localized: "The folder is there, but library.json, the file that lists your spaces and games, isn't. Nothing has been changed.")
        case .damaged:
            return brokenCopy.map { String(localized: "library.json is damaged (\(reason)). G-Player saved a copy as \($0.lastPathComponent) next to it and changed nothing else.") }
                ?? String(localized: "library.json is damaged (\(reason)). G-Player couldn't save a copy, so it won't replace the file and changed nothing else.")
        case .unreadable:
            return String(localized: "library.json can't be opened (\(reason)). That is usually a permission: check in Finder (Get Info, Sharing & Permissions) that you may read it. The file isn't damaged, and nothing has been changed.")
        }
    }

    /// What each button does, one sentence apiece, for the buttons that are there.
    public var buttonHelp: [String] {
        var lines = [String(localized: "Try Again looks at the library again, for a disk that has just been connected or a file you fixed.")]
        lines.append(String(localized: "Locate… lets you choose the folder your library is in now; G-Player uses that folder from then on, and your spaces are found in it."))
        if previousIsUsable {
            lines.append(String(localized: "Use Previous Copy brings back the library as it was before its last change, which G-Player kept as library.json.previous."))
        }
        if canStartEmpty {
            lines.append(String(localized: "Start Empty begins a new, empty library. Your spaces and games leave the library, but their files stay on your disk."))
        }
        return lines
    }

    /// Whether Start Empty is offered. A file that couldn't be copied first would be lost by it, so it isn't.
    public var canStartEmpty: Bool {
        switch kind {
        case .folderMissing, .fileMissing: true
        case .damaged: brokenCopy != nil
        case .unreadable: false
        }
    }

    /// The confirmation before Start Empty: what leaves the library, what stays, and where the old library is kept.
    public var startEmptyConsequence: String {
        let leaves = String(localized: "Your spaces and games leave the library.")
        let stays = String(localized: "Their files stay on your disk; the spaces are in the library's Spaces folder.")
        switch kind {
        case .folderMissing:
            return String(localized: "G-Player makes a new, empty library in \(root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).") + " "
                + String(localized: "The games and spaces of the library that was here aren't in it, and their files aren't deleted.") + " "
                + String(localized: "If the library is on a disk that isn't connected, choose Try Again instead.")
        case .fileMissing:
            return "\(leaves) \(stays) " + String(localized: "The previous copy of the library is kept next to the new one as library.json.before-empty-… so it can still be brought back.")
        case .damaged:
            let file = brokenCopy.map { String(localized: "The damaged file stays as \($0.lastPathComponent), and the previous copy, if there is one, as library.json.before-empty-…") }
                ?? String(localized: "The damaged file stays, and the previous copy, if there is one, as library.json.before-empty-…")
            return "\(leaves) \(stays) \(file)"
        case .unreadable:
            return String(localized: "G-Player can't copy library.json, so it won't replace it.")
        }
    }
}
