import Foundation

/// What G-Player leaves in the library when it quits or crashes in the middle of work, found by the temporary names it
/// gives that work and nothing else: a file or folder of the user's is never taken for one. Cleaned at start.
public enum Leftovers {
    /// Eight characters of a UUID, as the temporary names carry them.
    private static func isEightHex(_ text: Substring) -> Bool {
        text.count == 8 && text.allSatisfy { $0.isHexDigit && !$0.isLowercase }
    }

    /// "vc_redist.x64.exe.1A2B3C4D", and the same with ".part" (the downloader's bytes) once or twice (older versions added
    /// the suffix twice): a component or tool download that never ended. A real download is named as the publisher names it.
    public static func isComponentDownload(_ name: String) -> Bool {
        var rest = Substring(name)
        while rest.hasSuffix(".part") { rest = rest.dropLast(5) }
        guard let dot = rest.lastIndex(of: "."), dot != rest.startIndex else { return false }
        return isEightHex(rest[rest.index(after: dot)...])
    }

    /// "install-1A2B3C4D": where an Add Game archive was unpacked to run its installer.
    public static func isInstallFolder(_ name: String) -> Bool {
        name.hasPrefix("install-") && isEightHex(name.dropFirst(8))
    }

    /// "tmp-<uuid>": the scratch folder of one winetricks run.
    public static func isScratchFolder(_ name: String) -> Bool {
        name.hasPrefix("tmp-") && UUID(uuidString: String(name.dropFirst(4))) != nil
    }

    /// Removes the leftovers in `paths`. `processes` are the Windows programs running now: an installer that outlived the
    /// G-Player that started it may still run from its unpacked folder, and that folder stays while it does. Not for use
    /// while G-Player downloads or installs anything of its own.
    public static func clean(_ paths: LibraryPaths, processes: [WineProcess]) {
        let fm = FileManager.default
        let components = paths.downloads.appendingPathComponent("components", isDirectory: true)
        let tools = [components, paths.engines.appendingPathComponent("tools", isDirectory: true), Legendary(paths: paths).toolFolder]
        for (folder, matches) in tools.map({ ($0, isComponentDownload) }) {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where matches(name) {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        for name in (try? fm.contentsOfDirectory(atPath: components.path)) ?? [] where isScratchFolder(name) {
            try? fm.removeItem(at: components.appendingPathComponent(name))
        }
        for name in (try? fm.contentsOfDirectory(atPath: paths.downloads.path)) ?? [] where isInstallFolder(name) {
            let folder = paths.downloads.appendingPathComponent(name)
            if !isInUse(folder, by: processes) { try? fm.removeItem(at: folder) }
        }
    }

    /// True when a program works in the folder or runs something from it.
    static func isInUse(_ folder: URL, by processes: [WineProcess]) -> Bool {
        let roots = Set([folder.path, folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path])
        return processes.contains { process in
            roots.contains { root in
                process.command.contains(root + "/") || process.directory.map { $0 == root || $0.hasPrefix(root + "/") } == true
            }
        }
    }
}
