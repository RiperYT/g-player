import AppKit
import GPlayerCore
import SwiftUI

/// The entry point. A start with `--render-onboarding <folder>` draws the UI into PNGs and exits (`SnapshotRenderer`).
@main @MainActor
enum Launcher {
    static func main() {
        if let folder = LaunchArguments.snapshotFolder(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment) {
            SnapshotRenderer.run(into: folder)
        }
        handOverToRunningCopy()
        GPlayerApp.main()
    }

    /// Two copies would read and write one library.json and one Wine server. Info.plist keeps Launch Services from opening a
    /// second one; this covers a copy started directly. It quits before the model exists, so it changes nothing.
    private static func handOverToRunningCopy() {
        guard let id = Bundle.main.bundleIdentifier else { return }              // `swift run` has no bundle
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        guard let running = others.first else { return }
        if let url = running.bundleURL {
            let done = DispatchSemaphore(value: 0)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done.signal() }
            _ = done.wait(timeout: .now() + 3)
        } else {
            running.activate(options: [.activateAllWindows])
        }
        exit(0)
    }
}

struct GPlayerApp: App {
    @State private var model: AppModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppDelegate.model = model                                    // for the question on quitting
    }

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
                    .disabled(!model.onboardingDone || model.libraryProblem != nil)
                Button("New Space…") { model.showNewSpace = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.onboardingDone || model.libraryProblem != nil)
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's model, set when the app is made; the delegate asks it whether quitting would cut setup short.
    static var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting while engines download, a space is made, components or a store app install: ask first. Pressing Quit
    /// leaves what came on disk, so most of it goes on from there.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let question = Self.model?.quitQuestion else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.title
        alert.informativeText = question.detail
        alert.addButton(withTitle: "Keep Setting Up")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

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
        // Over the window, not instead of it, so onboarding keeps its place while the library question is open.
        .disabled(model.libraryProblem != nil)
        .overlay {
            if let problem = model.libraryProblem { LibraryProblemView(problem: problem).background(.background) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
