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
        @Bindable var model = model
        Form {
            let staging = EngineCatalog.wineStaging
            Section(staging.name) {
                Text(staging.summary).foregroundStyle(.secondary)
                LabeledContent("Version", value: staging.version)
                LabeledContent("Graphics", value: staging.backends.map(\.displayName).joined(separator: ", "))
                if model.isInstalled(staging) {
                    LabeledContent("Status") { Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Button("Remove", role: .destructive) { model.removeEngine(staging) }
                } else {
                    let mb = staging.downloads.reduce(0) { $0 + $1.approximateBytes } / 1_000_000
                    Button("Download (\(mb) MB)") { Task { _ = await model.ensureEngine(staging) } }
                        .disabled(model.isEngineBusy)
                }
            }
            AppleToolkitSection()
        }
        .formStyle(.grouped)
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
            Text("Adds Apple's D3DMetal for DirectX 11 and 12 games. G-Player never includes or downloads Apple's files; it only uses a copy you installed. Apple's license allows the toolkit for developing, testing and evaluating games, so check that it fits how you use it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.useAppleToolkit {
                if model.isInstalled(info) {
                    LabeledContent("Status") { Label("Found on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                } else {
                    LabeledContent("Status") { Text("Not found").foregroundStyle(.secondary) }
                }
            }
            Link("About the Game Porting Toolkit", destination: EngineCatalog.gptkInfoURL)
        } header: {
            Text("Advanced")
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
