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
    var body: some View {
        Section {
            Text(info.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent("Version", value: info.basedOn ?? info.version)
            LabeledContent("Graphics", value: info.backends.map(\.displayName).joined(separator: ", "))
            if model.isInstalled(info) {
                LabeledContent("Status") { Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Button("Remove", role: .destructive) { model.removeEngine(info) }
            } else {
                let mb = info.downloadBytes(wineStagingInstalled: model.isInstalled(EngineCatalog.wineStaging)) / 1_000_000
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
