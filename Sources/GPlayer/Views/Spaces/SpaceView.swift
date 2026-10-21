import GPlayerCore
import SwiftUI

struct SpaceView: View {
    @Environment(AppModel.self) private var model
    let space: Space
    @State private var size: Int64?
    @State private var found: [Shortcut] = []
    @State private var confirmRemove = false
    @State private var pendingEngine: String?

    var body: some View {
        let all = model.state.games(in: space), games = model.visibleGames(in: space)
        let hiddenCount = model.hiddenGames(in: space).count
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let preset = AppPresets.preset(space.presetID), !preset.isInstalled(in: space) {
                    presetMissing(preset)
                }
                if !games.isEmpty { GameGrid(title: "In this space", games: games.sorted { $0.title < $1.title }) }
                if !newFound(all).isEmpty { foundPrograms(newFound(all)) }
                if games.isEmpty && newFound(all).isEmpty {
                    if hiddenCount > 0 {
                        HiddenOnlyNote(count: hiddenCount)
                    } else {
                        DropZone(title: "Nothing here yet",
                                 message: "Drop a game or an installer on the library, or run a program in this space.",
                                 actions: AnyView(Button("Run a Program…") { runProgram() }))
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
        .navigationTitle(space.name)
        .toolbar { LibraryToolbar() }
        .inspector(isPresented: Binding(get: { inspected != nil }, set: { if !$0 { model.selectedGameID = nil } })) {
            if let g = inspected { GameInspector(game: g).inspectorColumnWidth(min: 280, ideal: 310, max: 380) }
        }
        .task(id: space.id) { await reload() }
        .confirmationDialog(removeTitle, isPresented: $confirmRemove) {
            if space.origin == .managed {
                Button("Move to Trash", role: .destructive) { model.removeSpace(space, deleteFiles: true) }
            }
            Button(space.origin == .managed ? "Keep Files, Remove from G-Player" : "Remove from G-Player") {
                model.removeSpace(space, deleteFiles: false)
            }
        } message: {
            Text(space.origin == .managed
                 ? "Its games leave the library. Moving to Trash also removes everything installed in it."
                 : "Its files stay where they are (\(space.originNote ?? "on this Mac")).")
        }
        .alert("Switch engine?", isPresented: Binding(get: { pendingEngine != nil }, set: { if !$0 { pendingEngine = nil } })) {
            Button("Switch") { if let e = pendingEngine { var s = space; s.engineID = e; model.update(s) }; pendingEngine = nil }
            Button("Cancel", role: .cancel) { pendingEngine = nil }
        } message: {
            Text("A newer Wine updates the space the first time it starts, and an older Wine may not open it afterwards.")
        }
    }

    /// The selected game, if it is one of this space's visible games.
    private var inspected: Game? {
        guard let g = model.game(model.selectedGameID), g.spaceID == space.id, !g.isHidden else { return nil }
        return g
    }

    private var removeTitle: String { "Remove “\(space.name)”?" }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(space.color).frame(width: 16, height: 16)
                Text(space.name).font(.largeTitle.weight(.semibold))
                if let note = space.originNote {
                    Text(note).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule())
                }
            }
            PathRow(url: space.url)
            HStack(spacing: 18) {
                Picker("Engine", selection: Binding(get: { space.engineID }, set: { if $0 != space.engineID { pendingEngine = $0 } })) {
                    ForEach(EngineCatalog.all) { info in
                        Text("\(info.name) \(info.kind == .gptk ? "(D3DMetal)" : info.version)")
                            + Text(model.isInstalled(info) ? "" : "  · not installed").foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
                Text(size.map { "\($0.formattedBytes) on disk" } ?? "Measuring…").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button { runProgram() } label: { Label("Run Program…", systemImage: "play.rectangle") }
                Button { model.filesSpaceID = space.id; model.selection = .files } label: { Label("Browse Files", systemImage: "folder") }
                Menu {
                    Button("Wine Configuration") { model.runTool("winecfg", in: space) }
                    Button("Registry Editor") { model.runTool("regedit", in: space) }
                    Button("Task Manager") { model.runTool("taskmgr", in: space) }
                    Button("Windows Explorer") { model.runTool("explorer", in: space) }
                } label: { Label("Windows Tools", systemImage: "wrench.and.screwdriver") }
                .fixedSize()
                Button { model.stopAll(in: space) } label: { Label("Stop All", systemImage: "stop.circle") }
                Spacer()
                Button(role: .destructive) { confirmRemove = true } label: { Label("Remove…", systemImage: "trash") }
            }
            .controlSize(.regular)
        }
    }

    private func presetMissing(_ preset: AppPreset) -> some View {
        HStack(spacing: 14) {
            Image(systemName: preset.symbol).font(.title2).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(preset.name) isn't installed in this space").font(.headline)
                Text(preset.summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Install \(preset.name)") { Task { await model.installPreset(preset) } }.buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func newFound(_ games: [Game]) -> [Shortcut] {
        let known = Set(games.compactMap { $0.executableURL(in: space)?.standardizedFileURL.path })
        let launcher = AppPresets.preset(space.presetID)?.executableURL(in: space).standardizedFileURL.path
        return found.filter { s in
            guard let t = s.target?.standardizedFileURL.path else { return false }
            return !known.contains(t) && t != launcher
        }
    }

    private func foundPrograms(_ list: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Found programs").sectionTitle()
            Text("Installed in this space but not in your library yet.").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(list, id: \.file) { s in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: s.target?.path ?? "")).resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name)
                            Text(s.target.map { space.windowsPath(for: $0) } ?? "").font(Theme.path).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Add to Library") {
                            guard let t = s.target else { return }
                            model.addGame(Game(title: s.name, spaceID: space.id, executablePath: Game.storedPath(for: t, in: space),
                                               arguments: s.arguments + ExecutableCandidate.chromiumArguments(for: t)))
                        }
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    if s.file != list.last?.file { Divider() }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func runProgram() {
        if let u = Panels.chooseFile(message: "Choose a Windows program to run in “\(space.name)”.", start: space.driveC,
                                     types: ["exe", "msi", "bat"]) { model.run(u, in: space) }
    }

    private func reload() async {
        let s = space
        found = await Task.detached { ShortcutScanner.programs(in: s) }.value
        size = await Task.detached { Files.allocatedSize(of: s.url) }.value
    }
}

/// Shown instead of "Nothing here yet" when every game in the space is hidden.
private struct HiddenOnlyNote: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "eye.slash").font(.title2).frame(width: 36)
            Text("\(count) hidden \(count == 1 ? "game" : "games") in this space").font(.headline)
            Spacer()
            Button("Show Hidden") { model.selection = .hidden }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct NewSpaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var engineID = EngineCatalog.wineStaging.id

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Space").font(.headline)
            Text("A space is a separate Windows: its own C: drive, settings and fonts. Give a game its own space when it needs special settings.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Main or Witcher 3"))
                Picker("Engine", selection: $engineID) {
                    ForEach(EngineCatalog.all) { info in
                        Text("\(info.name) · \(info.summary)").tag(info.id)
                    }
                }
            }
            .formStyle(.grouped).scrollDisabled(true).frame(height: 120)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    let info = EngineCatalog.info(engineID) ?? EngineCatalog.wineStaging
                    dismiss()
                    Task { if let s = await model.createSpace(name: n, engineInfo: info) { model.selection = .space(s.id) } }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 520)
    }
}
