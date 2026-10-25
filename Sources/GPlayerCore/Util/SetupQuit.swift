import Foundation

/// What G-Player says when it is asked to quit in the middle of setting something up (engine downloads, making a
/// space, installing Windows components or a store app), and when it doesn't ask.
public enum SetupQuit {
    /// What quitting costs.
    public enum Outcome: Equatable, Sendable {
        /// The first spaces are still on the list, so the next start goes on with them by itself.
        case resumes
        /// The welcome steps aren't done: the next start shows them again, and the download goes on from where it stopped
        /// once the user gets that far.
        case continuesInWelcome
        /// Nothing starts it again by itself: the user has to ask. Downloads keep what came.
        case stops
    }

    /// What the next start will do with the work that is cut short. Only the first run is picked up by itself: its first
    /// spaces are on a saved list (`pendingFirstRunSpaces`) that `AppModel.resumeFirstRunSpaces` goes through at start.
    public static func outcome(onboardingDone: Bool, pendingFirstRunSpaces: Bool) -> Outcome {
        guard onboardingDone else { return .continuesInWelcome }
        return pendingFirstRunSpaces ? .resumes : .stops
    }

    /// "downloading G-Player Wine", "creating “Main” and setting up Steam", "a, b and 2 more": the sidebar's titles read as a
    /// phrase. A title that comes twice counts once.
    public static func summary(of titles: [String]) -> String {
        var seen = Set<String>()
        let phrases = titles.filter { seen.insert($0).inserted }.map { title in
            title.prefix(1).lowercased() + title.dropFirst()
        }
        switch phrases.count {
        case 0: return String(localized: "setting up")
        case 1: return phrases[0]
        case 2: return String(localized: "\(phrases[0]) and \(phrases[1])")
        default: return String(localized: "\(phrases[0]), \(phrases[1]) and \(phrases.count - 2) more")
        }
    }

    /// The question for the Quit dialog: what is still running, and what quitting costs.
    public static func question(titles: [String], outcome: Outcome) -> (title: String, detail: String) {
        let tail: String
        switch outcome {
        case .resumes: tail = String(localized: "Setup continues the next time G-Player opens.")
        case .continuesInWelcome: tail = String(localized: "The download stops now. What came is kept, and it goes on from there when you continue the welcome steps again.")
        case .stops: tail = String(localized: "The setup stops now, and you can start it again later.")
        }
        return (String(localized: "G-Player is still setting up (\(summary(of: titles)))."), String(localized: "Quit anyway? \(tail)"))
    }

    // MARK: Who asked

    /// The reasons a quit Apple event carries when the system asks, not the user: shut down, restart, log out. The
    /// four-character codes of `kAEShutDown`, `kAERestart`, `kAEReallyLogOut` and `kAELogOut`.
    static let systemReasons = Set(["shut", "rest", "rlgo", "logo"].map(fourCharCode))

    /// True when the quit comes from the system going down or the user logging out: a question that can stop it would block
    /// the Mac from shutting down, so G-Player quits without asking.
    public static func isSystemQuit(reason: UInt32?) -> Bool {
        reason.map { systemReasons.contains($0) } ?? false
    }

    /// True when a question may stop the quit that is being handled. Not when the Mac is going down (`isSystemQuit`), and
    /// not when the quit is Sparkle's, for an update the user just said yes to: the installer waits for G-Player to quit, and
    /// a question that is answered with "Keep Setting Up" would leave it waiting.
    public static func mayAsk(systemIsGoingDown: Bool, reason: UInt32?, updateIsInstalling: Bool) -> Bool {
        !systemIsGoingDown && !isSystemQuit(reason: reason) && !updateIsInstalling
    }

    static func fourCharCode(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
}
