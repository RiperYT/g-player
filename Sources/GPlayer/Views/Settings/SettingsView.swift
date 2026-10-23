import AppKit
import GPlayerCore
import SwiftUI

/// The tabs of Settings. Settings opens on the one it was left on, so a button elsewhere that points to a tab picks it
/// first (`show`), also when Settings is open already.
enum SettingsTab: String {
    case general, engines, advanced

    /// Where on the Engines tab to scroll to, for a button that points to one part of it.
    enum Focus: String { case none = "", toolkit }

    @MainActor func show(_ focus: Focus = .none) {
        UserDefaults.standard.set(rawValue, forKey: "settingsTab")
        UserDefaults.standard.set(focus.rawValue, forKey: "settingsFocus")
    }
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsTab.general
    @AppStorage("settingsFocus") private var focus = ""

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            EngineSettings(focus: $focus).tabItem { Label("Engines", systemImage: "cpu") }.tag(SettingsTab.engines)
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }.tag(SettingsTab.advanced)
        }
        .frame(width: 560, height: 460)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section("Library") {
                if let root = model.libraryRoot { LabeledContent("Location") { PathRow(url: root) } }
                if let root = model.libraryRoot, let problem = model.libraryRootProblem(root) { PathWarning(text: problem) }
                LabeledContent("Spaces", value: "\(model.spaces.count)")
                LabeledContent("Games", value: "\(model.visibleGames.filter { $0.kind == .game }.count)")
            }
            Section {
                Button("Show Welcome Again…") { model.resetOnboarding() }
            } footer: {
                Text("Walks through setup again. Your library stays as it is.").font(.caption).foregroundStyle(.secondary)
            }
            if model.updater.isEnabled { UpdateSettings() }
        }
        .formStyle(.grouped)
    }
}

/// Whether G-Player looks for a newer version by itself. Only in a build that updates itself (`AppUpdater`).
struct UpdateSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var updater = model.updater
        Section {
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
        } footer: {
            Text("G-Player asks GitHub whether a newer version is out. The request says which G-Player you have; nothing else is sent.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct EngineSettings: View {
    /// A part of this tab to scroll to when it opens (`SettingsTab.Focus`); emptied once it has.
    @Binding var focus: String

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                EngineSection(info: EngineCatalog.crossover)
                AppleToolkitSection()
                AdvancedEngineSection()
            }
            .formStyle(.grouped)
            .task(id: focus) {
                guard focus == SettingsTab.Focus.toolkit.rawValue else { return }
                try? await Task.sleep(for: .milliseconds(150))          // after the form has laid itself out
                proxy.scrollTo(AppleToolkitSection.anchor, anchor: .top)
                focus = ""
            }
        }
    }
}

/// G-Player Wine: what it is, and install or remove.
struct EngineSection: View {
    let info: EngineInfo
    var body: some View {
        Section {
            EngineRows(info: info)
        } header: {
            Text(info.name)
        }
    }
}

/// Wine Staging, hidden under Advanced: a newer Wine for the rare game that needs it. Not installed with G-Player Wine and
/// never removed by itself; spaces that run on it keep running.
struct AdvancedEngineSection: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Bool
    private let info = EngineCatalog.wineStaging

    /// - Parameter expanded: open at first, for `SnapshotRenderer`.
    init(expanded: Bool = false) { _expanded = State(initialValue: expanded) }

    var body: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(info.displayName) is a newer Wine than G-Player Wine's \(EngineCatalog.crossover.version), for the rare game that needs it. To run a space on it, turn on “Choose the Wine engine for each space” in the Advanced tab.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.isInstalled(info), !model.isInUse(info) {
                        Text("No space uses it now. Remove it to free about \(info.installedBytes.formattedBytes).")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    EngineRows(info: info, showsSummary: false)
                }
                .padding(.top, 6)
            }
        }
    }
}

/// An engine G-Player downloads: its version and graphics, and install or remove.
struct EngineRows: View {
    @Environment(AppModel.self) private var model
    let info: EngineInfo
    var showsSummary = true
    @State private var confirmRemove = false
    /// The names of the spaces that keep the engine busy, while the refusal is shown.
    @State private var busySpaces: [String] = []
    var body: some View {
        Group {
            if showsSummary { Text(info.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            LabeledContent("Version", value: info.basedOn ?? info.version)
            LabeledContent("Graphics", value: info.backends.map(\.displayName).joined(separator: ", "))
            if model.isInstalled(info) {
                LabeledContent("Status") { Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Button("Remove", role: .destructive) { startRemoval() }
                    .confirmationDialog("Remove \(info.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                        Button("Remove", role: .destructive) { remove() }
                    } message: {
                        Text("Spaces that use it download it again (about \(redownloadMB) MB) the next time they start.")
                    }
                    .alert("Can't remove \(info.name)", isPresented: Binding(get: { !busySpaces.isEmpty }, set: { if !$0 { busySpaces = [] } })) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("It's in use: programs are running, or something is being installed or set up, in \(list(busySpaces)). Quit them or wait, then try again.")
                    }
            } else if model.isUpdating(info) {
                EngineUpdateStatus(info: info)
            } else {
                if let line = model.updateFailureLine(for: info) { PathWarning(text: line) }
                let mb = EngineCatalog.megabytes(info.downloadBytes(wineStagingInstalled: model.isInstalled(EngineCatalog.wineStaging)))
                Button("Download (\(mb) MB)") { Task { _ = await model.ensureEngine(info) } }
                    .disabled(model.isEngineBusy || model.libraryProblem != nil)
            }
        }
    }

    /// What a space downloads to use the engine again: its archives, and Wine Staging's too when G-Player Wine is
    /// the one removed and Staging isn't there.
    private var redownloadMB: Int {
        let stagingStays = info.id != EngineCatalog.wineStaging.id && model.isInstalled(EngineCatalog.wineStaging)
        return EngineCatalog.megabytes(info.downloadBytes(wineStagingInstalled: stagingStays))
    }

    /// Looks first, so a refusal comes before the question.
    private func startRemoval() {
        Task {
            let busy = await model.busySpaces(using: info)
            if busy.isEmpty { confirmRemove = true } else { busySpaces = busy.map { "“\($0.name)”" } }
        }
    }

    private func remove() {
        Task {
            let busy = await model.removeEngine(info)             // asks again: things change while the question is open
            if !busy.isEmpty { busySpaces = busy.map { "“\($0.name)”" } }
        }
    }

    private func list(_ names: [String]) -> String {
        names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.first ?? ""
    }
}

/// An engine downloading in the background to replace an older revision of it: how far it is, and the sentence that says why.
private struct EngineUpdateStatus: View {
    @Environment(AppModel.self) private var model
    let info: EngineInfo

    var body: some View {
        let download = model.download(of: info)
        LabeledContent("Status") { Text(download?.message ?? "Starting").foregroundStyle(.secondary) }
        if let progress = download?.progress { ProgressView(value: progress) }
        Text(EngineMigration.updateNote(for: info)).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Apple's toolkit: opt-in, never shipped or downloaded by G-Player. Says how to get and turn it on before it is on.
struct AppleToolkitSection: View {
    @Environment(AppModel.self) private var model
    /// What the Engines tab scrolls to (`SettingsTab.Focus.toolkit`).
    static let anchor = "toolkit"

    var body: some View {
        @Bindable var model = model
        let info = EngineCatalog.gptk       // the toolkit as found on this Mac: no engine G-Player offers, only where D3DMetal comes from
        Section {
            Text("Optional. A few newer DirectX 12 games need Apple's D3DMetal. G-Player never includes or downloads Apple's files, so you get the toolkit yourself.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).id(Self.anchor)
            VStack(alignment: .leading, spacing: 8) {
                ToolkitStep(number: 1, text: "Get the Game Porting Toolkit from Apple. Open its disk image once and agree to Apple's license.")
                ToolkitStep(number: 2, text: "Turn on the switch below. G-Player copies D3DMetal from the toolkit into G-Player Wine.")
            }
            Link("Open Apple's Game Porting Toolkit page", destination: EngineCatalog.gptkInfoURL)
            Toggle("Use Apple's Game Porting Toolkit", isOn: $model.useAppleToolkit)
            Text("Turned off, G-Player Wine goes back to Wine's own Direct3D. Apple's license allows the toolkit for developing, testing and evaluating games, so check that it fits how you use it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.useAppleToolkit {
                LabeledContent("Toolkit") {
                    if model.isInstalled(info) { Label("Found on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { Text("Not installed").foregroundStyle(.secondary) }
                }
                LabeledContent("D3DMetal for G-Player Wine") {
                    if model.isImportingD3DMetal { ProgressView().controlSize(.small) }
                    else if let d = model.d3dMetal { Text("\(d.version), from \(d.source)") }
                    else { Text("Not copied yet").foregroundStyle(.secondary) }
                }
                HStack {
                    if let source = D3DMetalStore.toolkitSource {
                        Button("Copy from the Installed Toolkit") { Task { await model.importD3DMetal(from: source) } }
                    }
                    Button("Choose a Toolkit Download…") { chooseDownload() }
                }
                .disabled(model.isImportingD3DMetal)
                Text("Apple's download is a disk image: open it in Finder once and agree to Apple's license, then choose it or the opened disk here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.d3dMetal != nil {
                Button("Turn Off and Remove the Copied D3DMetal", role: .destructive) { Task { await model.removeD3DMetal() } }
            }
        } header: {
            Text("Apple's Game Porting Toolkit")
        }
    }

    private func chooseDownload() {
        let panel = NSOpenPanel()
        panel.message = "Choose Apple's Game Porting Toolkit disk image, or an opened toolkit disk."
        panel.allowedContentTypes = [.diskImage, .folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { Task { await model.importD3DMetal(from: url) } }
    }
}

/// One numbered step of the toolkit how-to.
private struct ToolkitStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 20, height: 20).background(.quaternary, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("Spaces") {
                Toggle("Choose the Wine engine for each space", isOn: $model.choosesEngines)
                Text("Adds an engine menu to a space's page and to New Space. G-Player Wine suits almost every game; Wine Staging, from Settings › Engines › Advanced, is for the rare one that needs a newer Wine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Troubleshooting") {
                Toggle("Detailed Wine logs", isOn: $model.verboseLogs)
                Text("Slower, but the logs say why a game fails. Each launch writes one log file.")
                    .font(.caption).foregroundStyle(.secondary)
                if let logs = model.paths?.logs {
                    Button("Open Logs Folder") { NSWorkspace.shared.open(logs) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
