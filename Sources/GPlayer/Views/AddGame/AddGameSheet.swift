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
    /// How far copying or unpacking is (nil when that can't be told), and in words.
    @State private var workProgress: Double?
    @State private var workDetail = ""
    /// The work of the working step, and the installer in it: Cancel stops them.
    @State private var workTask: Task<Void, Never>?
    @State private var installer: InstallerRun?
    /// Cancel works only where stopping is possible (not while Windows is set up in a new space or an engine downloads).
    @State private var canStop = false
    @State private var stopping = false
    @State private var candidates: [ExecutableCandidate] = []
    @State private var chosen: URL?
    @State private var targetSpace: Space?
    @State private var dropTargeted = false

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
        // Stops the work. What an archive unpacked for its installer is removed by the work itself, once the installer has quit.
        .onDisappear { installer?.cancel(); workTask?.cancel() }
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
                if workProgress == nil { ProgressView().controlSize(.small) }
                Text(message).font(.body)
            }
            if let workProgress {
                ProgressView(value: workProgress)
                Text(workDetail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if !workDetail.isEmpty {
                Text(workDetail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let installer { InstallerNote(run: installer) }
        }
    }

    /// What the step says: where the installer is, or the work's own message.
    private var message: String {
        switch installer?.phase {
        case .queued: "Waiting for Windows components…"
        case .finishing: "Looking for what it installed…"
        default: workMessage
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
            Button(stopping ? "Stopping…" : "Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                .disabled(step == .working && (!canStop || stopping))
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
        guard let source else { return }
        let name = title.trimmingCharacters(in: .whitespaces)
        step = .working
        stopping = false
        workProgress = nil
        workDetail = ""
        workTask = Task { await work(source, name: name) }
    }

    /// Stops what the working step does (copying, unpacking, the installer), then closes. Anywhere else it just closes.
    private func cancel() {
        guard step == .working else { dismiss(); return }
        stopping = true
        installer?.cancel()
        workTask?.cancel()
    }

    private func work(_ source: ImportSource, name: String) async {
        // What an archive unpacked for its installer to run from: removed once the installer has quit, never while it runs.
        var unpacked: URL?
        defer { if let unpacked { try? FileManager.default.removeItem(at: unpacked) }; installer = nil; canStop = false }
        do {
            var space = model.space(spaceChoice)
            if space == nil {
                workMessage = "Creating the space “\(name)”…"
                space = await model.createSpace(name: name)
            }
            guard let space else { step = .details; return }                // the reason is shown
            if model.engine(for: space) == nil { workMessage = "Downloading \(EngineCatalog.info(space.engineID)?.name ?? "the engine")…" }
            guard let engine = await model.engineReady(for: space) else { step = .details; return }
            targetSpace = space
            canStop = true
            try Task.checkCancellation()
            if mode == .portable {
                let games = space.driveC.appendingPathComponent("Games", isDirectory: true)
                let plan = try await checkedPlan(source, move: move, destination: games, name: name)
                workMessage = source.url.hasDirectoryPath || Files.isDirectory(source.url) ? "Copying the game…" : "Unpacking the archive…"
                let folder = try await GameImporter.copyIntoSpace(source, space: space, title: name, move: move,
                                                                  totalBytes: plan.totalBytes, progress: showProgress)
                candidates = await Task.detached { ExecutableScanner.scan(folder, title: name) }.value
            } else {
                guard let paths = model.paths else { throw CancellationError() }
                workMessage = "Preparing the installer…"
                let folder = paths.downloads.appendingPathComponent("install-\(UUID().uuidString.prefix(8))")
                var plan = GameImporter.ImportPlan(totalBytes: 0, neededBytes: 0)
                if case .archive = source { plan = try await checkedPlan(source, move: false, destination: paths.downloads, name: name) }
                unpacked = folder
                let setup = try await GameImporter.installer(for: source, workFolder: folder, title: name,
                                                             totalBytes: plan.totalBytes, progress: showProgress)
                workProgress = nil; workDetail = ""
                workMessage = "Running \(setup.lastPathComponent)…"
                let run = InstallerRun()
                installer = run
                candidates = try await model.runInstaller(setup, in: space, engine: engine, title: name, run: run)
            }
            chosen = candidates.first?.url
            workProgress = nil; workDetail = ""
            step = .pick
        } catch is CancellationError {
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
            step = .details
        }
    }

    /// Looks at what the work will take and refuses it when the disk can't hold it, before anything is written.
    private func checkedPlan(_ source: ImportSource, move: Bool, destination: URL, name: String) async throws -> GameImporter.ImportPlan {
        workMessage = "Checking free space…"
        let plan = await GameImporter.plan(source, move: move, destination: destination)
        if let problem = GameImporter.spaceProblem(for: plan, destination: destination, title: name) { throw ShellError.failed(problem) }
        try Task.checkCancellation()
        return plan
    }

    /// Progress of copying or unpacking, from the work's own thread.
    private var showProgress: @Sendable (Int64, Int64) -> Void {
        { done, total in
            Task { @MainActor in
                workProgress = total > 0 ? min(1, Double(done) / Double(total)) : nil
                workDetail = total > 0 ? "\(done.formattedBytes) of \(total.formattedBytes)" : "\(done.formattedBytes) so far"
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

/// What the working step says while an installer waits for its turn and while it runs.
private struct InstallerNote: View {
    let run: InstallerRun

    var body: some View {
        switch run.phase {
        case .queued:
            Text("Windows components are installing in this space first. The installer starts when they are done.")
                .font(.callout).foregroundStyle(.secondary)
        case .running:
            Text("Finish the installer in its own window. You can uncheck “Launch game” at the end. G-Player continues when the installer closes.")
                .font(.callout).foregroundStyle(.secondary)
            Button("The Installer Is Done") { run.markDone() }
        case .finishing:
            EmptyView()
        }
    }
}
