import AppKit
import GPlayerCore
import SwiftUI

/// First launch: where the library lives, the engine, what's already on this Mac, and a first store.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    enum Step: Int, CaseIterable { case welcome, location, engine, found, apps }

    @State private var step: Step = .welcome
    @State private var root = LibraryPaths.defaultRoot
    @State private var rosetta: Bool?
    @State private var found: [FoundEnvironment] = []
    @State private var chosenFound = Set<String>()
    @State private var makeMain = true
    @State private var installSteam = false
    @State private var working = false
    /// The Rosetta install is running: its password window is up, and another must not open over it.
    @State private var installingRosetta = false
    /// The install, so Cancel can stop it (`Shell.installRosetta` also gives up after ten minutes).
    @State private var rosettaTask: Task<Void, Never>?

    /// What to draw instead of what the checks would find, so `SnapshotRenderer` can show every step without anyone
    /// clicking through them.
    struct Preview {
        var step: Step
        var root: URL? = nil
        var rosetta: Bool? = true
        /// The Rosetta install is under way (its password window is up).
        var installingRosetta = false
        var found: [FoundEnvironment] = []
    }
    private let preview: Preview?

    init(preview: Preview? = nil) {
        self.preview = preview
        guard let preview else { return }
        _step = State(initialValue: preview.step)
        _root = State(initialValue: preview.root ?? LibraryPaths.defaultRoot)
        _rosetta = State(initialValue: preview.rosetta)
        _installingRosetta = State(initialValue: preview.installingRosetta)
        _found = State(initialValue: preview.found)
        _chosenFound = State(initialValue: Set(preview.found.filter { $0.pathProblem == nil }.map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .frame(width: 520, alignment: .leading)
            Spacer(minLength: 20)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task { if preview == nil { rosetta = await Shell.isRosettaInstalled() } }
        .onAppear { if let existing = model.libraryRoot { root = existing } }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .location: locationStep
        case .engine: engineStep
        case .found: foundStep
        case .apps: appsStep
        }
    }

    @ViewBuilder private var welcomeStep: some View {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            title("Windows games on your Mac")
            Text("G-Player keeps your Windows games in one library and runs them with Wine, the open-source layer that lets Windows programs run on macOS.")
                .foregroundStyle(.secondary)
            facts([("square.grid.2x2", String(localized: "One library"), String(localized: "Steam, Epic and games you add yourself, side by side.")),
                   ("shippingbox", String(localized: "Spaces"), Copy.space),
                   ("square.and.arrow.down", String(localized: "Drop to add"), String(localized: "Drop a folder, an archive or an installer, and pick what starts the game."))])
    }

    @ViewBuilder private var locationStep: some View {
            title("Where should games live?")
            Text("Spaces, G-Player Wine and covers go in this folder. Games can take a lot of room, so pick a disk with space to spare.")
                .foregroundStyle(.secondary)
            HStack {
                PathRow(url: root)
                Spacer()
                Button("Change…") {
                    if let u = Panels.chooseFolder(message: "Choose a folder for the G-Player library.", start: root.deletingLastPathComponent()) {
                        root = u.lastPathComponent == "G-Player" ? u : u.appendingPathComponent("G-Player")
                    }
                }
                // G-Player Wine downloads into the folder chosen here; another folder would need it again.
                .disabled(model.isInstallingFirstRun)
            }
            if model.isInstallingFirstRun {
                Text("G-Player Wine is downloading into this folder. Change it once it is done.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let problem = model.libraryRootProblem(root) { PathWarning(text: problem) }
            if let free = freeSpace(at: root) {
                Text("\(free.formattedBytes) free on this disk").font(.callout).foregroundStyle(.secondary)
            }
            // Continue is what starts the downloads, so it says how much they take.
            if !model.isInstallingFirstRun, let note = FirstRunSetup.continueNote(installed: model.installedEngines) {
                Text(note).font(.callout)
            }
    }

    @ViewBuilder private var engineStep: some View {
            title("Get G-Player Wine")
            VStack(alignment: .leading, spacing: 8) {
                Text("G-Player runs your games on G-Player Wine, its own build of Wine for the Mac. It downloads once, and you don't need to choose anything.")
                if let sizes = FirstRunSetup.engineSizes(installed: model.installedEngines) { Text(sizes) }
            }
            .foregroundStyle(.secondary)
            rosettaRow
            ForEach(EngineCatalog.firstRunInstalls) { engineRow($0) }
            checkRow(ok: false, icon: "info.circle", title: "Apple's Game Porting Toolkit",
                     detail: String(localized: "Not needed to start. A few newer DirectX 12 games need it, and G-Player tells you when one does. You get it yourself from Apple; G-Player never downloads it."),
                     actionTitle: nil, action: {})
    }

    /// Rosetta runs Windows programs on Apple silicon. Installing it asks for the Mac's password, in one window at a time.
    private var rosettaRow: some View {
        let detail: String
        switch (rosetta, installingRosetta) {
        case (_, true): detail = String(localized: "Installing… Enter your Mac's password if it asks. Cancel stops waiting.")
        case (nil, _): detail = String(localized: "Checking…")
        case (true?, _): detail = String(localized: "Installed")
        case (false?, _): detail = String(localized: "Needed to run Windows programs. Install asks for your Mac's password.")
        }
        return checkRow(ok: rosetta == true, title: "Rosetta 2", detail: detail, working: installingRosetta,
                        actionTitle: installingRosetta ? String(localized: "Cancel") : rosetta == false ? String(localized: "Install") : nil,
                        action: installingRosetta ? cancelRosetta : installRosetta)
    }

    @ViewBuilder private var foundStep: some View {
            title(found.isEmpty ? "Nothing to bring over" : "Already on this Mac")
            Text(found.isEmpty
                 ? "No CrossOver bottles, Whisky bottles or Wine prefixes were found. You can add one later with New Space › Add Existing Space."
                 : "These Windows environments already exist. Add them as spaces to keep their games and saves. Their files stay where they are. You can add the rest later with New Space › Add Existing Space.")
                .foregroundStyle(.secondary)
            FoundEnvironmentList(found: found, chosen: $chosenFound)
    }

    @ViewBuilder private var appsStep: some View {
            title("Set up your library")
            Toggle(isOn: $makeMain) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create a space called Main").font(.body.weight(.medium))
                    Text("For games you add yourself. Most games share it. Takes about a minute.").font(.caption).foregroundStyle(.secondary)
                }
            }.toggleStyle(.checkbox)
            if !hasSteamAlready {
                Toggle(isOn: $installSteam) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Install Steam").font(.body.weight(.medium))
                        Text("In its own space. Steam downloads its client the first time, which takes a few minutes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.checkbox)
            }
            Text("More stores are in Get Apps, in the sidebar.").font(.callout).foregroundStyle(.secondary)
            if makeMain || (installSteam && !hasSteamAlready) || model.isInstallingFirstRun {
                Text("Setup carries on in the library, which shows its progress. You can add a game when it's done.")
                    .font(.callout).foregroundStyle(.secondary)
            }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule().fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: s == step ? 18 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.3), value: step)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            Spacer()
            if step != .welcome { Button("Back") { go(-1) }.disabled(working) }
            Button(step == .apps ? "Open Library" : "Continue") { next() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(working || (step == .engine && (rosetta == false || installingRosetta))
                          || (step == .location && model.libraryRootProblem(root) != nil))
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Pieces

    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 30, weight: .bold)).fixedSize(horizontal: false, vertical: true)
    }

    private func facts(_ rows: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(rows, id: \.1) { icon, head, text in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: icon).font(.title3).frame(width: 26).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(head).font(.body.weight(.semibold))
                        Text(text).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func checkRow(ok: Bool, icon: String? = nil, title: String, detail: String, progress: Activity? = nil,
                          working: Bool = false, actionTitle: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            // A neutral icon says "nothing for you to do here"; the dashed circle is a to-do.
            Image(systemName: icon ?? (ok ? "checkmark.circle.fill" : "circle.dashed"))
                .font(.title3).foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let progress { ProgressView(value: progress.progress ?? 0).controlSize(.small).padding(.top, 2) }
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            if let actionTitle { Button(actionTitle, action: action) }
        }
    }

    /// The engine the first run downloads: its own progress while it downloads, then Installed.
    private func engineRow(_ info: EngineInfo) -> some View {
        let installed = model.isInstalled(info)
        let download = model.download(of: info)
        return checkRow(ok: installed, title: info.displayName, detail: engineDetail(info, installed: installed, download: download),
                        progress: download,
                        actionTitle: installed || model.isEngineBusy || model.isInstallingFirstRun ? nil : String(localized: "Download"), action: downloadEngines)
    }

    private func engineDetail(_ info: EngineInfo, installed: Bool, download: Activity?) -> String {
        if installed { return String(localized: "Installed") }
        if let download { return download.message }
        if model.isInstallingFirstRun { return String(localized: "Starting…") }
        // The size is what the first run downloads: less when a Wine Staging that is installed already has the libraries.
        let mb = EngineCatalog.megabytes(info.downloadBytes(wineStagingInstalled: model.isInstalled(EngineCatalog.wineStaging)))
        return String(localized: "Runs Steam and DirectX 9–11 games. \(mb) MB.")
    }

    private var hasSteamAlready: Bool {
        found.contains { $0.presetID == "steam" && chosenFound.contains($0.id) } || model.isInstalled(AppPresets.steam)
    }

    private func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: Navigation

    private func go(_ delta: Int) {
        step = Step(rawValue: step.rawValue + delta) ?? step
    }

    private func next() {
        switch step {
        case .location:
            model.libraryRoot = root
            model.load()
            go(1)
            if !EngineCatalog.firstRunInstalls.allSatisfy({ model.isInstalled($0) }) { downloadEngines() }
        case .engine:
            let known = model.spaces.map(\.url) + [root]
            found = EnvironmentFinder.find(excluding: known, gptkInstalled: model.engineManager?.isInstalled(EngineCatalog.gptk) ?? false,
                                           installed: model.installedEngines)
            chosenFound = Set(found.filter { $0.pathProblem == nil }.map(\.id))
            go(1)
        case .found:
            for f in found where chosenFound.contains(f.id) { model.adopt(f) }
            found.removeAll { chosenFound.contains($0.id) }
            makeMain = !model.spaces.contains { $0.origin == .managed && $0.presetID == nil }
            installSteam = !model.isInstalled(AppPresets.steam) && model.presetSpace(AppPresets.steam) == nil
            go(1)
        case .apps:
            let wantMain = makeMain && !model.spaces.contains { $0.name == "Main" }
            let wantSteam = installSteam && !hasSteamAlready
            model.engineNoteSeen = true                           // the note about G-Player Wine is for those who updated
            model.finishOnboarding(root: root)
            // Made once an engine is there, also after a quit before the downloads ended.
            model.createFirstRunSpaces(main: wantMain, steam: wantSteam)
        default:
            go(1)
        }
    }

    private func downloadEngines() {
        model.installFirstRunEngines()
    }

    private func installRosetta() {
        guard !installingRosetta else { return }
        installingRosetta = true
        rosettaTask = Task {
            // Stops waiting after ten minutes, or at Cancel, which closes the password window: Continue never stays dimmed.
            do { try await Shell.installRosetta() }
            catch is CancellationError {}
            catch { model.errorMessage = error.localizedDescription }
            rosetta = await Shell.isRosettaInstalled()
            installingRosetta = false
            rosettaTask = nil
        }
    }

    private func cancelRosetta() { rosettaTask?.cancel() }
}
