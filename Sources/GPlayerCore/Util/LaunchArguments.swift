import Foundation

/// What the app was started with, beyond opening a window. Hidden: for checking the UI without clicking through it.
public enum LaunchArguments {
    /// The folder to draw the first-run screens into (`--render-onboarding <folder>`, `--render-onboarding=<folder>`, or
    /// the environment variable `GPLAYER_RENDER_ONBOARDING`; the argument wins), or nil for a normal start. A relative
    /// folder is taken from `currentDirectory`.
    public static func snapshotFolder(arguments: [String], environment: [String: String],
                                      currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> URL? {
        let flag = "--render-onboarding"
        var value: String?
        for (i, argument) in arguments.enumerated() {
            if argument == flag { value = i + 1 < arguments.count ? arguments[i + 1] : nil; break }
            if argument.hasPrefix(flag + "=") { value = String(argument.dropFirst(flag.count + 1)); break }
        }
        guard let chosen = value ?? environment["GPLAYER_RENDER_ONBOARDING"], !chosen.isEmpty else { return nil }
        let path = (chosen as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : currentDirectory.appendingPathComponent(path)
        return url.standardizedFileURL
    }
}
