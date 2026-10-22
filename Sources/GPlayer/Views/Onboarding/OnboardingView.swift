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

    /// What to draw instead of what the checks would find, so `SnapshotRenderer` can show every step without anyone
    /// clicking through them.
    struct Preview {
        var step: Step
        var root: URL? = nil
        var rosetta: Bool? = true
        var found: [FoundEnvironment] = []
    }
    private let preview: Preview?

    init(preview: Preview? = nil) {
        self.preview = preview
        guard let preview else { return }
        _step = State(initialValue: preview.step)
        _root = State(initialValue: preview.root ?? LibraryPaths.defaultRoot)
        _rosetta = State(initialValue: preview.rosetta)
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
            facts([("square.grid.2x2", "One library", "Steam, Epic and games you add yourself, side by side."),
                   ("shippingbox", "Spaces", "Each space is a separate Windows with its own C: drive."),
                   ("square.and.arrow.down", "Drop to add", "Drop a folder, an archive or an installer, and pick what starts the game.")])
    }

    @ViewBuilder private var locationStep: some View {
            title("Where should games live?")
            Text("Spaces, engines and covers go in this folder. Games can take a lot of room, so pick a disk with space to spare.")
                .foregroundStyle(.secondary)
            HStack {
                PathRow(url: root)
                Spacer()
                Button("Change…") {
                    if let u = Panels.chooseFolder(message: "Choose a folder for the G-Player library.", start: root.deletingLastPathComponent()) {
                        root = u.lastPathComponent == "G-Player" ? u : u.appendingPathComponent("G-Player")
                    }
                }
                // The engines download into the folder chosen here; another folder would need them again.
                .disabled(model.isInstallingFirstRun)
            }
            if model.isInstallingFirstRun {
                Text("The engines are downloading into this folder. Change it once they are done.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let problem = model.libraryRootProblem(root) { PathWarning(text: problem) }
            if let free = freeSpace(at: root) {
                Text("\(free.formattedBytes) free on this disk").font(.callout).foregroundStyle(.secondary)
            }
    }

    @ViewBuilder private var engineStep: some View {
            title("Get the engines")
            Text(engineIntro).foregroundStyle(.secondary)
            checkRow(ok: rosetta == true, title: "Rosetta 2",
                     detail: rosetta == nil ? "Checking…" : rosetta! ? "Installed" : "Needed to run Wine",
                     actionTitle: rosetta == false ? "Install" : nil, action: installRosetta)
            ForEach(EngineCatalog.all.filter { !$0.downloads.isEmpty }) { engineRow($0) }
            checkRow(ok: false, title: "Apple's Game Porting Toolkit (optional)",
                     detail: "For DirectX 12 games, if you install it yourself. Turn it on later in Settings › Engines.",
                     actionTitle: nil, action: {})
    }

    @ViewBuilder private var foundStep: some View {
            title(found.isEmpty ? "Nothing to bring over" : "Already on this Mac")
            Text(found.isEmpty
                 ? "No CrossOver bottles or Wine prefixes were found. You can add them later from the library."
                 : "These Windows environments already exist. Add them as spaces to keep their games and saves. Their files stay where they are.")
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(found) { f in
                    Toggle(isOn: Binding(get: { chosenFound.contains(f.id) },
                                         set: { if $0 { chosenFound.insert(f.id) } else { chosenFound.remove(f.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(f.name).font(.body.weight(.medium))
                                Text(f.originNote).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(describe(f)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(f.pathProblem != nil)
                    if let problem = f.pathProblem { PathWarning(text: problem, font: .caption).padding(.bottom, 8) }
                    if f.id != found.last?.id { Divider() }
                }
            }
    }

    @ViewBuilder private var appsStep: some View {
            title("Set up your library")
            Toggle(isOn: $makeMain) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create a space called Main").font(.body.weight(.medium))
                    Text("For games you add yourself. Takes about a minute.").font(.caption).foregroundStyle(.secondary)
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
                .disabled(working || (step == .engine && rosetta == false)
                          || (step == .location && model.libraryRootProblem(root) != nil))
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Pieces

    private func title(_ text: String) -> some View {
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

    private func checkRow(ok: Bool, title: String, detail: String, progress: Activity? = nil, actionTitle: String?,
                          action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3).foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let progress { ProgressView(value: progress.progress ?? 0).controlSize(.small).padding(.top, 2) }
            }
            Spacer()
            if let actionTitle { Button(actionTitle, action: action) }
        }
    }

    /// An engine G-Player downloads: its own progress while it downloads, then Installed.
    private func engineRow(_ info: EngineInfo) -> some View {
        let installed = model.isInstalled(info)
        let download = model.download(of: info)
        return checkRow(ok: installed, title: info.displayName, detail: engineDetail(info, installed: installed, download: download),
                        progress: download,
                        actionTitle: installed || model.isEngineBusy || model.isInstallingFirstRun ? nil : "Download", action: downloadEngines)
    }

    private func engineDetail(_ info: EngineInfo, installed: Bool, download: Activity?) -> String {
        if installed { return "Installed" }
        if let download { return download.message }
        if model.isInstallingFirstRun {
            return info.isRecommended && !model.isInstalled(EngineCatalog.wineStaging) ? "Downloads after Wine Staging, reusing its libraries" : "Starting…"
        }
        return info.isRecommended ? "Recommended. Runs Steam and DirectX 9–11 games, and DirectX 12 with Apple's D3DMetal if you add it"
                                  : "Alternative. Runs Steam and most DirectX 9–11 games"
    }

    /// What the engine step says before the rows: what G-Player uses and how much is left to download.
    private var engineIntro: String {
        let intro = "Wine for macOS runs Windows programs through Rosetta 2. G-Player uses G-Player Wine and keeps Wine Staging as an alternative."
        let mb = EngineCatalog.firstRunBytes(installed: model.installedEngines) / 1_000_000
        return mb == 0 ? intro : intro + " That takes about \(mb) MB to download. G-Player checks every file before using it."
    }

    private var hasSteamAlready: Bool {
        found.contains { $0.presetID == "steam" && chosenFound.contains($0.id) } || model.isInstalled(AppPresets.steam)
    }

    private func describe(_ f: FoundEnvironment) -> String {
        var parts: [String] = []
        if f.presetID == "steam" { parts.append("Steam") }
        parts += f.games.map(\.title)
        let engine = EngineCatalog.info(f.suggestedEngineID)?.name ?? f.suggestedEngineID
        return (parts.isEmpty ? "" : parts.joined(separator: ", ") + " · ") + "runs on \(engine)"
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
            found = EnvironmentFinder.find(excluding: known, gptkInstalled: model.engineManager?.isInstalled(EngineCatalog.gptk) ?? false)
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
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        Task {
            _ = try? await Shell.run(Shell.tool("osascript"), ["-e", script])
            rosetta = await Shell.isRosettaInstalled()
        }
    }
}
