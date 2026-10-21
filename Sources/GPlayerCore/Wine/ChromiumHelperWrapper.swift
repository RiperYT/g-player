import Foundation

/// Makes Chromium-based launchers (Steam, Epic, GOG Galaxy, Rockstar) draw their windows under Wine on macOS.
///
/// Out of process, Chromium's GPU process paints into a window owned by another process, which Wine's Mac
/// driver can't show, so the window stays black. The wrapper (`tools/chromium-helper-wrapper/wrapper.c`, from
/// MaPC's MacadeKit, Apache-2.0) takes the helper's place, starts `<name>_real.exe` and adds
/// `--disable-gpu --disable-gpu-compositing --in-process-gpu`. Steam ignores `-cef-*` flags on its own
/// command line since 2026, so the flags have to go to the helper itself. Updates restore the vendor helper,
/// so `apply` runs before every launch.
public enum ChromiumHelperWrapper {
    static let marker = Data("macade-chromium-wrapper/2".utf8)

    /// The wrapper: in the app bundle, or next to the sources when running from the repository.
    public static var wrapperURL: URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["GPLAYER_WRAPPER"], fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        if let bundled = Bundle.main.url(forResource: "chromium-helper-wrapper", withExtension: "exe") { return bundled }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/chromium-helper-wrapper.exe")
        return fm.fileExists(atPath: source.path) ? source : nil
    }

    public static func isWrapper(_ data: Data) -> Bool { data.range(of: marker) != nil }

    /// Wraps every helper matching `helpers` (paths relative to drive_c; `*` matches one folder name).
    /// Returns the helpers it changed.
    @discardableResult
    public static func apply(helpers: [String], in space: Space, wrapper: Data? = nil) throws -> [URL] {
        guard let wrapper = wrapper ?? wrapperURL.flatMap({ FileManager.default.contents(atPath: $0.path) }),
              isWrapper(wrapper) else {
            throw ShellError.failed("The Chromium helper wrapper is missing from G-Player.")
        }
        var changed: [URL] = []
        for pattern in helpers {
            for helper in expand(pattern, in: space.driveC) where try wrap(helper, with: wrapper) {
                changed.append(helper)
            }
        }
        return changed
    }

    /// `Program Files (x86)/Steam/bin/cef/cef.*/steamwebhelper.exe` → every matching file that exists.
    static func expand(_ pattern: String, in root: URL) -> [URL] {
        var results = [root]
        for part in pattern.split(separator: "/").map(String.init) {
            if part.contains("*") {
                let prefix = String(part.prefix { $0 != "*" })
                let suffix = String(part.drop { $0 != "*" }.dropFirst())
                results = results.flatMap { dir in
                    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                        .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
                        .map { dir.appendingPathComponent($0) }
                }
            } else {
                results = results.map { $0.appendingPathComponent(part) }
            }
        }
        let fm = FileManager.default
        return results.filter { url in
            fm.fileExists(atPath: url.path) || fm.fileExists(atPath: realURL(for: url).path)
        }
    }

    static func realURL(for helper: URL) -> URL {
        helper.deletingLastPathComponent().appendingPathComponent(helper.deletingPathExtension().lastPathComponent + "_real.exe")
    }

    /// Swaps one helper. The vendor binary is copied to `_real.exe` before the wrapper replaces it,
    /// so a failure at any point leaves a helper that starts.
    static func wrap(_ helper: URL, with wrapper: Data) throws -> Bool {
        let fm = FileManager.default
        let real = realURL(for: helper)
        guard let current = fm.contents(atPath: helper.path) else {
            guard let saved = fm.contents(atPath: real.path), !saved.isEmpty, !isWrapper(saved) else { return false }
            try wrapper.write(to: helper, options: .atomic)
            return true
        }
        if isWrapper(current) {
            guard let saved = fm.contents(atPath: real.path), !saved.isEmpty, !isWrapper(saved) else {
                throw ShellError.failed("The original \(helper.lastPathComponent) is missing. Repair the app to download it again.")
            }
            if current == wrapper { return false }
            try wrapper.write(to: helper, options: .atomic)
            return true
        }
        try current.write(to: real, options: .atomic)
        try wrapper.write(to: helper, options: .atomic)
        return true
    }

    /// Puts the vendor helpers back (used before a repair).
    public static func restore(helpers: [String], in space: Space) {
        let fm = FileManager.default
        for pattern in helpers {
            for helper in expand(pattern, in: space.driveC) {
                let real = realURL(for: helper)
                guard let saved = fm.contents(atPath: real.path), !isWrapper(saved) else { continue }
                try? saved.write(to: helper, options: .atomic)
            }
        }
    }
}
