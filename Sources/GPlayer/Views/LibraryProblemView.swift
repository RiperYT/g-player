import GPlayerCore
import SwiftUI

/// Over the window while the library can't be opened (`AppModel.libraryProblem`). G-Player writes nothing until the user
/// has chosen, so a library on a disk that isn't connected yet, or one this version can't read, is never replaced by an empty one.
struct LibraryProblemView: View {
    @Environment(AppModel.self) private var model
    let problem: LibraryProblem
    @State private var confirmEmpty = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 40, weight: .light)).foregroundStyle(.orange)
            Text(problem.title)
                .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                .lineLimit(3).truncationMode(.middle)
            Text(problem.explanation).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Try Again") { model.retryLibrary() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button("Locate…") { locate() }
                if problem.previousIsUsable { Button("Use Previous Copy") { model.restorePreviousLibrary() } }
                if problem.canStartEmpty { Button("Start Empty") { confirmEmpty = true } }
            }
            .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(problem.buttonHelp, id: \.self) { Text($0) }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
        .frame(maxWidth: 480)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Start with an empty library?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Start Empty", role: .destructive) { model.startEmptyLibrary() }
        } message: {
            Text(problem.startEmptyConsequence)
        }
    }

    private func locate() {
        let start = problem.root.deletingLastPathComponent()
        if let folder = Panels.chooseFolder(message: "Choose your library folder, the one that holds library.json.", start: start) {
            model.locateLibrary(folder)
        }
    }
}
