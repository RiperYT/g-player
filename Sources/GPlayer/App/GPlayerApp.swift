import AppKit
import GPlayerCore
import SwiftUI

@main
struct GPlayerApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("G-Player", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Game…") { model.addGameSource = nil; model.showAddGame = true }
                    .keyboardShortcut("n")
                    .disabled(!model.onboardingDone)
                Button("New Space…") { model.showNewSpace = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.onboardingDone)
            }
            CommandGroup(after: .sidebar) {
                Button("Refresh Library") { model.refreshStores() }.keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files dropped on the Dock icon or opened with "Open With › G-Player" start Add Game.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NotificationCenter.default.post(name: .gplayerOpenFile, object: url)
    }
}

extension Notification.Name {
    static let gplayerOpenFile = Notification.Name("GPlayerOpenFile")
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.onboardingDone && model.libraryRoot != nil {
                MainView()
            } else {
                OnboardingView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
