import Foundation
import Testing
@testable import GPlayerCore

/// "Share What Worked": the GitHub address and the Markdown copy.
@Suite struct WorkedIssueTests {
    let redaction = WorkedReport.Redaction(homeFolder: "/Users/jane", names: ["jane"])
    let machine = WorkedReport.Machine(appVersion: "0.4.3", macOSVersion: "15.4", chip: "Apple M2 Pro")

    func report(environment: [String: String] = [:]) -> WorkedReport {
        let game = Game(title: "Sample Game", spaceID: UUID(), environment: environment)
        return WorkedReport(game: game, engine: EngineCatalog.wineStaging, planned: .dxvk, components: [], machine: machine,
                            redaction: redaction)
    }

    func issue(game: String = "Sample Game", notes: String = "", environment: [String: String] = [:]) -> WorkedIssue {
        WorkedIssue(game: game, notes: notes, report: report(environment: environment), redaction: redaction)
    }

    func items(_ url: URL) -> [String: String] {
        let found = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0.value ?? "") })
    }

    // MARK: The address

    @Test func theAddressOpensTheNewIssueFormOfTheRepositoryWithTheTemplateAndItsFields() {
        let sub = issue(notes: "Needed the xact component").submission
        #expect(sub.fit == .complete && !sub.needsPasting)
        #expect(sub.url.scheme == "https" && sub.url.host == "github.com" && sub.url.path == "/RiperYT/g-player/issues/new")
        let q = items(sub.url)
        #expect(q["template"] == "works.yml")
        #expect(q["title"] == "Works: Sample Game")
        #expect(q["game"] == "Sample Game")
        #expect(q["details"] == report().text)
        #expect(q["notes"] == "Needed the xact component")
        #expect(Set(q.keys) == ["template", "title", "game", "details", "notes"])
    }

    @Test func theTemplateHasTheFieldsTheAddressFills() throws {
        // …/Tests/GPlayerCoreTests/WorkedIssueTests.swift → the repository root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let form = try String(contentsOf: root.appendingPathComponent(".github/ISSUE_TEMPLATE/\(WorkedIssue.template)"), encoding: .utf8)
        for field in ["game", "details", "notes"] { #expect(form.contains("id: \(field)")) }
        #expect(form.contains("title: \"Works: \""))
    }

    @Test func valuesArePercentEncodedAsUTF8AndNothingWithAMeaningInAnAddressIsLeftAsItIs() {
        let notes = "a&b=c#d+e%20f ~g\nsecond line\t“Привіт” 日本語 🎮"
        let sub = issue(game: "Sample & Co: 100% #1", notes: notes).submission
        let text = sub.url.absoluteString
        let query = String(text[text.range(of: "?")!.upperBound...])
        // Only unreserved characters and %XX are in the query, besides the & and = that separate it.
        let separators = query.replacingOccurrences(of: "%[0-9A-F]{2}", with: "", options: .regularExpression)
        #expect(separators.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~&=".contains($0)) })
        #expect(query.contains("notes=a%26b%3Dc%23d%2Be%2520f%20~g%0Asecond%20line%09"))
        #expect(query.contains("title=Works%3A%20Sample%20%26%20Co%3A%20100%25%20%231"))
        // And it reads back as what was typed.
        let q = items(sub.url)
        #expect(q["notes"] == notes)
        #expect(q["game"] == "Sample & Co: 100% #1")
        #expect(q["title"] == "Works: Sample & Co: 100% #1")
        #expect(q["details"] == report().text)
    }

    @Test func emptyFieldsAreLeftOutOfTheAddress() {
        let q = items(issue(notes: "").submission.url)
        #expect(q["notes"] == nil)
        let blank = items(issue(game: "  ").submission.url)
        #expect(blank["game"] == nil && blank["title"] == "Works:")
    }

    @Test func encodingIsReversibleForEverySingleASCIICharacter() {
        let all = String((UInt8(0x20)...0x7E).map { Character(UnicodeScalar($0)) })
        #expect(WorkedIssue.encode(all).removingPercentEncoding == all)
        #expect(WorkedIssue.encode("A-Za-z0-9._~") == "A-Za-z0-9._~")
    }

    // MARK: What the user typed

    @Test func theGameNameIsOneTrimmedShortLine() {
        #expect(issue(game: "  Sample\nGame  ").game == "Sample Game")
        #expect(issue(game: String(repeating: "g", count: 500)).game.count == WorkedIssue.maxGameLength)
        #expect(issue(game: "").title == "Works:")
        #expect(issue(game: "Sample Game").title == "Works: Sample Game")
    }

    @Test func aHomeFolderInTheNameOrTheNotesBecomesATilde() {
        let i = issue(game: "/Users/jane/Games/Sample", notes: "  Config is in /Users/jane/Library/Sample\n")
        #expect(i.game == "~/Games/Sample")
        #expect(i.notes == "Config is in ~/Library/Sample")
        #expect(!i.markdown.contains("/Users") && !i.submission.url.absoluteString.contains("jane"))
    }

    // MARK: The Markdown copy

    @Test func theCopyIsTheTitleTheDetailsAsACodeBlockAndTheNotes() {
        let i = issue(notes: "Works at 60 fps.")
        #expect(i.markdown == """
            **Works: Sample Game**

            ```text
            \(report().text)
            ```

            Notes:

            Works at 60 fps.
            """)
        #expect(!issue().markdown.contains("Notes:"))
    }

    // MARK: Too long for an address

    @Test func longNotesAreCutFirstAndTheRestIsLeftToThePaste() {
        let notes = String(repeating: "word ", count: 3000)
        let i = issue(notes: notes)
        let sub = i.submission
        #expect(sub.fit == .notesShortened && sub.needsPasting)
        #expect(sub.url.absoluteString.count <= WorkedIssue.maxAddressLength)
        let q = items(sub.url)
        #expect(q["details"] == report().text)                       // the details are all there
        let cut = q["notes"] ?? ""
        #expect(cut.hasSuffix("…") && cut.count > 100)
        #expect(notes.hasPrefix(String(cut.dropLast())))
        // The longest start that fits: it is cut to the limit, not shorter (the next word wouldn't fit).
        #expect(sub.url.absoluteString.count > WorkedIssue.maxAddressLength - 10)
        // The full text is what gets copied.
        #expect(i.markdown.contains(notes.trimmingCharacters(in: .whitespaces)))
    }

    @Test func detailsThatAloneAreTooLongAreLeftOutAndTheFormOpensWithTheGameOnly() {
        let environment = Dictionary(uniqueKeysWithValues: (0..<400).map { ("VARIABLE_NUMBER_\($0)", "value-\($0)-" + String(repeating: "v", count: 60)) })
        let i = issue(notes: "A note", environment: environment)
        let sub = i.submission
        #expect(sub.fit == .detailsLeftOut && sub.needsPasting)
        #expect(sub.url.absoluteString.count <= WorkedIssue.maxAddressLength)
        let q = items(sub.url)
        #expect(q["details"] == nil && q["notes"] == nil)
        #expect(q["game"] == "Sample Game" && q["title"] == "Works: Sample Game" && q["template"] == "works.yml")
        #expect(i.markdown.contains("VARIABLE_NUMBER_399") && i.markdown.contains("A note"))
    }

    @Test func theLimitIsAParameterAndAnAddressExactlyAtItStaysComplete() {
        let i = issue(notes: "A note")
        let exact = i.address(details: i.details, notes: i.notes).absoluteString.count
        #expect(i.submission(maxLength: exact).fit == .complete)
        #expect(i.submission(maxLength: exact - 1).fit == .notesShortened)
        #expect(WorkedIssue.maxAddressLength == 7_000)
    }
}
