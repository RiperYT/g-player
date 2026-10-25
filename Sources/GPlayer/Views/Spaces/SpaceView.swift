import GPlayerCore
import SwiftUI

struct SpaceView: View {
    @Environment(AppModel.self) private var model
    let space: Space
    @State private var size: Int64?
    @State private var found: [Shortcut] = []
    @State private var confirmRemove = false
    @State private var pendingEngine: String?
    /// A Windows program runs in the space, whether or not it is in the library: looked up when the engine is picked.
    @State private var programsRunning = false

    var body: some View {
        let all = model.state.games(in: space), games = model.visibleGames(in: space)
        let hiddenCount = model.hiddenGames(in: space).count
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if model.needsAppleToolkit(space) { ToolkitOffBanner() }
                if model.wineMonoNotes[space.id] != nil { LibraryNoteBanner(note: .wineMono(space.id)) }
                // One offer at a time, the bottle's consent first: a bottle of another app on the retired engine asks for its
                // owner's yes (`EngineMigration.offersMove`); a space on another engine is offered G-Player Wine (`pageOffer`), a
                // launcher space that opens only there (Epic's) also while the engine menus are on.
                if let target = model.engineMoveOffer(for: space) {
                    EngineMoveOffer(space: space, target: target)
                } else if model.engineOffer(for: space) == .move
                            || EngineSwitch.launcherNeedsMove(presetID: space.presetID, engineID: space.engineID) {
                    EngineMoveNote(space: space) { askToSwitch(to: EngineCatalog.crossover.id) }
                }
                if let preset = AppPresets.preset(space.presetID), !preset.isInstalled(in: space) {
                    presetMissing(preset)
                }
                if !games.isEmpty { GameGrid(title: "In this space", games: games.sorted { $0.title < $1.title }) }
                if !newFound(all).isEmpty { foundPrograms(newFound(all)) }
                ComponentsSection(space: space)
                if games.isEmpty && newFound(all).isEmpty {
                    if hiddenCount > 0 {
                        HiddenOnlyNote(count: hiddenCount)
                    } else {
                        emptySpace
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
                 : "Its files stay where they are (\(space.originNote ?? String(localized: "on this Mac"))).")
        }
        .alert(switchTitle, isPresented: Binding(get: { pendingEngine != nil }, set: { if !$0 { pendingEngine = nil } })) {
            Button("Move") { if let target = pendingEngine.flatMap(EngineCatalog.info) { model.switchEngine(of: space, to: target) }; pendingEngine = nil }
                .disabled(switchBlocked)
            Button("Cancel", role: .cancel) { pendingEngine = nil }
        } message: {
            Text(switchMessage)
        }
    }

    /// Nothing is moved under a program that runs in the space: a newer Wine updates its files on the first start.
    private var switchBlocked: Bool { programsRunning || model.hasRunningGames(in: space) }

    private var switchTitle: String {
        pendingEngine.flatMap(EngineCatalog.info).map { EngineSwitch.title(space: space.name, to: $0) } ?? String(localized: "Move this space?")
    }

    private var switchMessage: String {
        guard let target = pendingEngine.flatMap(EngineCatalog.info) else { return "" }
        if switchBlocked { return EngineSwitch.busyMessage(space: space.name) }
        return EngineSwitch.message(space: space.name, from: EngineCatalog.info(space.engineID), to: target,
                                    downloadBytes: model.downloadSize(of: target))
    }

    /// The page of a space with nothing in it. Not a drop target (the library takes drops), so it isn't drawn as one.
    private var emptySpace: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "tray")
        } description: {
            Text("Run a program in this space, or add a game and choose this space for it.")
        } actions: {
            HStack {
                Button("Run a Program…") { runProgram() }.buttonStyle(.borderedProminent)
                Button("Add a Game…") { model.openAddGame() }
                    .disabled(model.addGameBlock != nil)
                    .help(model.addGameBlock?.message ?? "")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    /// The selected game, if it is one of this space's visible games.
    private var inspected: Game? {
        guard let g = model.game(model.selectedGameID), g.spaceID == space.id, !g.isHidden else { return nil }
        return g
    }

    private var removeTitle: LocalizedStringKey { "Remove “\(space.name)”?" }

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
            if EpicGames.isGamesSpace(space) { EpicLibraryLink() }
            HStack(spacing: 18) {
                if case .picker(let selected) = model.engineOffer(for: space) {
                    Picker("Engine", selection: Binding(get: { selected }, set: { if $0 != selected { askToSwitch(to: $0) } })) {
                        ForEach(EngineCatalog.all) { info in
                            Text(info.displayName) + Text(model.engineNote(info)).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
                }
                Text(size.map { String(localized: "\($0.formattedBytes) on disk") } ?? String(localized: "Measuring…")).font(.callout).foregroundStyle(.secondary)
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
                .disabled(model.installingSpaces.contains(space.id))
                .help(model.installingSpaces.contains(space.id) ? "Waits for the installs in this space to finish." : "")
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

    private func askToSwitch(to engineID: String) {
        let s = space
        Task {
            programsRunning = await AppModel.isBusy(s)
            pendingEngine = engineID
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

/// The Epic Games space holds the games installed through Legendary; the account and the rest of the library are on Epic's page.
private struct EpicLibraryLink: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.openEpicLibrary() } label: { Label(EpicGames.libraryTitle, systemImage: "shippingbox") }
            .buttonStyle(.link)
    }
}

/// A space that runs on Apple's toolkit while it is turned off in Settings.
private struct ToolkitOffBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Needs Apple's Game Porting Toolkit, which is turned off").font(.callout.weight(.semibold))
                Text("Programs in this space won't start until you turn it on, or move the space to G-Player Wine. Apple's license allows the toolkit for developing, testing and evaluating games; G-Player only uses the copy you installed.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Turn On") { model.useAppleToolkit = true }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A space on an engine new spaces don't use (Wine Staging, or Apple's toolkit): says so in plain words, and offers G-Player Wine.
/// The question that follows says what moving does (`EngineSwitch.message`), and nothing moves without a yes.
private struct EngineMoveNote: View {
    @Environment(AppModel.self) private var model
    let space: Space
    let move: () -> Void

    private var info: EngineInfo? { EngineCatalog.info(space.engineID) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle").foregroundStyle(.secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(info?.kind == .gptk ? "This space runs on Apple's Game Porting Toolkit" : "This space runs on \(info?.shortName ?? String(localized: "an older engine"))")
                    .font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Move to G-Player Wine…", action: move).disabled(model.movingSpaces.contains(space.id))
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var detail: String {
        if let reason = EngineSwitch.launcherMoveDetail(presetID: space.presetID) { return reason }
        let newer = String(localized: "New spaces use G-Player Wine, which plays game videos and can use Apple's D3DMetal. Moving asks first.")
        return info?.kind == .gptk
            ? String(localized: "It keeps running while the toolkit is installed and turned on in Settings.") + " " + newer : newer
    }
}

/// A bottle of another app that is on a retired engine, once the newer one is ready: one sentence and the yes. Nothing is
/// written into the bottle before it.
private struct EngineMoveOffer: View {
    @Environment(AppModel.self) private var model
    let space: Space
    let target: EngineInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.accentColor).font(.title3)
            Text(EngineMigration.moveOffer(to: target)).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Move Bottle") { model.acceptEngineMove(of: space) }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Shown instead of "Nothing here yet" when every game in the space is hidden.
private struct HiddenOnlyNote: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "eye.slash").font(.title2).frame(width: 36)
            Text("\(count) hidden games in this space").font(.headline)
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
    /// The user's pick, while the engine menus are on (Settings › Advanced); until then, and always with them off, the engine a
    /// new space gets without a choice (G-Player Wine, or Wine Staging while that is the only one installed, so nothing
    /// downloads unasked).
    @State private var picked: String?
    /// Showing the spaces already on this Mac (`ExistingSpacesView`) instead of the form.
    @State private var showingExisting = false

    private var engine: EngineInfo { model.engineForNewSpace(picking: picked) }

    /// What the menu shows: the offered engine that `engine` is (an earlier revision of G-Player Wine shows as G-Player Wine).
    private var selection: String {
        EngineCatalog.all.first { EngineCatalog.isRevision(engine.id, of: $0) }?.id ?? engine.id
    }

    var body: some View {
        if showingExisting {
            ExistingSpacesView(back: { showingExisting = false }, done: { dismiss() })
        } else {
            form
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Space").font(.headline)
            Text(Copy.space)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Main or Overcooked"))
                if model.choosesEngines {
                    // The short name and the note fit in the menu; the full name is in the text below.
                    Picker("Engine", selection: Binding(get: { selection }, set: { picked = $0 })) {
                        ForEach(EngineCatalog.all) { info in
                            Text(info.shortName + model.engineNote(info, listsInstalled: true)).tag(info.id)
                        }
                    }
                }
            }
            .formStyle(.grouped).scrollDisabled(true).frame(height: model.choosesEngines ? 120 : 64)
            if model.choosesEngines {
                Text("\(engine.displayName). \(engine.summary)").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Add Existing Space…") { showingExisting = true }
                    .help("Use a CrossOver or Whisky bottle or a Wine prefix that is already on this Mac")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    let info = engine
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

/// "Add Existing Space": the CrossOver and Whisky bottles and Wine prefixes already on this Mac, used in place with their
/// games. The same list as the first run's, for whoever skipped it or got a bottle later.
struct ExistingSpacesView: View {
    @Environment(AppModel.self) private var model
    let back: () -> Void
    let done: () -> Void
    /// nil while the Mac is searched.
    @State private var found: [FoundEnvironment]?
    @State private var chosen = Set<String>()

    /// - Parameter found: what to show instead of searching this Mac, for `SnapshotRenderer`.
    init(found: [FoundEnvironment]? = nil, back: @escaping () -> Void, done: @escaping () -> Void) {
        self.back = back; self.done = done
        _found = State(initialValue: found)
        _chosen = State(initialValue: Set((found ?? []).filter { $0.pathProblem == nil }.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Existing Space").font(.headline)
            Text("A space already on this Mac keeps its games and saves, and its files stay where they are.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content
            HStack {
                Button("Back", action: back)
                Spacer()
                Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    for f in found ?? [] where chosen.contains(f.id) { model.adopt(f) }
                    done()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(22).frame(width: 520)
        .task {
            guard found == nil else { return }
            let list = await model.findExistingEnvironments()
            found = list
            chosen = Set(list.filter { $0.pathProblem == nil }.map(\.id))
        }
    }

    @ViewBuilder private var content: some View {
        if let found {
            if found.isEmpty {
                Text("No CrossOver bottles, Whisky bottles or Wine prefixes were found in the usual places, or they are spaces already.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView { FoundEnvironmentList(found: found, chosen: $chosen) }.frame(maxHeight: 300)
            }
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking…").foregroundStyle(.secondary) }
        }
    }
}
