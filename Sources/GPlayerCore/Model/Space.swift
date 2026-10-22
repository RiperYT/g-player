import Foundation

/// A Windows environment: its own C: drive, registry and fonts (a Wine prefix).
public struct Space: Codable, Identifiable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// Created by G-Player inside the library folder.
        case managed
        /// Found elsewhere on this Mac (CrossOver bottle, an older prefix) and used in place.
        case external
    }

    public var id: UUID
    public var name: String
    /// Absolute path of the prefix folder (the one that holds `drive_c`).
    public var path: String
    public var engineID: String
    public var origin: Origin
    /// Where it came from, e.g. "CrossOver" or "~/Games". Shown in the UI.
    public var originNote: String?
    /// The app preset (Steam, Epic…) this space was made for, if any.
    public var presetID: String?
    /// Index into `SpaceColor.palette`.
    public var colorIndex: Int
    public var createdAt: Date
    /// External spaces only: whether the user lets G-Player install Windows components and write per-game settings
    /// into it. Nil until asked. Spaces G-Player created are always changed as needed.
    public var allowsChanges: Bool?

    public init(id: UUID = UUID(), name: String, path: String, engineID: String, origin: Origin,
                originNote: String? = nil, presetID: String? = nil, colorIndex: Int = 0, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.path = path; self.engineID = engineID; self.origin = origin
        self.originNote = originNote; self.presetID = presetID; self.colorIndex = colorIndex; self.createdAt = createdAt
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var driveC: URL { url.appendingPathComponent("drive_c", isDirectory: true) }
    /// True when G-Player may install components and write settings into this space.
    public var mayChange: Bool { origin == .managed || allowsChanges == true }
    public var exists: Bool { FileManager.default.fileExists(atPath: driveC.appendingPathComponent("windows").path) }

    /// Maps a Windows path (`C:\Games\x.exe`, `Z:\Users\…`) to the Mac.
    public func macURL(forWindowsPath windowsPath: String) -> URL? {
        let parts = windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        guard let drive = parts.first?.lowercased(), drive.count == 2, drive.hasSuffix(":") else { return nil }
        let root: URL
        if drive == "c:" {
            root = driveC
        } else if drive == "z:" {
            root = URL(fileURLWithPath: "/")
        } else {
            let link = url.appendingPathComponent("dosdevices/\(drive)")
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
            root = URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
        }
        return parts.dropFirst().reduce(root) { $0.appendingPathComponent($1) }
    }

    /// The Windows path a program inside this space sees for a Mac file.
    public func windowsPath(for macURL: URL) -> String {
        if let rel = Files.relativePath(of: macURL, to: driveC) {
            return "C:\\" + rel.replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + macURL.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
    }
}

/// Muted colours that tell spaces apart on covers and in the sidebar.
public enum SpaceColor {
    /// (red, green, blue) 0…1. Slate, moss, clay, plum, ochre, teal, rose, graphite.
    public static let palette: [(Double, Double, Double)] = [
        (0.357, 0.420, 0.498), (0.373, 0.478, 0.353), (0.604, 0.420, 0.325), (0.478, 0.353, 0.498),
        (0.627, 0.518, 0.251), (0.310, 0.498, 0.510), (0.639, 0.388, 0.443), (0.353, 0.361, 0.384),
    ]
    public static func next(after used: [Int]) -> Int {
        (0..<palette.count).first { !used.contains($0) } ?? (used.count % palette.count)
    }
}
