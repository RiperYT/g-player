import Foundation

/// Makes Chromium-based launchers (Steam, Epic, GOG Galaxy, Rockstar) draw their windows under Wine on macOS.
///
/// Out of process, Chromium's GPU process paints into a window owned by another process, which Wine's Mac
/// driver can't show, so the window stays black. The wrapper (`tools/chromium-helper-wrapper/wrapper.c`, from
/// MaPC's MacadeKit, Apache-2.0) takes the helper's place, starts `<name>_real.exe` and adds
/// `--disable-gpu --disable-gpu-compositing --in-process-gpu`. Steam ignores `-cef-*` flags on its own
/// command line since 2026, so the flags have to go to the helper itself. Updates restore the vendor helper,
/// so `apply` runs before every launch, and again while the launcher runs (it updates itself on start). A launcher that
/// runs better with its own helper on an engine (Epic on G-Player Wine) isn't wrapped there, and `unwrap` puts it back.
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
        let wrapper = try wrapperData(wrapper)
        var changed: [URL] = []
        for pattern in helpers {
            for helper in expand(pattern, in: space.driveC) where try wrap(helper, with: wrapper) {
                changed.append(helper)
            }
        }
        return changed
    }

    /// Takes G-Player's wrapper out of every helper matching `helpers`, for a launcher that runs better with its own
    /// (`AppPreset.helpersToUnwrap`). The vendor helper is copied back from `<name>_real.exe`, which stays where it is. A helper is
    /// only touched when the file there is exactly the wrapper G-Player ships and the vendor copy is there: a helper the
    /// launcher updated, or another tool's wrapper, is left as it is. Nothing at all in a space G-Player may not change
    /// (`Space.mayChange`). Returns the helpers it changed.
    @discardableResult
    public static func unwrap(helpers: [String], in space: Space, wrapper: Data? = nil) throws -> [URL] {
        guard space.mayChange else { return [] }
        let wrapper = try wrapperData(wrapper)
        var changed: [URL] = []
        for pattern in helpers {
            for helper in expand(pattern, in: space.driveC) where try unwrap(helper, wrapper: wrapper) {
                changed.append(helper)
            }
        }
        return changed
    }

    private static func wrapperData(_ given: Data?) throws -> Data {
        guard let wrapper = given ?? wrapperURL.flatMap({ FileManager.default.contents(atPath: $0.path) }),
              isWrapper(wrapper) else {
            throw ShellError.failed("The Chromium helper wrapper is missing from G-Player.")
        }
        return wrapper
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

    /// Swaps one helper back. Nothing is deleted, and the helper is written whole in one step, so a failure leaves one that starts.
    static func unwrap(_ helper: URL, wrapper: Data) throws -> Bool {
        let fm = FileManager.default
        // The size first: most starts find the vendor helper, which is a different size, and read nothing.
        guard Files.size(of: helper) == Int64(wrapper.count), fm.contents(atPath: helper.path) == wrapper,
              let saved = fm.contents(atPath: realURL(for: helper).path), !saved.isEmpty, !isWrapper(saved) else { return false }
        try saved.write(to: helper, options: .atomic)
        return true
    }

    /// Helper processes that run the vendor binary instead of the wrapper. With the wrapper, Chromium's subprocesses
    /// (`--type=…`) run as `<name>_real.exe`; under the helper's own name they mean the wrapper wasn't there when the
    /// helper started (the launcher had just updated itself), so the window is black. Returns every process with the
    /// helper's name then, the main one too: once they quit, the launcher starts its helper again, through the wrapper.
    public static func unwrappedProcesses(helpers: [String], in processes: [WineProcess]) -> [WineProcess] {
        let names = Set(helpers.compactMap { $0.split(separator: "/").last.map { $0.lowercased() } })
        let running = processes.filter { p in p.programName.map(names.contains) ?? false }
        return running.contains { $0.command.contains("--type=") } ? running : []
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
