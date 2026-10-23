import GPlayerCore
import SwiftUI

struct GameInspector: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var title = ""
    @State private var arguments = ""
    @State private var coverTargeted = false
    /// Read from the .exe header once per game, off the main thread.
    @State private var details: PEDetails?

    var body: some View {
        let space = model.space(game.spaceID)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CoverView(game: game)
                    .frame(maxWidth: 220)
                    .frame(maxWidth: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: Theme.coverRadius)
                        .strokeBorder(Color.accentColor, lineWidth: coverTargeted ? 3 : 0).frame(maxWidth: 220))
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let u = urls.first, NSImage(contentsOf: u) != nil else { return false }
                        model.setCover(u, for: game); return true
                    } isTargeted: { coverTargeted = $0 }
                    .help("Drop an image here to use it as the cover")

                TextField("Title", text: $title)
                    .textFieldStyle(.plain).font(.title2.weight(.semibold))
                    .onSubmit { rename() }

                PlayStopButton(game: game)

                if model.isRunning(game), !model.isPreparing(game), let other = model.otherGraphics(for: game) {
                    PictureMissingButton(game: game, other: other)
                }

                facts(space)

                if let space, case .executable = game.source { executableSettings(space) }
                if let space {
                    if game.kind == .game {
                        HowItRunsSection(game: game, space: space)
                    } else {
                        if model.changesRefused(for: game) { RefusedChangesNote(space: space) }
                        graphicsSettings(space)
                    }
                }

                if model.canShareWhatWorked(game) { ShareWhatWorkedRow(game: game) }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Cover").sectionTitle()
                    HStack {
                        Button("Choose Image…") {
                            if let u = Panels.chooseFile(message: "Choose a cover image (2:3 works best).", start: nil,
                                                         types: ["png", "jpg", "jpeg", "heic", "webp"]) { model.setCover(u, for: game) }
                        }
                        if game.coverFile != nil { Button("Use Text Cover") { model.clearCover(for: game) } }
                    }
                }

                Divider()
                libraryActions
            }
            .padding(18)
        }
        .onAppear(perform: sync)
        .onChange(of: game.id) { sync() }
        .task(id: [game.id.uuidString, game.executablePath ?? ""]) {
            details = nil
            let exe = model.space(game.spaceID).flatMap { game.executableURL(in: $0) }
            let found = await Task.detached { exe.flatMap { PEInfo.details(ofExecutableAt: $0) } }.value
            guard !Task.isCancelled else { return }
            details = found
        }
    }

    @ViewBuilder private var libraryActions: some View {
        if game.isHidden {
            Button { model.setHidden(game, false) } label: { Label("Show in Library", systemImage: "eye") }
            Text("Puts it back in All Games, Recently Played, search and its space.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Button { model.setHidden(game, true) } label: { Label("Hide", systemImage: "eye.slash") }
            Text("Takes it out of All Games, Recently Played, search and its space. Find it under Hidden.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if game.canRemove {
            Button("Remove from Library…", role: .destructive) { model.gamePendingRemoval = game }
                .buttonStyle(.link).foregroundStyle(.red)
            Text("Removing keeps the game's files. Delete them from the space's files if you want the disk space back.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if case .legendary = game.source {
            Button("Uninstall…", role: .destructive) { model.gamePendingUninstall = game }
                .buttonStyle(.link).foregroundStyle(.red)
                .disabled(model.epic.isOccupied || model.isRunning(game))
            Text("Deletes the game's files from its space. Install it again from Epic Games in the sidebar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sync() {
        title = game.title
        arguments = game.arguments.joined(separator: " ")
    }

    private func rename() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != game.title else { return }
        var g = game; g.title = t; model.update(g)
    }

    @ViewBuilder private func facts(_ space: Space?) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            if let space {
                GridRow {
                    Text("Space").foregroundStyle(.secondary)
                    Button { model.selection = .space(space.id) } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(space.color).frame(width: 9, height: 9)
                            Text(space.name)
                        }
                    }.buttonStyle(.link)
                }
                GridRow {
                    Text("Runs on").foregroundStyle(.secondary)
                    Text(EngineCatalog.info(space.engineID)?.displayName ?? space.engineID)
                }
            }
            GridRow { Text("Source").foregroundStyle(.secondary); Text(game.source.label) }
            if let details {
                GridRow { Text("Program").foregroundStyle(.secondary); Text(details.label) }
            }
            if game.secondsPlayed > 0 {
                GridRow { Text("Played").foregroundStyle(.secondary); Text(game.secondsPlayed.playtime) }
            }
            if let d = game.lastPlayedAt {
                GridRow { Text("Last played").foregroundStyle(.secondary); Text(d.formatted(date: .abbreviated, time: .shortened)) }
            }
        }
        .font(.callout)
        if let note = details.flatMap(PEInfo.compatibilityNote) {
            Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func executableSettings(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Starts with").sectionTitle()
            if let exe = game.executableURL(in: space) {
                Text(space.windowsPath(for: exe)).font(Theme.path).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                PathRow(url: exe)
            }
            HStack {
                Button("Change…") {
                    let start = game.executableURL(in: space)?.deletingLastPathComponent() ?? space.driveC
                    if let u = Panels.chooseFile(message: "Choose the program that starts the game.", start: start,
                                                 types: ["exe", "bat", "msi"]) {
                        model.setExecutable(game, to: u)
                    }
                }
            }
            TextField("Arguments", text: $arguments, prompt: Text("Arguments, e.g. -windowed"))
                .textFieldStyle(.roundedBorder).font(Theme.path)
                .onSubmit {
                    var g = game
                    g.arguments = arguments.split(separator: " ").map(String.init)
                    model.update(g)
                }
        }
    }

    @ViewBuilder private func graphicsSettings(_ space: Space) -> some View {
        let info = model.engineInfo(for: space)
        VStack(alignment: .leading, spacing: 8) {
            Text("Graphics").sectionTitle()
            Picker("Graphics", selection: Binding(get: { info.backends.contains(game.graphics) ? game.graphics : .auto },
                                                  set: { model.setGraphics($0, for: game) })) {
                Text(GraphicsBackend.auto.displayName).tag(GraphicsBackend.auto)
                ForEach(info.backends) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            Text(info.graphicsHint(for: game.graphics, profile: game.launchOptions.profile))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Once a game has run well: a way to tell others what made it work. G-Player only opens the browser; the user submits it.
private struct ShareWhatWorkedRow: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.shareWhatWorked(game) } label: { Label("Share What Worked…", systemImage: "square.and.arrow.up") }
            Text("Opens a filled-in GitHub issue in your browser, so others can run this game the way you do. You see it first, and nothing is sent until you submit it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Play, or Stop while the game runs. While G-Player is making another try with other graphics, Stop prevents it. Once
/// the game has been started again and hasn't shown up, it can't be called back: the button says what it still can do,
/// which is to stop the tries.
private struct PlayStopButton: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        let retry = model.retryState(for: game)
        let running = model.isRunning(game)
        Button(action: act) { label(retry: retry, running: running) }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(model.isPreparing(game) && (retry == .none || retry == .stopping))
            .help(help(retry: retry, running: running))
            .keyboardShortcut(.return, modifiers: [])
    }

    private func act() {
        switch model.retryState(for: game) {
        case .starting: model.stopTryingOtherGraphics(game)
        case .trying: model.stop(game)
        case .stopping: break
        case .none: model.isRunning(game) ? model.stop(game) : model.play(game)
        }
    }

    @ViewBuilder private func label(retry: RetryState, running: Bool) -> some View {
        switch retry {
        case .stopping:
            busy("Stopping…")
        case .starting:
            Label("Stop Trying Other Graphics", systemImage: "stop.fill").frame(maxWidth: .infinity)
        case .trying:
            Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
        case .none:
            if model.isPreparing(game) {
                busy(model.isWaitingForInstalls(game) ? "Waiting for installs…" : "Starting…")
            } else {
                Label(running ? "Stop" : "Play", systemImage: running ? "stop.fill" : "play.fill").frame(maxWidth: .infinity)
            }
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .frame(maxWidth: .infinity)
    }

    private func help(retry: RetryState, running: Bool) -> String {
        switch retry {
        case .trying: "Stops trying other graphics. Nothing more is started."
        case .starting: "The game is already starting and opens in a moment. This only stops G-Player from trying other graphics for it."
        case .stopping, .none: running ? model.stopHelp(game) : ""
        }
    }
}

/// A game that runs but shows nothing can't be told from one that works. This closes it, after asking, and plays it again
/// with the next graphics Automatic has to offer.
private struct PictureMissingButton: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let other: GraphicsBackend

    var body: some View {
        Button { model.askOtherGraphics(game) } label: {
            Label("Picture Missing? Try Other Graphics", systemImage: "arrow.triangle.2.circlepath")
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.regular)
        .help("Closes the game and starts it again with \(other.displayName).")
    }
}
