import Foundation

/// What programs a space holds, so the ones an installer added can be found afterwards.
public struct ProgramSnapshot: Sendable {
    public let executables: Set<String>
    public let shortcuts: Set<String>

    public static func take(of space: Space) -> ProgramSnapshot {
        let exes = ExecutableScanner.scan(space.driveC, maxDepth: 7).map { $0.url.standardizedFileURL.path }
        let links = ShortcutScanner.shortcutFiles(in: space).map { $0.standardizedFileURL.path }
        return ProgramSnapshot(executables: Set(exes), shortcuts: Set(links))
    }

    /// Programs that are new since `before`, best guess first: shortcuts the installer made, then new .exe files.
    public static func newPrograms(in space: Space, since before: ProgramSnapshot) -> [ExecutableCandidate] {
        let after = take(of: space)
        var results: [ExecutableCandidate] = []
        var seen = Set<String>()
        for linkPath in after.shortcuts.subtracting(before.shortcuts).sorted() {
            guard let shortcut = ShortcutScanner.read(URL(fileURLWithPath: linkPath), in: space),
                  let target = shortcut.target, target.pathExtension.lowercased() == "exe",
                  !ExecutableScanner.isHelper(target.lastPathComponent),
                  seen.insert(target.standardizedFileURL.path).inserted else { continue }
            results.append(ExecutableCandidate(url: target, size: Files.size(of: target), score: 1000,
                                               hint: "Shortcut “\(shortcut.name)”"))
        }
        let newExes = after.executables.subtracting(before.executables)
        let rated = ExecutableScanner.scan(space.driveC, maxDepth: 7)
            .filter { newExes.contains($0.url.standardizedFileURL.path) && seen.insert($0.url.standardizedFileURL.path).inserted }
        return results + rated
    }
}
