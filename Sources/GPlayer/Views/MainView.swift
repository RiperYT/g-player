import GPlayerCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

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
                case .hidden: LibraryView(filter: .hidden)
                case .space(let id): if let s = model.space(id) { SpaceView(space: s) } else { LibraryView(filter: .all) }
                case .files: FilesView()
                case .apps: AppsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $model.showAddGame) { AddGameSheet(initialSource: model.addGameSource) }
        .sheet(isPresented: $model.showNewSpace) { NewSpaceSheet() }
        .sheet(isPresented: Binding(get: { model.failedLaunch != nil }, set: { if !$0 { model.failedLaunch = nil } })) {
            if let g = model.game(model.failedLaunch) { FailedLaunchSheet(game: g) }
        }
        .alert("Steam has to close for a minute", isPresented: Binding(get: { model.launcherQuit != nil },
                                                                     set: { if !$0 { model.launcherQuit = nil } }),
               presenting: model.launcherQuit) { request in
            Button("Close Steam and Install") { model.quitSteamThenInstall(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("Windows installers need the space to themselves. G-Player closes Steam, installs \(model.componentsLabel(request.components)), then starts \(model.game(request.gameID)?.title ?? "the game") again, which opens Steam with it.")
        }
        .alert("This game may not run", isPresented: Binding(get: { model.blockedLaunch != nil },
                                                             set: { if !$0 { model.blockedLaunch = nil } }),
               presenting: model.blockedLaunch) { blocked in
            if blocked.notes.contains(where: { $0.title == CompatResolver.needsDirectX12 }),
               let space = model.game(blocked.gameID).flatMap({ model.space($0.spaceID) }) {
                if !model.d3dMetalAvailable {
                    Button("Set Up Apple's D3DMetal…") { openSettings() }
                } else if space.engineID != EngineCatalog.crossover.id {
                    Button("Move Space to G-Player Wine…") { model.offerGPlayerWine(for: blocked.gameID) }
                }
            }
            Button("Play Anyway") {
                model.acknowledgedBlockers.insert(blocked.gameID)
                if let g = model.game(blocked.gameID) { model.play(g, skipping: blocked.skipped.union([.blockers])) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { blocked in
            Text(blocked.notes.map { [$0.title, $0.detail].compactMap { $0 }.joined(separator: ". ") }.joined(separator: "\n\n"))
        }
        .alert("Move this space to G-Player Wine?", isPresented: Binding(get: { model.engineMove != nil },
                                                                        set: { if !$0 { model.engineMove = nil } }),
               presenting: model.engineMove) { move in
            Button("Move and Play") { model.moveToGPlayerWine(move.gameID) }
            Button("Cancel", role: .cancel) {}
        } message: { move in
            Text("Every program in “\(move.spaceName)” will run on G-Player Wine (Wine 11.0, from CrossOver's source) instead of \(move.fromEngine)\(move.olderWine ? ", an older Wine than the space has now" : ""); the space's files are updated for it on the first start. Steam closes first if it's open.\(move.downloadMB > 0 ? " G-Player Wine downloads first (about \(move.downloadMB) MB)." : "") You can switch back in the space's settings.")
        }
        .alert("Steam is already running", isPresented: Binding(get: { model.steamRestart != nil },
                                                                set: { if !$0 { model.steamRestart = nil } }),
               presenting: model.steamRestart) { request in
            Button("Restart Steam and Play") { model.restartSteamAndPlay(request) }
            Button("Play Anyway") {
                if let g = model.game(request.gameID) { model.play(g, skipping: request.skipped.union([.runningSteam])) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("Steam starts games with the settings it had when it opened, so \(model.game(request.gameID)?.title ?? "this game")'s profile and fixes only reach it after a restart. Restarting quits Steam first, which pauses its downloads and closes other games it runs. Play Anyway starts the game with Steam's current settings.")
        }
        // Every answer goes through a button (Esc is Don't Allow), which takes the request off the list.
        .alert(changesTitle, isPresented: Binding(get: { model.changesRequest != nil }, set: { _ in }),
               presenting: model.changesRequest) { _ in
            Button("Allow") { model.answerChangesRequest(true) }
            Button("Don't Allow", role: .cancel) { model.answerChangesRequest(false) }
        } message: { request in
            let where_ = model.space(request.spaceID)?.originNote.map { " (\($0))" } ?? ""
            Text("""
            This space\(where_) belongs to another app, and G-Player uses it in place. To help games run, G-Player can:
            • install Windows components such as Visual C++ into it
            • change Wine settings in its registry: per-game DLL and Windows-version settings, Retina mode, and removing ones it set before
            • put DXVK's graphics files and Steam's window fix in place of Wine's own (it keeps Wine's copies)
            • install a store app such as Steam into it, when you ask
            • keep small notes next to drive_c about what it added

            Your games and saves stay untouched. If you don't allow it, games start with the space as it is, and may not run. You can change this later in the space.
            """)
        }
        .confirmationDialog("Remove from Library?", isPresented: Binding(get: { model.gamePendingRemoval != nil },
                                                                        set: { if !$0 { model.gamePendingRemoval = nil } }),
                            titleVisibility: .visible, presenting: model.gamePendingRemoval) { game in
            Button("Remove “\(game.title)”", role: .destructive) { model.remove(game) }
        } message: { game in
            Text("“\(game.title)” leaves the library. Its files stay in the space, and you can add it again.")
        }
    }
}

extension MainView {
    private var changesTitle: String {
        "Allow G-Player to change “\(model.space(model.changesRequest?.spaceID)?.name ?? "this space")”?"
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
                if !model.hiddenGames.isEmpty { HiddenRow(count: model.hiddenGames.count).tag(SidebarItem.hidden) }
            }
            Section("Spaces") {
                ForEach(model.spaces) { space in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(space.color).frame(width: 12, height: 12)
                        Text(space.name).lineLimit(1)
                        Spacer()
                        let count = model.visibleGames(in: space).count
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

/// "Hidden" under Library, with how many games are in it.
private struct HiddenRow: View {
    let count: Int

    var body: some View {
        HStack {
            Label("Hidden", systemImage: "eye.slash")
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
    }
}
