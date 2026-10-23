import GPlayerCore
import SwiftUI

/// An Epic game whose files aren't where Legendary says (the library moved, a disk is away, the folder was changed): what is
/// wrong and what can be done about it. Shown in the game's panel; nothing when the game is fine.
struct EpicFilesNote: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        if let note = model.epicNote(for: game) {
            VStack(alignment: .leading, spacing: 8) {
                Label(note.title, systemImage: "exclamationmark.triangle.fill").font(.callout.weight(.medium)).foregroundStyle(.orange)
                Text(note.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { EpicProblemButtons(game: game) }
            }
        }
    }
}

/// Repair, when the files are in this library's Epic Games space, and Remove….
struct EpicProblemButtons: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        if case .filesNotFound(.some) = model.epicHealth(of: game) {
            Button("Repair") { model.repairEpicGame(game) }
                .buttonStyle(.borderedProminent)
                .disabled(model.epic.isOccupied)
                .help("Points Legendary's record at the files in this library")
        }
        Button("Remove…") { model.gamePendingForget = game }
            .disabled(model.epic.isOccupied)
            .help("Removes it from the library. No file is deleted.")
    }
}
