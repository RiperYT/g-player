import Foundation

/// Signing in to Epic Games without Epic's launcher. The user signs in on Epic's own page; the only thing G-Player takes from
/// it is the one-time authorization code Epic's redirect page hands to the app that asked (the same way the Epic Games
/// Launcher gets it), which `legendary auth --code` turns into a login. The password is never seen: nothing here reads a
/// form, and no URL or page that holds a code is logged.
public enum EpicSignIn {
    /// Epic's login page, which sends the user on to `redirectHost`/`redirectPath` with the code for this client.
    public static let loginURL = URL(string: "https://www.epicgames.com/id/login?redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode")!
    /// What the page is told the browser is, as Legendary's own login window says it, so the page treats it as a launcher.
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) EpicGamesLauncher"
    /// Where a user who prefers their own browser signs in: Legendary's page, which shows the code to copy.
    public static let browserLoginURL = URL(string: "https://legendary.gl/epiclogin")!

    static let redirectHost = "www.epicgames.com"
    static let redirectPath = "/id/api/redirect"

    /// A code is at least this long (Epic's are 32 characters).
    public static let shortestCode = 30
    static let longestCode = 128

    /// True for the page that shows the code: Epic's redirect API. Only then is the page's text looked at.
    public static func isRedirectPage(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == redirectHost else { return false }
        return url.path == redirectPath
    }

    /// The code from the text of the redirect page, a JSON object with an `authorizationCode`. Nil for anything else.
    public static func code(fromPageBody body: String) -> String? {
        guard let data = body.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let code = object["authorizationCode"] as? String { return plausible(code) }
        // The same code is in the address Epic would send the browser to.
        if let redirect = (object["redirectUrl"] as? String).flatMap(URL.init(string:)) { return code(fromRedirect: redirect) }
        return nil
    }

    /// The code from an address on `localhost` with `?code=…`: where the redirect leads when the page isn't shown (Heroic
    /// watches for it too). Nil for any other host.
    public static func code(fromRedirect url: URL) -> String? {
        guard url.host?.lowercased() == "localhost",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value else { return nil }
        return plausible(code)
    }

    /// The code from what the user pasted: the code itself, in quotes, or the whole JSON page. Nil when it can't be one.
    public static func code(fromPasted text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return code(fromPageBody: trimmed) }
        return plausible(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
    }

    /// The code when it can be one: letters, digits, `_` and `-` only (so it can't be taken for an option on a command line,
    /// and never starts with a dash), and at least `shortestCode` characters.
    static func plausible(_ code: String) -> String? {
        guard (shortestCode...longestCode).contains(code.count), let first = code.unicodeScalars.first,
              first.isASCII, CharacterSet.alphanumerics.contains(first) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return code.unicodeScalars.allSatisfy(allowed.contains) ? code : nil
    }
}
