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
                LabeledContent("Games", value: "\(model.games.filter { $0.kind == .game }.count)")
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
            ForEach(EngineCatalog.all) { info in
                Section(info.name) {
                    Text(info.summary).foregroundStyle(.secondary)
                    LabeledContent("Version", value: info.version)
                    LabeledContent("Graphics", value: info.backends.map(\.displayName).joined(separator: ", "))
                    if model.isInstalled(info) {
                        LabeledContent("Status") { Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        if info.kind == .wineStaging {
                            Button("Remove", role: .destructive) { model.removeEngine(info) }
                        }
                    } else if info.downloads.isEmpty {
                        Text("Install it in Terminal with Homebrew:").font(.callout)
                        HStack {
                            Text(EngineCatalog.gptkHomebrewCommand).font(Theme.path).textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(EngineCatalog.gptkHomebrewCommand, forType: .string)
                            }
                        }
                    } else {
                        let mb = info.downloads.reduce(0) { $0 + $1.approximateBytes } / 1_000_000
                        Button("Download (\(mb) MB)") { Task { _ = await model.ensureEngine(info) } }
                            .disabled(model.isEngineBusy)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
