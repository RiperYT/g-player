import GPlayerCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    enum Filter { case all, recent, hidden }

    @Environment(AppModel.self) private var model
    let filter: Filter
    var spaceID: UUID? = nil
    @State private var dropTargeted = false

    private var items: [Game] {
        var list = filter == .hidden ? model.hiddenGames : model.visibleGames
        if let spaceID { list = list.filter { $0.spaceID == spaceID } }
        if filter == .recent { list = list.filter { $0.lastPlayedAt != nil }.sorted { $0.lastPlayedAt! > $1.lastPlayedAt! } }
        else { list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }
        let q = model.searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.title.localizedCaseInsensitiveContains(q) } }
        return list
    }

    private var title: String {
        switch filter {
        case .all: "All Games"
        case .recent: "Recently Played"
        case .hidden: "Hidden"
        }
    }

    /// The selected game, if this view lists it (a hidden game only shows in Hidden).
    private var inspected: Game? {
        guard let g = model.game(model.selectedGameID), g.isHidden == (filter == .hidden) else { return nil }
        return g
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if filter == .all { notes }
                if items.isEmpty { emptyState } else { grids(items) }
            }
            .padding(Theme.pagePadding)
        }
        .navigationTitle(title)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search games")
        .toolbar { LibraryToolbar() }
        .inspector(isPresented: Binding(get: { inspected != nil }, set: { if !$0 { model.selectedGameID = nil } })) {
            if let g = inspected {
                GameInspector(game: g).inspectorColumnWidth(min: 280, ideal: 310, max: 380)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Adding a game needs the engine and Main, which the first run is still making.
            guard model.addGameBlock == nil, let url = urls.first, let source = ImportSource(url) else { return false }
            model.openAddGame(source)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted && !items.isEmpty {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2).padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private func grids(_ list: [Game]) -> some View {
        if filter == .hidden {
            GameGrid(title: "Hidden", games: list)
        } else {
            let apps = list.filter { $0.kind == .app }, games = list.filter { $0.kind == .game }
            if !apps.isEmpty, filter == .all { GameGrid(title: "Apps", games: apps) }
            if !games.isEmpty { GameGrid(title: filter == .recent ? "Recently played" : "Games", games: games) }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if filter == .recent {
            ContentUnavailableView("Nothing played yet", systemImage: "clock",
                                   description: Text("Games you start show up here."))
        } else if filter == .hidden {
            ContentUnavailableView("Nothing hidden", systemImage: "eye.slash",
                                   description: Text("Games you hide show up here."))
        } else if let status = model.firstRunStatus {
            SettingUpView(message: status, activity: model.firstRunActivity)
        } else {
            DropZone(title: "Add your first game",
                     message: "Drop a game folder, a zip, rar or 7z archive, or an installer here. G-Player copies it into a space and finds the program that starts it. Bought it on Steam or Epic? Use “Get Steam or Another Store”.",
                     targeted: dropTargeted,
                     actions: AnyView(HStack {
                         Button("Choose a File or Folder…") { model.openAddGame() }
                             .buttonStyle(.borderedProminent)
                         Button("Get Steam or Another Store") { model.selection = .apps }
                     }))
        }
    }

    /// One-time notes: what is new for someone who updated, what to do once a store is set up.
    @ViewBuilder private var notes: some View {
        let list = model.libraryNotes
        if !list.isEmpty {
            VStack(spacing: 10) { ForEach(list) { LibraryNoteBanner(note: $0) } }
        }
    }
}

struct LibraryToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.refreshStores() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Look for games Steam or Epic installed")
            Button { model.openAddGame() } label: { Label("Add Game", systemImage: "plus") }
                .disabled(model.addGameBlock != nil)
                .help(model.addGameBlock?.message ?? "Add a game folder, archive or installer")
        }
    }
}

struct GameGrid: View {
    let title: String
    let games: [Game]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).sectionTitle()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.tileMinWidth, maximum: 200), spacing: Theme.gridSpacing, alignment: .top)],
                      alignment: .leading, spacing: Theme.gridSpacing + 6) {
                ForEach(games) { GameTile(game: $0) }
            }
        }
    }
}

struct GameTile: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var hovering = false

    var body: some View {
        let selected = model.selectedGameID == game.id
        VStack(alignment: .leading, spacing: 8) {
            CoverView(game: game, hovering: hovering)
                .overlay {
                    if model.isPreparing(game) {
                        ProgressView().controlSize(.regular)
                            .frame(width: 46, height: 46)
                            .background(.white.opacity(0.92), in: Circle())
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    } else if hovering {
                        Button { model.isRunning(game) ? model.stop(game) : model.play(game) } label: {
                            Image(systemName: model.isRunning(game) ? "stop.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold)).foregroundStyle(.black.opacity(0.85))
                                .frame(width: 46, height: 46)
                                .background(.white.opacity(0.92), in: Circle())
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .help(model.isRunning(game) ? model.stopHelp(game) : "Play")
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.coverRadius + 3, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0).padding(-4))
                .scaleEffect(hovering ? 1.015 : 1)
            Text(game.title).font(.callout.weight(.medium)).lineLimit(1)
            if model.didNotStart(game) && !model.isRunning(game) && !model.isPreparing(game) {
                Label("Didn't start · see what to try", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            } else if let note = model.epicNote(for: game) {
                Label("\(note.title) · see Epic Games", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            } else {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { hovering = h } }
        .onTapGesture(count: 2) { model.play(game) }
        .onTapGesture { model.selectedGameID = game.id }
        .contextMenu { GameMenu(game: game) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Play") { model.play(game) }
    }

    private var subtitle: String {
        if model.isPreparing(game) { return model.isWaitingForInstalls(game) ? "Waiting for installs…" : "Starting…" }
        if model.isRunning(game) { return "Running" }
        if let d = game.lastPlayedAt { return "Played " + d.formatted(.relative(presentation: .named)) }
        if game.kind == .app { return "Launcher" }
        if case .executable = game.source { return "Not played yet" }
        return game.source.label
    }
}

struct GameMenu: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        Button(model.isRunning(game) ? "Stop" : "Play") { model.isRunning(game) ? model.stop(game) : model.play(game) }
        Divider()
        Button("Info and Settings") { model.selectedGameID = game.id }
        if let s = model.space(game.spaceID), let exe = game.executableURL(in: s) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exe]) }
        }
        if let s = model.space(game.spaceID) {
            Button("Go to Space “\(s.name)”") { model.selection = .space(s.id) }
        }
        if model.canShareWhatWorked(game) {
            Button("Share What Worked…") { model.shareWhatWorked(game) }
        }
        Divider()
        if game.isHidden {
            Button("Show in Library") { model.setHidden(game, false) }
        } else {
            Button("Hide") { model.setHidden(game, true) }
        }
        if game.canRemove {
            Button("Remove from Library…", role: .destructive) { model.gamePendingRemoval = game }
        }
        if case .legendary = game.source {
            Button("Uninstall…", role: .destructive) { model.gamePendingUninstall = game }
                .disabled(model.epicUninstallBlock(for: game) != nil)
        }
    }
}
