import Foundation

/// The command lines G-Player gives Legendary. Pure, so what matters is tested: global flags go before the subcommand (after
/// it Legendary hands them to the game), a command that takes a platform always gets Windows (Legendary's own default on a Mac
/// is `Mac`), and nothing is left to a question, since stdin is closed.
public enum LegendaryCommand {
    /// The platform of every command that takes one.
    public static let platform = "Windows"

    /// `-y` answers every question with yes. It is a global flag of Legendary, so it comes first.
    private static func command(_ arguments: [String]) -> [String] { ["-y"] + arguments }

    /// Who is signed in, from what is on this Mac only.
    public static var status: [String] { command(["status", "--offline", "--json"]) }

    /// Signs in with the code Epic's page gave. The code is an argument of this one command and of no other.
    public static func signIn(code: String) -> [String] { command(["auth", "--code", code]) }

    /// Forgets the login on this Mac.
    public static var signOut: [String] { command(["auth", "--delete"]) }

    /// The games the account owns, for Windows. Asks Epic, so it needs the network.
    public static var library: [String] { command(["list", "--platform", platform, "--json"]) }

    public static var installed: [String] { command(["list-installed", "--json"]) }

    /// Installs a game under `basePath`. The two `--skip` flags keep it from asking: Legendary asks which language packs to get
    /// for the games that have them, and with `-y` it would install every add-on without being asked.
    public static func install(appName: String, basePath: URL) -> [String] {
        command(["install", appName, "--platform", platform, "--base-path", basePath.path, "--skip-sdl", "--skip-dlcs"])
    }

    public static func uninstall(appName: String) -> [String] { command(["uninstall", appName]) }

    // TODO: update and repair (`install` again, `install --repair`), verify, sync-saves and eos-overlay, once G-Player offers them.

    /// How to start a game, as JSON; Legendary starts nothing. Online it asks Epic for a one-time code to log the game in, so
    /// the answer is for right now. `--wine` is always given: without it Legendary looks for CrossOver. The version check is
    /// skipped: an out-of-date game would otherwise refuse to start, and G-Player can't update games yet.
    public static func launch(appName: String, wine: URL, offline: Bool) -> [String] {
        command(["launch", appName, "--json", "--wine", wine.path, "--skip-version-check"] + (offline ? ["--offline"] : []))
    }

    /// True for a name Legendary gives a game ("Sugar", "9d2d0eb64d5c…"): it never starts with a dash, so it can't be taken
    /// for an option.
    public static func isAppName(_ name: String) -> Bool {
        guard (1...100).contains(name.count), let first = name.unicodeScalars.first, first.isASCII,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }
}
