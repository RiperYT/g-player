import GPlayerCore
import SwiftUI

struct AddGameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initialSource: ImportSource?

    enum Step: Equatable { case choose, details, working, pick }

    @State private var step: Step = .choose
    @State private var source: ImportSource?
    @State private var title = ""
    @State private var mode: ImportMode = .portable
    @State private var spaceChoice: UUID?          // nil = new space named after the game
    @State private var move = false
    @State private var workMessage = ""
    @State private var waitingForInstaller = false
    @State private var installerDone = false
    @State private var candidates: [ExecutableCandidate] = []
    @State private var chosen: URL?
    @State private var targetSpace: Space?
    @State private var dropTargeted = false
    @State private var workFolder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .choose: chooseStep
                case .details: detailsStep
                case .working: workingStep
                case .pick: pickStep
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .onAppear {
            spaceChoice = model.spaces.first(where: { $0.presetID == nil && $0.origin == .managed })?.id
            if let initialSource { pick(initialSource) }
        }
        .onDisappear { if let workFolder { try? FileManager.default.removeItem(at: workFolder) } }
    }

    // MARK: Steps

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add a Game").font(.headline)
                Text(stepCaption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var stepCaption: String {
        switch step {
        case .choose: "A folder, an archive or an installer"
        case .details: source.map { $0.url.lastPathComponent } ?? ""
        case .working: mode == .installer ? "Installing" : "Copying"
        case .pick: "Which program starts the game?"
        }
    }

    private var chooseStep: some View {
        DropZone(title: "Drop a game here",
                 message: "A game folder, a zip, rar or 7z archive, or a setup .exe or .msi.",
                 targeted: dropTargeted,
                 actions: AnyView(Button("Choose…") { if let u = Panels.chooseGameSource() { open(u) } }
                    .buttonStyle(.borderedProminent)))
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first else { return false }
                open(u); return true
            } isTargeted: { dropTargeted = $0 }
    }

    private var detailsStep: some View {
        Form {
            TextField("Title", text: $title)
            Picker("Add it by", selection: $mode) {
                Text("Copying the game").tag(ImportMode.portable)
                Text("Running its installer").tag(ImportMode.installer)
            }
            .pickerStyle(.radioGroup)
            Text(mode == .portable
                 ? "The game is copied into the space's C: drive, under Games. Nothing is installed."
                 : "The installer opens inside the space. Install as you would on Windows, then G-Player finds what it installed.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Space", selection: $spaceChoice) {
                ForEach(model.spaces) { s in Text(s.name).tag(Optional(s.id)) }
                Divider()
                Text("New space “\(title.isEmpty ? "Game" : title)”").tag(UUID?.none)
            }
            if case .folder = source, mode == .portable {
                Toggle("Move the folder instead of copying it", isOn: $move)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var workingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(workMessage).font(.body)
            }
            if waitingForInstaller {
                Text("Finish the installer in its own window. You can uncheck “Launch game” at the end. G-Player continues when the installer closes.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("The Installer Is Done") { installerDone = true }
            }
        }
    }

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if candidates.isEmpty {
                Text("No new programs were found. Choose the game's .exe yourself.")
                    .foregroundStyle(.secondary)
            } else {
                List(candidates.prefix(30), selection: $chosen) { c in
                    HStack(spacing: 10) {
                        Image(systemName: chosen == c.url ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(chosen == c.url ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(c.name).font(.body.weight(.medium))
                                if let hint = c.hint, c == candidates.first {
                                    Text(hint).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                }
                            }
                            Text(relative(c.url)).font(Theme.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(c.size.formattedBytes).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(c.url)
                    .padding(.vertical, 2)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }
            Button("Choose Another File…") {
                let start = chosen?.deletingLastPathComponent() ?? targetSpace?.driveC
                if let u = Panels.chooseFile(message: "Choose the program that starts the game.", start: start, types: ["exe", "bat"]) {
                    chosen = u
                    if !candidates.contains(where: { $0.url == u }) {
                        candidates.insert(ExecutableCandidate(url: u, size: Files.size(of: u), score: 0, hint: nil), at: 0)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                .disabled(step == .working && !waitingForInstaller)
            Spacer()
            switch step {
            case .choose: EmptyView()
            case .details:
                Button(mode == .installer ? "Run Installer" : "Add Game") { start() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            case .working: EmptyView()
            case .pick:
                Button("Add to Library") { finish() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(chosen == nil)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    // MARK: Actions

    private func open(_ url: URL) {
        guard let s = ImportSource(url) else {
            model.errorMessage = "\(url.lastPathComponent) isn't a folder, an archive or a Windows program."
            return
        }
        pick(s)
    }

    private func pick(_ s: ImportSource) {
        source = s
        title = s.suggestedTitle
        step = .details
        Task {
            let (guessed, _) = await GameImporter.guess(s)
            mode = guessed
        }
    }

    private func start() {
        guard let source, let paths = model.paths else { return }
        let name = title.trimmingCharacters(in: .whitespaces)
        step = .working
        Task {
            var space = model.space(spaceChoice)
            if space == nil {
                workMessage = "Creating the space “\(name)”…"
                space = await model.createSpace(name: name)
            }
            guard let space, let engine = model.engine(for: space) else { step = .details; return }
            targetSpace = space
            do {
                if mode == .portable {
                    workMessage = source.url.hasDirectoryPath || Files.isDirectory(source.url) ? "Copying the game…" : "Unpacking the archive…"
                    let folder = try await GameImporter.copyIntoSpace(source, space: space, title: name, move: move)
                    candidates = ExecutableScanner.scan(folder, title: name)
                } else {
                    workMessage = "Preparing the installer…"
                    let work = paths.downloads.appendingPathComponent("install-\(UUID().uuidString.prefix(8))")
                    workFolder = work
                    let installer = try await GameImporter.installer(for: source, workFolder: work, title: name)
                    let before = ProgramSnapshot.take(of: space)
                    workMessage = "Running \(installer.lastPathComponent)…"
                    waitingForInstaller = true
                    installerDone = false
                    _ = try WineLauncher.start(engine: engine, space: space, arguments: WineLauncher.arguments(toOpen: installer),
                                               workingDirectory: installer.deletingLastPathComponent(), backend: .auto,
                                               logsFolder: paths.logs, logName: "Install \(name)") { _ in
                        Task { await WineLauncher.waitForAll(engine: engine, space: space)
                               await MainActor.run { installerDone = true } }
                    }
                    while !installerDone { try await Task.sleep(for: .milliseconds(400)) }
                    waitingForInstaller = false
                    workMessage = "Looking for what it installed…"
                    candidates = ProgramSnapshot.newPrograms(in: space, since: before)
                }
                chosen = candidates.first?.url
                step = .pick
            } catch {
                waitingForInstaller = false
                model.errorMessage = error.localizedDescription
                step = .details
            }
        }
    }

    private func finish() {
        guard let exe = chosen, let space = targetSpace else { return }
        let game = Game(title: title.trimmingCharacters(in: .whitespaces), spaceID: space.id,
                        executablePath: Game.storedPath(for: exe, in: space),
                        arguments: ExecutableCandidate.chromiumArguments(for: exe))
        model.addGame(game)
        model.selection = .allGames
        dismiss()
    }

    private func relative(_ url: URL) -> String {
        guard let space = targetSpace else { return url.path }
        return space.windowsPath(for: url)
    }
}
