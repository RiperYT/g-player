import Foundation

/// The GitHub issue "Share What Worked" opens: the repository's "It works" form (`.github/ISSUE_TEMPLATE/works.yml`),
/// filled in from the report. G-Player only opens the address in the browser, or copies the text: nothing is sent until
/// the user submits the form on GitHub.
public struct WorkedIssue: Sendable, Equatable {
    public static let repository = "RiperYT/g-player"
    /// The form's file name, and the ids of its fields (`game`, `details`, `notes`).
    static let template = "works.yml"
    /// The address stays under this many characters; GitHub and browsers take about 8,000.
    public static let maxAddressLength = 7_000
    static let maxGameLength = 120

    /// What the user called the game. G-Player never fills it in by itself.
    public let game: String
    public let notes: String
    /// The report's lines.
    public let details: String

    /// What the user typed is trimmed, the game's name is made one line, and a home folder in either becomes "~".
    public init(game: String, notes: String, report: WorkedReport, redaction: WorkedReport.Redaction) {
        let name = redaction.scrubbing(game).split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.game = String(name.prefix(Self.maxGameLength))
        self.notes = redaction.scrubbing(notes).trimmingCharacters(in: .whitespacesAndNewlines)
        self.details = report.text
    }

    public var title: String { game.isEmpty ? "Works:" : "Works: \(game)" }

    /// What "Copy" puts on the clipboard, and what the sheet previews: the title, the details as a code block, the notes.
    public var markdown: String {
        var parts = ["**\(title)**", "```text\n\(details)\n```"]
        if !notes.isEmpty { parts.append("Notes:\n\n\(notes)") }
        return parts.joined(separator: "\n\n")
    }

    /// How much of the text the address carries.
    public enum Fit: Sendable, Equatable {
        /// All of it.
        case complete
        /// The notes were cut to fit; the details are all there.
        case notesShortened
        /// Even without notes the details are too long: the form opens with the game and no details.
        case detailsLeftOut
    }

    public struct Submission: Sendable, Equatable {
        public var url: URL
        public var fit: Fit
        /// The address doesn't carry everything, so the full text (`markdown`) goes to the clipboard, to be pasted in.
        public var needsPasting: Bool { fit != .complete }
    }

    /// The address that opens the form, within `maxAddressLength`: the notes are cut first, then the details are left out.
    public var submission: Submission { submission(maxLength: Self.maxAddressLength) }

    func submission(maxLength: Int) -> Submission {
        let fits = { (url: URL) in url.absoluteString.count <= maxLength }
        let whole = address(details: details, notes: notes)
        if fits(whole) { return Submission(url: whole, fit: .complete) }
        guard fits(address(details: details, notes: "")) else {
            return Submission(url: address(details: "", notes: ""), fit: .detailsLeftOut)
        }
        // The longest start of the notes that fits, with "…" to say it goes on. A longer start never fits better.
        let cut = { (count: Int) in
            count == 0 ? "" : self.notes.prefix(count).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        var low = 0, high = notes.count
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(address(details: details, notes: cut(middle))) { low = middle } else { high = middle - 1 }
        }
        return Submission(url: address(details: details, notes: cut(low)), fit: .notesShortened)
    }

    func address(details: String, notes: String) -> URL {
        var query = ["template=\(Self.template)", "title=\(Self.encode(title))"]
        for (field, value) in [("game", game), ("details", details), ("notes", notes)] where !value.isEmpty {
            query.append("\(field)=\(Self.encode(value))")
        }
        return URL(string: "https://github.com/\(Self.repository)/issues/new?" + query.joined(separator: "&"))!
    }

    /// Percent-encoding for a query value: everything but letters, digits and `-._~`, as UTF-8. `&`, `=`, `#`, `+`, `%`,
    /// spaces and line breaks all have a meaning in an address, so none is left as it is.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
