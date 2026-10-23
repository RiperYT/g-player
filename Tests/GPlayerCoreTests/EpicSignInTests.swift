import Foundation
import Testing
@testable import GPlayerCore

// Signing in to Epic without its launcher: which page is read, and which codes are taken from it.

@Suite struct EpicSignInTests {
    private let code = "0123456789abcdef0123456789abcdef"

    @Test func onlyEpicsRedirectPageIsRead() {
        func page(_ text: String) -> Bool { EpicSignIn.isRedirectPage(URL(string: text)) }
        #expect(page("https://www.epicgames.com/id/api/redirect?clientId=34a02cf8f4414e29b15921876da36f9a&responseType=code"))
        #expect(page("https://WWW.EPICGAMES.COM/id/api/redirect"))
        #expect(!page("https://www.epicgames.com/id/login?redirectUrl=x"))
        #expect(!page("https://www.epicgames.com/id/api/redirect/other"))
        #expect(!page("https://epicgames.com/id/api/redirect"))
        #expect(!page("https://www.epicgames.com.evil.example/id/api/redirect"))
        #expect(!page("https://evil.example/id/api/redirect"))
        #expect(!page("http://www.epicgames.com/id/api/redirect"))
        #expect(!EpicSignIn.isRedirectPage(nil))
    }

    @Test func theLoginPageIsEpicsWithTheRedirectForTheLauncher() {
        let url = EpicSignIn.loginURL
        #expect(url.host == "www.epicgames.com" && url.path == "/id/login")
        let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirectUrl" }?.value
        #expect(redirect == "https://www.epicgames.com/id/api/redirect?clientId=34a02cf8f4414e29b15921876da36f9a&responseType=code")
        #expect(EpicSignIn.userAgent == "Mozilla/5.0 (Windows NT 10.0; Win64; x64) EpicGamesLauncher")
    }

    @Test func theCodeComesOutOfThePagesJSON() {
        let body = #"{"redirectUrl":"https://localhost/launcher/authorized?code=\#(code)","authorizationCode":"\#(code)","exchangeCode":null,"sid":null,"ssoV2Enabled":true}"#
        #expect(EpicSignIn.code(fromPageBody: body) == code)
        #expect(EpicSignIn.code(fromPageBody: "  \n" + body + "\n") == code)
    }

    @Test func theCodeIsTakenFromTheRedirectAddressWhenTheFieldIsEmpty() {
        let body = #"{"redirectUrl":"https://localhost/launcher/authorized?code=\#(code)","authorizationCode":null}"#
        #expect(EpicSignIn.code(fromPageBody: body) == code)
    }

    @Test func aPageThatIsNotTheCodeGivesNothing() {
        for body in ["", "<html><body>Sign in</body></html>", "{}", #"{"authorizationCode":null}"#, #"{"authorizationCode":"short"}"#,
                     #"{"authorizationCode":42}"#, "[1,2]"] {
            #expect(EpicSignIn.code(fromPageBody: body) == nil, "\(body)")
        }
    }

    @Test func aLocalhostRedirectWithACodeIsRead() {
        #expect(EpicSignIn.code(fromRedirect: URL(string: "https://localhost/launcher/authorized?code=\(code)")!) == code)
        #expect(EpicSignIn.code(fromRedirect: URL(string: "http://localhost:3000/?foo=1&code=\(code)")!) == code)
        #expect(EpicSignIn.code(fromRedirect: URL(string: "https://localhost/launcher/authorized")!) == nil)
        #expect(EpicSignIn.code(fromRedirect: URL(string: "https://localhost/?code=short")!) == nil)
        // Another host with a code in its address is not a redirect for the launcher.
        #expect(EpicSignIn.code(fromRedirect: URL(string: "https://evil.example/?code=\(code)")!) == nil)
        #expect(EpicSignIn.code(fromRedirect: URL(string: "https://localhost.evil.example/?code=\(code)")!) == nil)
    }

    @Test func theLauncherNameIsToldToEpicsOwnPagesOnly() {
        func agent(_ text: String) -> Bool { EpicSignIn.usesLauncherAgent(for: URL(string: text)) }
        #expect(agent("https://www.epicgames.com/id/login"))
        #expect(agent("https://epicgames.com/id/login"))
        #expect(agent("https://accounts.epicgames.com/x"))
        #expect(!agent("https://accounts.google.com/o/oauth2/auth"))
        #expect(!agent("https://appleid.apple.com/auth"))
        #expect(!agent("https://www.epicgames.com.evil.example/"))
        #expect(!agent("https://evil.example/epicgames.com"))
        #expect(!agent("http://www.epicgames.com/"))
        #expect(!EpicSignIn.usesLauncherAgent(for: nil))
    }

    @Test func aCodeIsOnlyTakenFromTheMainFrame() {
        let url = URL(string: "https://localhost/launcher/authorized?code=\(code)")!
        #expect(EpicSignIn.code(navigatingTo: url, isMainFrame: true) == code)
        #expect(EpicSignIn.code(navigatingTo: url, isMainFrame: false) == nil)                // a frame inside a page
        let redirect = URL(string: "https://www.epicgames.com/id/api/redirect?clientId=x&responseType=code")!
        let body = #"{"authorizationCode":"\#(code)"}"#
        #expect(EpicSignIn.code(fromPage: redirect, isMainFrame: true, text: body) == code)
        #expect(EpicSignIn.code(fromPage: redirect, isMainFrame: false, text: body) == nil)
    }

    @Test func aPageThatLooksLikeTheAnswerButIsNotEpicsRedirectIsNotRead() {
        let body = #"{"authorizationCode":"\#(code)"}"#
        for address in ["https://evil.example/id/api/redirect", "https://www.epicgames.com/id/login", "http://www.epicgames.com/id/api/redirect",
                        "https://www.epicgames.com.evil.example/id/api/redirect"] {
            #expect(EpicSignIn.code(fromPage: URL(string: address), isMainFrame: true, text: body) == nil, "\(address)")
        }
        #expect(EpicSignIn.code(fromPage: nil, isMainFrame: true, text: body) == nil)
    }

    @Test func aRedirectToLocalhostIsOnlyHttpOrHttps() {
        #expect(EpicSignIn.code(fromRedirect: URL(string: "http://localhost:8080/?code=\(code)")!) == code)
        #expect(EpicSignIn.code(fromRedirect: URL(string: "https://localhost/?code=\(code)")!) == code)
        #expect(EpicSignIn.code(fromRedirect: URL(string: "ftp://localhost/?code=\(code)")!) == nil)
        #expect(EpicSignIn.code(fromRedirect: URL(string: "file://localhost/tmp/x?code=\(code)")!) == nil)
        #expect(EpicSignIn.code(fromRedirect: URL(string: "javascript://localhost/%0Aalert(1)?code=\(code)")!) == nil)
    }

    @Test func aPastedCodeMayHaveQuotesSpacesOrBeTheWholePage() {
        #expect(EpicSignIn.code(fromPasted: code) == code)
        #expect(EpicSignIn.code(fromPasted: "  \"\(code)\"\n") == code)
        #expect(EpicSignIn.code(fromPasted: #"{"redirectUrl":"x","authorizationCode":"\#(code)","exchangeCode":null}"#) == code)
    }

    @Test func aCodeIsAtLeastThirtyCharactersOfLettersAndDigits() {
        #expect(EpicSignIn.code(fromPasted: String(repeating: "a", count: 30)) != nil)
        #expect(EpicSignIn.code(fromPasted: String(repeating: "a", count: 29)) == nil)
        #expect(EpicSignIn.code(fromPasted: String(repeating: "a", count: 129)) == nil)
        // Never a dash first (it would be read as an option), nor anything that isn't part of a code.
        #expect(EpicSignIn.code(fromPasted: "-" + String(repeating: "a", count: 31)) == nil)
        #expect(EpicSignIn.code(fromPasted: String(repeating: "a", count: 20) + " " + String(repeating: "b", count: 20)) == nil)
        #expect(EpicSignIn.code(fromPasted: String(repeating: "a", count: 40) + ";rm") == nil)
    }
}
