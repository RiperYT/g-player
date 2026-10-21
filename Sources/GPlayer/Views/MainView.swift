import GPlayerCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            Group {
                switch model.selection ?? .allGames {
                case .allGames: LibraryView(filter: .all)
                case .recent: LibraryView(filter: .recent)
                case .space(let id): if let s = model.space(id) { SpaceView(space: s) } else { LibraryView(filter: .all) }
                case .files: FilesView()
                case .apps: AppsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $model.showAddGame) { AddGameSheet(initialSource: model.addGameSource) }
        .sheet(isPresented: $model.showNewSpace) { NewSpaceSheet() }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Library") {
                Label("All Games", systemImage: "square.grid.2x2").tag(SidebarItem.allGames)
                Label("Recently Played", systemImage: "clock").tag(SidebarItem.recent)
            }
            Section("Spaces") {
                ForEach(model.spaces) { space in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(space.color).frame(width: 12, height: 12)
                        Text(space.name).lineLimit(1)
                        Spacer()
                        let count = model.state.games(in: space).count
                        if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
                    }
                    .tag(SidebarItem.space(space.id))
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([space.url]) }
                        Button("Stop All Programs") { model.stopAll(in: space) }
                    }
                }
                Button { model.showNewSpace = true } label: {
                    Label("New Space", systemImage: "plus").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Section("Browse") {
                Label("Files", systemImage: "folder").tag(SidebarItem.files)
                Label("Get Apps", systemImage: "square.and.arrow.down.on.square").tag(SidebarItem.apps)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { ActivityPanel() }
    }
}
