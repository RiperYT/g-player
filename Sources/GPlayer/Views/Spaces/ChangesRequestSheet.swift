import GPlayerCore
import SwiftUI

/// "Allow G-Player to change this space?" for a space that belongs to another app. A plain sentence says what and why;
/// the technical list is under Details. Every answer goes through a button (Esc is Don't Allow), which takes the request
/// off the list.
struct ChangesRequestSheet: View {
    @Environment(AppModel.self) private var model
    let request: ChangesRequest
    @State private var showDetails = false

    var body: some View {
        let space = model.space(request.spaceID)
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow G-Player to change “\(space?.name ?? "this space")”?").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("To help games run, G-Player would like to add some Windows files to this space and change a few of its settings. Your games and saves aren't touched.")
                Text("This space\(space?.originNote.map { " (\($0))" } ?? "") belongs to another app, and G-Player uses it where it is, so it asks first.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Details", isExpanded: $showDetails) {
                Text("""
                G-Player can:
                • install Windows components such as Visual C++ into it
                • change Wine settings in its registry: per-game DLL and Windows-version settings, Retina mode, and removing ones it set before
                • put DXVK's graphics files and Steam's window fix in place of Wine's own (it keeps Wine's copies)
                • install a store app such as Steam into it, when you ask
                • move it to a newer G-Player Wine, which updates Wine's own files in it once
                • keep small notes next to drive_c about what it added
                """)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }
            Text("If you don't allow it, games start with the space as it is, and may not run. You can change this later in the space.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Don't Allow") { model.answerChangesRequest(false) }.keyboardShortcut(.cancelAction)
                Button("Allow") { model.answerChangesRequest(true) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(22).frame(width: 460)
        .interactiveDismissDisabled()
    }
}
