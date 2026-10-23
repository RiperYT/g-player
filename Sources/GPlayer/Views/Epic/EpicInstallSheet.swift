import GPlayerCore
import SwiftUI

/// The question before an Epic game is installed: where it goes, what G-Player has to fetch first, how much room it takes (once
/// Legendary has said, which takes about ten seconds; the question doesn't wait for it, but a size that doesn't fit stops it).
struct EpicInstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: EpicGame
    @State private var size: Int64?
    @State private var asking = true

    var body: some View {
        let details = model.epicInstallDetails(sizeBytes: size)
        VStack(alignment: .leading, spacing: 14) {
            Text("Install “\(game.title)”?").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(details.lines, id: \.self) { Text($0).font(.callout).fixedSize(horizontal: false, vertical: true) }
                if asking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Asking Epic how much room it takes…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let problem = details.problem { PathWarning(text: problem) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") { model.installEpicGame(game) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(details.problem != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            size = await model.epicInstallSize(of: game)
            asking = false
        }
    }
}
