import AppKit
import GPlayerCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            EngineSettings().tabItem { Label("Engines", systemImage: "cpu") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560, height: 380)
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
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            ForEach(EngineCatalog.all.filter { !$0.downloads.isEmpty }) { EngineSection(info: $0) }
            AppleToolkitSection()
        }
        .formStyle(.grouped)
    }
}

/// An engine G-Player downloads: what it is, and install or remove. The catalogue lists the recommended one first.
struct EngineSection: View {
    @Environment(AppModel.self) private var model
    let info: EngineInfo
    @State private var confirmRemove = false
    /// The names of the spaces that keep the engine busy, while the refusal is shown.
    @State private var busySpaces: [String] = []
    var body: some View {
        Section {
            Text(info.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                        Text("It's in use: programs are running or installing in \(list(busySpaces)). Quit them or wait, then try again.")
                    }
            } else {
                let mb = info.downloadBytes(wineStagingInstalled: model.isInstalled(EngineCatalog.wineStaging)) / 1_000_000
                Button("Download (\(mb) MB)") { Task { _ = await model.ensureEngine(info) } }
                    .disabled(model.isEngineBusy || model.libraryProblem != nil)
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

    /// What a space downloads to use the engine again: its archives, and Wine Staging's too when G-Player Wine is
    /// the one removed and Staging isn't there.
    private var redownloadMB: Int64 {
        let stagingStays = info.id != EngineCatalog.wineStaging.id && model.isInstalled(EngineCatalog.wineStaging)
        return info.downloadBytes(wineStagingInstalled: stagingStays) / 1_000_000
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

/// Apple's toolkit: opt-in, never shipped or downloaded by G-Player.
struct AppleToolkitSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        let info = EngineCatalog.gptk
        Section {
            Toggle("Use Apple's Game Porting Toolkit", isOn: $model.useAppleToolkit)
            Text("Adds Apple's D3DMetal for DirectX 11 and 12 games. G-Player never includes or downloads Apple's files. Turned on, it copies D3DMetal from the toolkit you installed or downloaded from Apple (checking that D3DMetal.framework and libd3dshared.dylib are signed by Apple) into your library and G-Player Wine; turned off, G-Player Wine goes back to Wine's own Direct3D. Apple's license allows the toolkit for developing, testing and evaluating games, so check that it fits how you use it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            Link("About the Game Porting Toolkit", destination: EngineCatalog.gptkInfoURL)
        } header: {
            Text("Advanced")
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
