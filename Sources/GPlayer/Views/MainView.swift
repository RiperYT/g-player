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
        .sheet(isPresented: $model.epic.showSignIn) { EpicSignInSheet() }
        .sheet(isPresented: Binding(get: { model.failedLaunch != nil }, set: { if !$0 { model.failedLaunch = nil } })) {
            if let g = model.game(model.failedLaunch) { FailedLaunchSheet(game: g) }
        }
        .sheet(isPresented: Binding(get: { model.sharingWorked != nil }, set: { if !$0 { model.sharingWorked = nil } })) {
            if let g = model.game(model.sharingWorked), let setup = model.workedSetup(for: g) { ShareWorkedSheet(game: g, setup: setup) }
        }
        .alert("Steam has to close for a minute", isPresented: Binding(get: { model.launcherQuit != nil },
                                                                     set: { if !$0 { model.launcherQuit = nil } }),
               presenting: model.launcherQuit) { request in
            Button("Close Steam and Install") { model.quitSteamThenInstall(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("Windows installers need the space to themselves. G-Player closes Steam, installs \(model.componentsLabel(request.components)), then starts \(model.game(request.gameID)?.title ?? String(localized: "the game", comment: "Inside “…then starts … again”: the game that is waiting")) again, which opens Steam with it.")
        }
        .alert("This game may not run", isPresented: Binding(get: { model.blockedLaunch != nil },
                                                             set: { if !$0 { model.blockedLaunch = nil } }),
               presenting: model.blockedLaunch) { blocked in
            if blocked.notes.contains(where: { $0.title == CompatResolver.needsDirectX12 }),
               let space = model.game(blocked.gameID).flatMap({ model.space($0.spaceID) }) {
                if !model.d3dMetalAvailable {
                    Button("Set Up Apple's D3DMetal…") { SettingsTab.engines.show(.toolkit); openSettings() }
                } else if !EngineCatalog.isRevision(space.engineID, of: EngineCatalog.crossover) {
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
        .alert("Close the game and try other graphics?", isPresented: Binding(get: { model.pendingOtherGraphics != nil },
                                                                              set: { if !$0 { model.pendingOtherGraphics = nil } }),
               presenting: model.pendingOtherGraphics) { request in
            Button("Close and Try Again") { model.tryOtherGraphics(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(model.otherGraphicsMessage(for: request))
        }
        .alert("Move this space to G-Player Wine?", isPresented: Binding(get: { model.engineMove != nil },
                                                                        set: { if !$0 { model.engineMove = nil } }),
               presenting: model.engineMove) { move in
            Button("Move and Play") { model.moveToGPlayerWine(move.gameID) }
            Button("Cancel", role: .cancel) {}
        } message: { move in
            Text(model.engineMoveMessage(move))
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
            Text("Steam starts games with the settings it had when it opened, so \(model.game(request.gameID)?.title ?? String(localized: "this game", comment: "Inside “so …’s profile and fixes only reach it”"))'s profile and fixes only reach it after a restart. Restarting quits Steam first, which pauses its downloads and closes other games it runs. Play Anyway starts the game with Steam's current settings.")
        }
        .sheet(isPresented: Binding(get: { model.changesRequest != nil }, set: { _ in })) {
            if let request = model.changesRequest { ChangesRequestSheet(request: request) }
        }
        .confirmationDialog("Remove from Library?", isPresented: Binding(get: { model.gamePendingRemoval != nil },
                                                                        set: { if !$0 { model.gamePendingRemoval = nil } }),
                            titleVisibility: .visible, presenting: model.gamePendingRemoval) { game in
            Button("Remove “\(game.title)”", role: .destructive) { model.remove(game) }
        } message: { game in
            Text("“\(game.title)” leaves the library. Its files stay in the space, and you can add it again.")
        }
        .confirmationDialog("Remove from Epic Games?", isPresented: Binding(get: { model.gamePendingForget != nil },
                                                                           set: { if !$0 { model.gamePendingForget = nil } }),
                            titleVisibility: .visible, presenting: model.gamePendingForget) { game in
            Button("Remove “\(game.title)”", role: .destructive) { model.forgetEpicGame(game) }
        } message: { game in
            Text(model.epicNote(for: game)?.removal ?? "")
        }
        .confirmationDialog("Uninstall from Epic Games?", isPresented: Binding(get: { model.gamePendingUninstall != nil },
                                                                              set: { if !$0 { model.gamePendingUninstall = nil } }),
                            titleVisibility: .visible, presenting: model.gamePendingUninstall) { game in
            Button("Uninstall “\(game.title)”", role: .destructive) { model.uninstallEpicGame(game) }
        } message: { game in
            Text("Deletes “\(game.title)” and its files from the space. Saves the game keeps outside its own folder stay. Your Epic account keeps the game, so you can install it again.")
        }
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
                        if count > 0 { Text(verbatim: "\(count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
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
            Text(verbatim: "\(count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
    }
}
