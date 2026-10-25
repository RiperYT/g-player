import Foundation

/// G-Player Wine's GStreamer, for game videos that go through Media Foundation. The engine's archive carries none of it: at
/// its root, next to `wine/`, it has `gstreamer-files.txt`, which names the official runtime package (file name and
/// SHA-256) and lists the files of it that Wine and its plugins load. Installing downloads that package
/// (`EngineCatalog.gstreamer`), expands it and copies the listed files, unchanged, into the engine's `wine` folder.
///
///     package gstreamer-1.0-1.28.8-universal.pkg d371ab04…
///     lib/gstreamer-1.0/libgstapplemedia.dylib
///     lib/libglib-2.0.0.dylib
public enum GStreamerRuntime {
    /// At the root of the engine archive. An engine without it (Wine Staging, G-Player Wine 26.3.0-1) has no GStreamer step.
    public static let manifestName = "gstreamer-files.txt"

    public struct Manifest: Equatable, Sendable {
        /// File name of the official package.
        public let packageName: String
        public let sha256: String
        /// Relative to the package's payload root (the framework's Versions/1.0 folder), and to the engine's `wine` folder
        /// once copied.
        public let files: [String]
    }

    /// The list at `folder`'s root (an unpacked engine archive), or nil when the engine has none.
    public static func manifest(in folder: URL) throws -> Manifest? {
        let file = folder.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw ShellError.said("The engine's list of GStreamer files can't be read.")
        }
        return try parse(text)
    }

    /// Reads the list: a `package <file name> <sha256>` line, then one path per line. Anything that isn't a plain relative
    /// path inside the engine is refused, so a damaged list can't make the copy write elsewhere.
    public static func parse(_ text: String) throws -> Manifest {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let head = lines.first?.split(separator: " ", omittingEmptySubsequences: true).map(String.init) ?? []
        guard head.count == 3, head[0] == "package", !head[1].contains("/"),
              head[2].count == 64, head[2].allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ShellError.said("The engine's list of GStreamer files is damaged: it doesn't start with the package it needs.")
        }
        let files = Array(lines.dropFirst())
        for path in files where !isPlainRelative(path) {
            throw ShellError.said("The engine's list of GStreamer files is damaged: “\(path)” isn't a path inside the engine.")
        }
        guard !files.isEmpty else { throw ShellError.said("The engine's list of GStreamer files is empty.") }
        return Manifest(packageName: head[1], sha256: head[2], files: files)
    }

    private static func isPlainRelative(_ path: String) -> Bool {
        !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != "" && $0 != "." && $0 != ".." }
    }

    /// The engine must want the package this G-Player knows (and pins): another one is a GStreamer it was never checked against.
    public static func check(_ manifest: Manifest, against pin: PinnedDownload) throws {
        guard manifest.packageName == pin.fileName, manifest.sha256 == pin.sha256 else {
            throw ShellError.said("This engine expects \(manifest.packageName), a GStreamer this version of G-Player doesn't know. Update G-Player, then try again.")
        }
    }

    /// Copies each listed file from the package expanded at `expanded` (`pkgutil --expand-full`: one `<name>.pkg/Payload`
    /// folder per sub-package, all of them parts of one tree) to the same path under `wineRoot`. The first sub-package that
    /// has the file wins; a link is followed and the real file copied under the listed name, but only one inside the expanded
    /// package. A file that no sub-package has fails the install. Files already there are replaced.
    public static func copyFiles(of manifest: Manifest, from expanded: URL, into wineRoot: URL) throws {
        let fm = FileManager.default
        let payloads = ((try? fm.contentsOfDirectory(at: expanded, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "pkg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { $0.appendingPathComponent("Payload", isDirectory: true) }
        let inside = expanded.resolvingSymlinksInPath().path + "/"
        for path in manifest.files {
            guard let source = payloads.lazy.compactMap({ realFile($0.appendingPathComponent(path), inside: inside) }).first else {
                throw ShellError.said("GStreamer's package has no \(path), which G-Player Wine needs.")
            }
            let target = wineRoot.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)
        }
    }

    /// The file `url` is (or links to), when it exists and lies under `inside` (a folder path ending in a slash).
    private static func realFile(_ url: URL, inside: String) -> URL? {
        let resolved = url.resolvingSymlinksInPath()
        var isFolder: ObjCBool = false
        guard resolved.path.hasPrefix(inside), FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isFolder),
              !isFolder.boolValue else { return nil }
        return resolved
    }
}
