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
        }
        .formStyle(.grouped)
    }
}

struct EngineSettings: View {
    /// A part of this tab to scroll to when it opens (`SettingsTab.Focus`); emptied once it has.
    @Binding var focus: String

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                ForEach(EngineCatalog.all.filter { !$0.downloads.isEmpty }) { EngineSection(info: $0) }
                AppleToolkitSection()
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

/// An engine G-Player downloads: what it is, and install or remove. The catalogue lists the recommended one first.
struct EngineSection: View {
    @Environment(AppModel.self) private var model
    let info: EngineInfo
    var body: some View {
        Section {
            Text(info.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent("Version", value: info.basedOn ?? info.version)
            LabeledContent("Graphics", value: info.backends.map(\.displayName).joined(separator: ", "))
            if model.isInstalled(info) {
                LabeledContent("Status") { Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Button("Remove", role: .destructive) { model.removeEngine(info) }
            } else {
                let mb = EngineCatalog.megabytes(info.downloadBytes(wineStagingInstalled: model.isInstalled(EngineCatalog.wineStaging)))
                Button("Download (\(mb) MB)") { Task { _ = await model.ensureEngine(info) } }
                    .disabled(model.isEngineBusy)
            }
        } header: {
            HStack(spacing: 8) {
                Text(info.name)
                Text(info.isRecommended ? "Recommended" : "Alternative").font(.caption2.weight(.semibold))
                    .foregroundStyle(info.isRecommended ? Color.accentColor : .secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((info.isRecommended ? Color.accentColor : .secondary).opacity(0.12), in: Capsule())
            }
        }
    }
}

/// Apple's toolkit: opt-in, never shipped or downloaded by G-Player. Says how to get and turn it on before it is on.
struct AppleToolkitSection: View {
    @Environment(AppModel.self) private var model
    /// What the Engines tab scrolls to (`SettingsTab.Focus.toolkit`).
    static let anchor = "toolkit"

    var body: some View {
        @Bindable var model = model
        let info = EngineCatalog.gptk
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
