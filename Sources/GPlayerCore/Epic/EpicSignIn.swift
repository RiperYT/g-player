import Foundation

/// Signing in to Epic Games without Epic's launcher. The user signs in on Epic's own page; the only thing G-Player takes from
/// it is the one-time authorization code Epic's redirect page hands to the app that asked (the same way the Epic Games
/// Launcher gets it), which `legendary auth --code` turns into a login. The password is never seen: nothing here reads a
/// form, and no URL or page that holds a code is logged.
public enum EpicSignIn {
    /// Epic's login page as Heroic opens it: told by `userAgent` it is the Epic Games Launcher, it ends on `localhost` with the
    /// code (`code(navigatingTo:isMainFrame:)`). A `redirectUrl` to Epic's redirect API, as Legendary's docs had it, is refused
    /// now ("the client's redirect URL is unknown").
    public static let loginURL = URL(string: "https://www.epicgames.com/id/login?responseType=code")!
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

    /// True for an address on Epic's own domain, where the page is told the browser is the Epic Games Launcher. A sign-in with
    /// Google or Apple, on their pages, gets the browser's own name.
    public static func usesLauncherAgent(for url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "epicgames.com" || host.hasSuffix(".epicgames.com")
    }

    /// The code of a navigation about to happen: only one of the page itself (`isMainFrame`; a frame inside a page, an ad or a
    /// widget, is not where the user's sign-in ends) and only to `localhost` with a code. Nil otherwise.
    public static func code(navigatingTo url: URL, isMainFrame: Bool) -> String? {
        isMainFrame ? code(fromRedirect: url) : nil
    }

    /// The code from the text of a page that finished loading: only Epic's redirect page, only the page itself, never a page of
    /// another address however much it looks like the answer.
    public static func code(fromPage url: URL?, isMainFrame: Bool, text: String) -> String? {
        isMainFrame && isRedirectPage(url) ? code(fromPageBody: text) : nil
    }

    /// The code from an address on `localhost` with `?code=…`: where the redirect leads when the page isn't shown (Heroic
    /// watches for it too), over http or https. Nil for any other host or scheme.
    public static func code(fromRedirect url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.lowercased() == "localhost",
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
