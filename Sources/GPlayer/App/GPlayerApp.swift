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
        Window(Text(verbatim: "G-Player"), id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                if model.updater.isEnabled {
                    Button("Check for Updates…") { model.updater.check() }
                        .disabled(!model.updater.canCheck)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Game…") { model.openAddGame() }
                    .keyboardShortcut("n")
                    .disabled(model.addGameBlock != nil)
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
    /// Opens the main window again; the window's own view sets it (`RootView`), since only a view can ask SwiftUI for a window.
    static var reopenMainWindow: (@MainActor () -> Void)?
    /// The Mac is powering off (shut down, restart, log out): set by the system's notice, before it asks the app to quit.
    private var systemIsGoingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemIsGoingDown = true }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A Legendary download left running would go on with no window to show it; it goes on from where it stopped next time.
    func applicationWillTerminate(_ notification: Notification) { Legendary.stopRunning() }

    /// Why the quit that is being handled was asked for: the reason in its Apple event, when the system sent it.
    private static var quitReason: UInt32? {
        NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
    }

    /// Quitting while engines download, a space is made, components or a store app install: ask first. Pressing Quit
    /// leaves what came on disk, so most of it goes on from there. Never when the system asks (shut down, restart, log out):
    /// a question that can stop it would keep the Mac from going down. Nor when Sparkle quits G-Player to install an update the
    /// user chose: it relaunches G-Player once this has quit (`SetupQuit.mayAsk`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let updating = Self.model?.updater.isInstalling ?? false
        guard SetupQuit.mayAsk(systemIsGoingDown: systemIsGoingDown, reason: Self.quitReason, updateIsInstalling: updating),
              let question = Self.model?.quitQuestion else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.title
        alert.informativeText = question.detail
        alert.addButton(withTitle: String(localized: "Keep Setting Up"))
        alert.addButton(withTitle: String(localized: "Quit"))
        if alert.runModal() == .alertSecondButtonReturn { return .terminateNow }
        // Closing the last window asked to quit; staying means the window comes back, not an app with none.
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            DispatchQueue.main.async { Self.reopenMainWindow?(); NSApp.activate() }
        }
        return .terminateCancel
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Group {
            if model.onboardingDone && model.libraryRoot != nil {
                MainView()
            } else {
                OnboardingView()
            }
        }
        .onAppear {
            AppDelegate.reopenMainWindow = { openWindow(id: "main") }
            // Sparkle only once the main window is up: its first question shown before it was the only window, and closing
            // that window quit G-Player (it quits when its last window closes). Does nothing in a build without the update key.
            model.updater.start()
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
