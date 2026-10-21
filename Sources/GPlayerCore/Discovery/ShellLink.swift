import Foundation

/// The parts of a Windows shortcut (.lnk, MS-SHLLINK) G-Player needs.
public struct ShellLink: Sendable, Equatable {
    public var localBasePath: String?
    public var relativePath: String?
    public var workingDirectory: String?
    public var arguments: String?

    public static func parse(_ data: Data) -> ShellLink? {
        let b = [UInt8](data)
        guard b.count >= 0x4C, u32(b, 0) == 0x4C else { return nil }
        let flags = u32(b, 0x14)
        let hasIDList = flags & 0x1 != 0, hasLinkInfo = flags & 0x2 != 0, hasName = flags & 0x4 != 0
        let hasRelative = flags & 0x8 != 0, hasWorkDir = flags & 0x10 != 0, hasArgs = flags & 0x20 != 0
        let unicode = flags & 0x80 != 0
        var pos = 0x4C
        if hasIDList {
            guard pos + 2 <= b.count else { return nil }
            pos += 2 + Int(u16(b, pos))
        }
        var link = ShellLink()
        if hasLinkInfo {
            guard pos + 0x1C <= b.count else { return nil }
            let start = pos
            let size = Int(u32(b, pos))
            let headerSize = Int(u32(b, pos + 4))
            let infoFlags = u32(b, pos + 8)
            if infoFlags & 0x1 != 0 {
                let baseOffset = Int(u32(b, pos + 16)), suffixOffset = Int(u32(b, pos + 24))
                var base = cString(b, start + baseOffset)
                if headerSize >= 0x24, pos + 0x20 <= b.count {
                    let uOffset = Int(u32(b, pos + 0x1C))
                    if uOffset > 0, let w = wideCString(b, start + uOffset) { base = w }
                }
                let suffix = cString(b, start + suffixOffset) ?? ""
                if let base { link.localBasePath = suffix.isEmpty ? base : base + suffix }
            }
            pos = start + size
        }
        func readString() -> String? {
            guard pos + 2 <= b.count else { return nil }
            let count = Int(u16(b, pos)); pos += 2
            let byteCount = unicode ? count * 2 : count
            guard pos + byteCount <= b.count else { return nil }
            let slice = Data(b[pos..<pos + byteCount]); pos += byteCount
            return String(data: slice, encoding: unicode ? .utf16LittleEndian : .windowsCP1252)
        }
        if hasName { _ = readString() }
        if hasRelative { link.relativePath = readString() }
        if hasWorkDir { link.workingDirectory = readString() }
        if hasArgs { link.arguments = readString() }
        return link
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 1 < b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 3 < b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    private static func cString(_ b: [UInt8], _ i: Int) -> String? {
        guard i > 0, i < b.count else { return nil }
        var end = i
        while end < b.count, b[end] != 0 { end += 1 }
        return String(data: Data(b[i..<end]), encoding: .windowsCP1252)
    }
    private static func wideCString(_ b: [UInt8], _ i: Int) -> String? {
        guard i > 0, i < b.count else { return nil }
        var end = i
        while end + 1 < b.count, !(b[end] == 0 && b[end + 1] == 0) { end += 2 }
        return String(data: Data(b[i..<end]), encoding: .utf16LittleEndian)
    }
}

/// A Start Menu or Desktop shortcut inside a space.
public struct Shortcut: Sendable, Hashable {
    public let name: String
    public let file: URL
    public let target: URL?
    public let arguments: [String]
}

public enum ShortcutScanner {
    /// Start Menu and Desktop folders Wine fills when an installer makes shortcuts.
    public static func folders(in space: Space) -> [URL] {
        let fm = FileManager.default
        var dirs = [space.driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs")]
        let users = space.driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            let home = users.appendingPathComponent(user)
            dirs.append(home.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
            dirs.append(home.appendingPathComponent("Desktop"))
        }
        return dirs.filter { fm.fileExists(atPath: $0.path) }
    }

    public static func shortcutFiles(in space: Space) -> [URL] {
        folders(in: space).flatMap { dir -> [URL] in
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
            return walker.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "lnk" }
        }
    }

    public static func read(_ file: URL, in space: Space) -> Shortcut? {
        guard let data = try? Data(contentsOf: file), let link = ShellLink.parse(data) else { return nil }
        var target: URL?
        if let base = link.localBasePath { target = space.macURL(forWindowsPath: base) }
        if target == nil, let rel = link.relativePath {
            target = file.deletingLastPathComponent()
                .appendingPathComponent(rel.replacingOccurrences(of: "\\", with: "/")).standardizedFileURL
        }
        let args = (link.arguments ?? "").split(separator: " ").map(String.init)
        return Shortcut(name: file.deletingPathExtension().lastPathComponent, file: file, target: target, arguments: args)
    }

    /// Programs with shortcuts, without uninstallers and helpers, one per target.
    public static func programs(in space: Space) -> [Shortcut] {
        var seen = Set<String>()
        return shortcutFiles(in: space).compactMap { read($0, in: space) }.filter { s in
            guard let t = s.target, t.pathExtension.lowercased() == "exe",
                  FileManager.default.fileExists(atPath: t.path),
                  !ExecutableScanner.isHelper(t.lastPathComponent), !ExecutableScanner.isHelper(s.name) else { return false }
            return seen.insert(t.standardizedFileURL.path).inserted
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
