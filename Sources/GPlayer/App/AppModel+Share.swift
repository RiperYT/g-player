import AppKit
import Foundation
import GPlayerCore

/// What a "Share What Worked" report needs from the library, read once when its sheet opens.
struct WorkedSetup {
    let engine: EngineInfo
    /// The backend a launch would use now (`CompatPlan.backend`).
    let planned: GraphicsBackend
    /// Windows components in the game's space beyond the ones every space gets.
    let components: [String]
}

/// Share What Worked: a game that runs well can open a filled-in GitHub issue in the browser, or copy its text. G-Player
/// sends nothing itself. The report and the address are core's (`WorkedReport`, `WorkedIssue`).
extension AppModel {
    /// Offered once the game has run well (`WorkedReport.mayShare`), and not while its last start is shown as failed.
    func canShareWhatWorked(_ game: Game) -> Bool {
        WorkedReport.mayShare(game) && !didNotStart(game)
    }

    func shareWhatWorked(_ game: Game) { sharingWorked = game.id }

    func workedSetup(for game: Game) -> WorkedSetup? {
        guard let space = space(game.spaceID), let plan = compatPreview(for: game) else { return nil }
        let base = Set(RuntimeCatalog.base.map(\.id))
        return WorkedSetup(engine: engineInfo(for: space), planned: plan.backend,
                           components: installedComponents(in: space).subtracting(base).sorted())
    }

    /// Opens the "It works" form with what fits in the address. What doesn't fit is put on the clipboard to be pasted in.
    func openWorkedIssue(_ issue: WorkedIssue) {
        let submission = issue.submission
        if submission.needsPasting { copyToClipboard(issue.markdown) }
        if !NSWorkspace.shared.open(submission.url) {
            errorMessage = "Couldn't open the browser. Choose Copy, then paste the text into a new issue at github.com/\(WorkedIssue.repository)."
        }
    }

    func copyWorkedIssue(_ issue: WorkedIssue) { copyToClipboard(issue.markdown) }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
