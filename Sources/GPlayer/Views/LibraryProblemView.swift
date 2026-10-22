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
            Text("G-Player can't read your library at \(shown(problem.root))")
                .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                .lineLimit(3).truncationMode(.middle)
            Text(explanation).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Try Again") { model.retryLibrary() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button("Locate…") { locate() }
                if problem.previousIsUsable { Button("Use Previous Copy") { model.restorePreviousLibrary() } }
                Button("Start Empty") { confirmEmpty = true }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 480)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Start with an empty library?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Start Empty", role: .destructive) { model.startEmptyLibrary() }
        } message: {
            Text(emptyConsequence)
        }
    }

    private func locate() {
        let start = problem.root.deletingLastPathComponent()
        if let folder = Panels.chooseFolder(message: "Choose your library folder, the one that holds library.json.", start: start) {
            model.locateLibrary(folder)
        }
    }

    private func shown(_ url: URL) -> String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    /// What is wrong, and what each button is for.
    private var explanation: String {
        switch problem.kind {
        case .folderMissing:
            return "The folder isn't there. If your library is on an external disk, connect it and choose Try Again. "
                + "If you moved or renamed the folder, choose Locate… and pick it. Nothing has been changed."
        case .fileMissing:
            return "The folder is there, but library.json isn't."
                + (problem.previousIsUsable ? " Use Previous Copy brings back the library as it was before its last change." : "")
                + " Nothing has been changed."
        case .unreadable:
            let kept = problem.brokenCopy.map { "G-Player saved a copy as \($0.lastPathComponent) next to it" }
                ?? "G-Player couldn't save a copy, so it won't replace the file"
            return "library.json is damaged (\(problem.reason)). \(kept) and changed nothing else."
        }
    }

    private var emptyConsequence: String {
        switch problem.kind {
        case .folderMissing:
            return "G-Player makes a new library in \(shown(problem.root)). Your spaces and games leave the library. "
                + "If it is on a disk that isn't connected, choose Try Again instead."
        case .fileMissing:
            return "Your spaces and games leave the library. library.json.previous stays next to it."
        case .unreadable:
            return "Your spaces and games leave the library. The damaged file stays next to it"
                + (problem.brokenCopy.map { " as \($0.lastPathComponent)." } ?? ".")
        }
    }
}
