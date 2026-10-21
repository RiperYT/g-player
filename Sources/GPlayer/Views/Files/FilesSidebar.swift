import GPlayerCore
import SwiftUI

/// The left column of Files: which space you're in (a big switcher at the top), then the places inside it.
/// The main sidebar already lists spaces, so this column doesn't repeat that list.
struct FilesSidebar: View {
    let space: Space
    let places: [SpacePlace]
    /// The folder the table shows.
    let current: URL
    let go: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpaceSwitcher(space: space)
                .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 8)
            List(selection: Binding<SpacePlace.Kind?>(get: { currentPlace?.id }, set: { id in
                if let place = places.first(where: { $0.id == id }) { go(place.url) }
            })) {
                Section("Places") {
                    ForEach(places) { place in
                        Label(place.label, systemImage: place.symbol).lineLimit(1).tag(place.id)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var currentPlace: SpacePlace? {
        places.first { $0.url.standardizedFileURL.path == current.standardizedFileURL.path }
    }
}

/// The space whose files you're looking at, as a full-width menu.
private struct SpaceSwitcher: View {
    @Environment(AppModel.self) private var model
    let space: Space

    var body: some View {
        Menu {
            ForEach(model.spaces) { s in
                Button { model.filesSpaceID = s.id } label: {
                    if s.id == space.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                }
            }
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(space.color).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Space").font(.caption2).foregroundStyle(.secondary)
                    Text(space.name).font(.body.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Choose which space's files to show")
    }
}

extension SpacePlace {
    var symbol: String {
        switch kind {
        case .drive: "internaldrive"
        case .games: "gamecontroller"
        case .programFiles: "macwindow"
        case .programFilesX86: "macwindow.on.rectangle"
        case .documents: "doc.text"
        case .appData: "archivebox"
        case .spaceFolder: "folder"
        }
    }
}
