import GPlayerCore
import SwiftUI

/// "Share What Worked…": opens a filled-in GitHub issue in the browser, or copies the text. The name of the game starts
/// empty (G-Player never puts a game's name anywhere by itself), and the preview is exactly the text that is shared.
struct ShareWorkedSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: Game
    let setup: WorkedSetup
    @State private var name = ""
    @State private var notes = ""
    @State private var includeSteamAppID = false
    @State private var copied = false
    @State private var machine = WorkedReport.Machine.current()

    private var issue: WorkedIssue {
        let redaction = WorkedReport.Redaction.current
        let report = WorkedReport(game: game, engine: setup.engine, planned: setup.planned, components: setup.components,
                                  machine: machine, redaction: redaction, includesSteamAppID: includeSteamAppID)
        return WorkedIssue(game: name, notes: notes, report: report, redaction: redaction)
    }

    var body: some View {
        let issue = issue
        let ready = !issue.game.isEmpty
        VStack(alignment: .leading, spacing: 14) {
            Text("Share What Worked").font(.headline)
            Text("Open GitHub shows a new issue in your browser with the details below filled in. Nothing is sent until you submit it there.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            fields
            if case .steam = game.source {
                Toggle("Include the Steam app ID (helps match the game)", isOn: $includeSteamAppID)
                    .toggleStyle(.checkbox).font(.callout)
            }
            ReportPreview(text: issue.markdown, fit: issue.submission.fit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(copied ? "Copied" : "Copy") { model.copyWorkedIssue(issue); copied = true }
                    .disabled(!ready || copied).help(ready ? "" : "Enter the game's name first.")
                Button("Open GitHub") { open(issue) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!ready).help(ready ? "" : "Enter the game's name first.")
            }
        }
        .padding(22).frame(width: 520)
        .onChange(of: issue.markdown) { copied = false }
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Game").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Game", text: $name, prompt: Text("Game name")).labelsHidden().textFieldStyle(.roundedBorder)
                    Button("Use “\(game.title)”") { name = game.title }
                        .controlSize(.small).lineLimit(1).truncationMode(.tail).frame(maxWidth: 190)
                        .help("Fills in the name this game has in your library")
                }
            }
            GridRow {
                Text("Notes").foregroundStyle(.secondary)
                TextField("Notes", text: $notes, prompt: Text("Optional: what you changed or noticed"), axis: .vertical)
                    .labelsHidden().textFieldStyle(.roundedBorder).lineLimit(3...5)
            }
        }
        .font(.callout)
    }

    /// An address that can't carry it all goes to the form with what fits; the full text is on the clipboard then, and
    /// the sheet stays, still saying so.
    private func open(_ issue: WorkedIssue) {
        model.openWorkedIssue(issue)
        if !issue.submission.needsPasting { dismiss() }
    }
}

/// The text that is shared, read-only, and a line when it is too long for the address.
private struct ReportPreview: View {
    let text: String
    let fit: WorkedIssue.Fit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview").sectionTitle()
            ScrollView {
                Text(text).font(Theme.path).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 190)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if fit != .complete {
                Label("Too long for a link, so Open GitHub also copies the full text. Paste it into the form.",
                      systemImage: "doc.on.clipboard")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
