import GPlayerCore
import SwiftUI

struct GameInspector: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var title = ""
    @State private var arguments = ""
    @State private var coverTargeted = false

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

                Button { model.isRunning(game) ? model.stop(game) : model.play(game) } label: {
                    Label(model.isRunning(game) ? "Stop" : "Play",
                          systemImage: model.isRunning(game) ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])

                facts(space)

                if let space, case .executable = game.source { executableSettings(space) }
                if let space { graphicsSettings(space) }

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
                Button("Remove from Library", role: .destructive) { model.remove(game) }
                    .buttonStyle(.link).foregroundStyle(.red)
                Text("Removing keeps the game's files. Delete them from the space's files if you want the disk space back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .onAppear(perform: sync)
        .onChange(of: game.id) { sync() }
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
                    Text("Engine").foregroundStyle(.secondary)
                    Text(EngineCatalog.info(space.engineID).map { "\($0.name) \($0.version)" } ?? space.engineID)
                }
            }
            GridRow { Text("Source").foregroundStyle(.secondary); Text(game.source.label) }
            if game.secondsPlayed > 0 {
                GridRow { Text("Played").foregroundStyle(.secondary); Text(game.secondsPlayed.playtime) }
            }
            if let d = game.lastPlayedAt {
                GridRow { Text("Last played").foregroundStyle(.secondary); Text(d.formatted(date: .abbreviated, time: .shortened)) }
            }
        }
        .font(.callout)
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
                        var g = game; g.executablePath = Game.storedPath(for: u, in: space); model.update(g)
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
        let info = EngineCatalog.info(space.engineID) ?? EngineCatalog.wineStaging
        VStack(alignment: .leading, spacing: 8) {
            Text("Graphics").sectionTitle()
            Picker("Graphics", selection: Binding(get: { game.graphics }, set: { v in var g = game; g.graphics = v; model.update(g) })) {
                Text("Automatic (\(info.defaultBackend.displayName))").tag(GraphicsBackend.auto)
                ForEach(info.backends) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            Text(info.resolve(game.graphics).summary).font(.caption).foregroundStyle(.secondary)
        }
    }
}
