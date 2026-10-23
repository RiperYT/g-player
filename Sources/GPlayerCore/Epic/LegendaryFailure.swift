import Foundation

/// Why a Legendary command failed, in words for the user, from the end of its output. Legendary logs
/// `[cli] ERROR: …` lines, and a Python traceback when it falls over (signed out, for one).
public enum LegendaryFailure {
    public enum Kind: Equatable, Sendable {
        /// Nobody is signed in, or Epic no longer accepts the login: signing in again is the way on.
        case signedOut
        /// Another Legendary is installing, updating or removing a game.
        case busy
        /// Epic (or Legendary's own server, which a login asks too) couldn't be reached.
        case network
        /// Anything else.
        case other
    }

    public static let signedOutMessage = "You're signed out of Epic Games. Sign in again from Epic Games in the sidebar."

    /// What Legendary's log (stderr) says went wrong. Its stdout is not looked at: it can hold a game's description.
    public static func kind(stderr text: String) -> Kind {
        if text.contains("No saved credentials") || text.contains("no longer valid") || text.contains("InvalidCredentialsError") {
            return .signedOut
        }
        if text.contains("Failed to acquire installed data lock") { return .busy }
        if ["ConnectionError", "NameResolutionError", "Max retries exceeded", "Connection refused", "HTTP request for login failed"]
            .contains(where: text.contains) { return .network }
        return .other
    }

    /// The reason, as one short sentence and Legendary's exit code. A one-time code or account name that got into the output
    /// is hidden (`LaunchSecrets`).
    public static func reason(stdout: String, stderr: String, status: Int32) -> String {
        switch kind(stderr: stderr) {
        case .signedOut: return signedOutMessage
        case .busy: return "Epic Games is busy with another install. Wait for it to finish, then try again."
        case .network: return "Couldn't connect to Epic Games. Check your internet connection, then try again."
        case .other: break
        }
        let lines = (stderr + "\n" + stdout).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("[PYI-") }
        // Legendary's own explanation first; a traceback ends with the exception; else the last line there is.
        let text = lines.reversed().lazy.compactMap(explanation).first
            ?? lines.last { $0.range(of: #"^[A-Za-z_.]+(Error|Exception): "#, options: .regularExpression) != nil }
            ?? lines.last ?? ""
        let clean = LaunchSecrets.scrub(String(text.prefix(300)))
        if status == 0 { return clean.isEmpty ? "Legendary didn't say why." : clean }
        return clean.isEmpty ? "Legendary stopped with code \(status)." : "\(clean) (Legendary code \(status))"
    }

    /// The message of a log line that says something went wrong: `[cli] ERROR: …`, or the `! Failure: …` of a check that
    /// failed (not enough room on the disk).
    static func explanation(in line: String) -> String? {
        for marker in ["] ERROR: ", "] FATAL: ", "] CRITICAL: ", "! Failure: "] {
            if let range = line.range(of: marker) { return String(line[range.upperBound...]) }
        }
        return nil
    }
}
