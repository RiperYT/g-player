import AppKit
import GPlayerCore
import SwiftUI

/// Debug aid: `GPlayer --render-onboarding <folder>` (or `GPLAYER_RENDER_ONBOARDING=<folder>`) draws every first-run
/// screen and the main empty states into PNGs, light and dark, and exits. See "Reviewing the UI" in docs/ARCHITECTURE.md.
///
/// Nothing real is touched: a throwaway library folder and settings kept in memory stand in for the user's, no engine
/// is downloaded, no Wine runs, and no window is shown. The views are drawn by AppKit in a window that is never on
/// screen, because SwiftUI's `ImageRenderer` draws checkboxes, forms, lists and progress bars as placeholders.
@MainActor
enum SnapshotRenderer {
    /// Draws every screen into `folder`, prints the files, and ends the process.
    static func run(into folder: URL) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)                    // no Dock icon, no menu, nothing in front of other apps
        // A run that goes wrong ends by itself.
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            FileHandle.standardError.write(Data("GPlayer: rendering took too long, stopped.\n".utf8))
            exit(2)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var files: [String] = []
            for shot in shots {
                let sandbox = Sandbox()
                defer { sandbox.dispose() }
                for (mode, data) in capture(shot.view(sandbox), size: shot.size) {
                    let file = folder.appendingPathComponent("\(shot.name)-\(mode).png")
                    try data.write(to: file, options: .atomic)
                    files.append(file.path)
                }
            }
            files.forEach { print($0) }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("GPlayer: couldn't write the snapshots: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: The screens

    private struct Shot {
        let name: String
        /// nil: as big as the view wants to be (sheets).
        var size: CGSize?
        let view: (Sandbox) -> AnyView
    }

    private static let windowSize = CGSize(width: 900, height: 600)
    private static let mainSize = CGSize(width: 1100, height: 700)
    private static let settingsSize = CGSize(width: 560, height: 820)

    private static var shots: [Shot] {
        func onboarding(_ name: String, _ preview: @escaping (Sandbox) -> OnboardingView.Preview) -> Shot {
            Shot(name: name, size: windowSize) { box in AnyView(OnboardingView(preview: preview(box)).environment(box.model)) }
        }
        return [
            onboarding("onboarding-1-welcome") { _ in .init(step: .welcome) },
            onboarding("onboarding-2-location") { _ in .init(step: .location) },
            onboarding("onboarding-2-location-too-long") { box in .init(step: .location, root: box.tooLongFolder) },
            onboarding("onboarding-3-engines") { _ in .init(step: .engine) },
            Shot(name: "onboarding-3-engines-downloading", size: windowSize) { box in
                box.downloadingEngines()
                return AnyView(OnboardingView(preview: .init(step: .engine)).environment(box.model))
            },
            onboarding("onboarding-4-found-nothing") { _ in .init(step: .found) },
            onboarding("onboarding-4-found-some") { box in .init(step: .found, found: box.foundEnvironments()) },
            onboarding("onboarding-5-library") { _ in .init(step: .apps) },
            Shot(name: "main-library-empty", size: mainSize) { box in
                box.finishedOnboarding()
                return AnyView(MainWindow(detail: LibraryView(filter: .all)).environment(box.model))
            },
            Shot(name: "main-space-new", size: mainSize) { box in
                let space = box.newSpace()
                return AnyView(MainWindow(detail: SpaceView(space: space)).environment(box.model))
            },
            Shot(name: "sheet-new-space") { box in AnyView(NewSpaceSheet().environment(box.model)) },
            Shot(name: "sheet-add-game") { box in AnyView(AddGameSheet(initialSource: nil).environment(box.model)) },
            Shot(name: "settings-engines", size: settingsSize) { box in AnyView(EngineSettings().environment(box.model)) },
            Shot(name: "settings-general-long-path", size: CGSize(width: 560, height: 300)) { box in
                box.model.libraryRoot = box.tooLongFolder
                return AnyView(GeneralSettings().environment(box.model))
            },
        ]
    }

    /// The main window without its chrome: the sidebar next to a page. (A window's glass sidebar can't be drawn off screen.)
    private struct MainWindow<Detail: View>: View {
        let detail: Detail
        var body: some View {
            HStack(spacing: 0) {
                Sidebar().frame(width: 220).background(.background.secondary)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Drawing

    /// A window that is never shown, and draws its controls as in one that is in front.
    private final class OffscreenWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { true }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// The view as PNG data in light and dark mode, at 2x.
    private static func capture(_ view: AnyView, size: CGSize?) -> [(mode: String, data: Data)] {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key))
        let size = size ?? host.fittingSize
        let window = OffscreenWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                                     backing: .buffered, defer: false)
        window.contentView = host
        window.alphaValue = 0
        window.setFrameOrigin(CGPoint(x: -30_000, y: -30_000))      // ordered in, so tasks run, but far from any screen
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var shots: [(mode: String, data: Data)] = []
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            settle(host, seconds: shots.isEmpty ? 0.35 : 0.15)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) { shots.append((mode, data)) }
        }
        return shots
    }

    /// Lets SwiftUI run its tasks and lay the view out.
    private static func settle(_ host: NSView, seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        host.layoutSubtreeIfNeeded()
    }

    // MARK: A throwaway library

    /// Settings that live in memory only, for the keys `AppModel` uses. A suite of its own would still leave a preferences
    /// file behind.
    private final class MemoryDefaults: UserDefaults {
        private var values: [String: Any] = [:]
        init() { super.init(suiteName: nil)! }
        override func object(forKey key: String) -> Any? { values[key] }
        override func string(forKey key: String) -> String? { values[key] as? String }
        override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
        override func set(_ value: Any?, forKey key: String) { values[key] = value }
        override func set(_ value: Bool, forKey key: String) { values[key] = value }
        override func removeObject(forKey key: String) { values[key] = nil }
    }

    /// A library folder and settings that exist for one screen only, and a model on them.
    @MainActor
    private final class Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gplayer-snapshot-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let model = AppModel(defaults: MemoryDefaults(), watching: false)

        func dispose() { try? FileManager.default.removeItem(at: root) }

        /// A library folder with a path over the limit, which is never created.
        var tooLongFolder: URL {
            root.appendingPathComponent(String(repeating: "a-long-folder-name/", count: 8) + "G-Player", isDirectory: true)
        }

        /// The state after the first run: a library folder, and nothing in it.
        func finishedOnboarding() {
            model.libraryRoot = root.appendingPathComponent("G-Player", isDirectory: true)
            model.onboardingDone = true
        }

        /// A space as "New Space" leaves it before Windows is set up in it: its folder is a prefix, nothing in it.
        func newSpace() -> Space {
            finishedOnboarding()
            let folder = model.paths!.spaces.appendingPathComponent("Main", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent("drive_c/windows"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("system.reg").path, contents: Data())
            let space = Space(name: "Main", path: folder.path, engineID: EngineCatalog.defaultForNewSpaces.id, origin: .managed)
            model.mutate { $0.spaces.append(space) }
            model.selection = .space(space.id)
            return space
        }

        /// Wine Staging installed, G-Player Wine on its way: the engine step a minute into the first run.
        func downloadingEngines() {
            model.libraryRoot = root.appendingPathComponent("G-Player", isDirectory: true)
            let staging = model.engineManager!.folder(for: EngineCatalog.wineStaging)
                .appendingPathComponent("Wine Staging.app/Contents/Resources/wine/bin", isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let wine = staging.appendingPathComponent("wine")
            FileManager.default.createFile(atPath: wine.path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
            let engine = EngineCatalog.crossover
            _ = model.begin(AppModel.downloadTitle(engine), "Downloading 41 of 98 MB", progress: 0.42)
        }

        /// What the engine step's next screen shows when this Mac has bottles and prefixes: found by the real finder in
        /// a made-up home folder, one of them with a path too long for Wine.
        func foundEnvironments() -> [FoundEnvironment] {
            let home = root.appendingPathComponent("home", isDirectory: true)
            let longFolder = String(repeating: "a-folder-with-a-long-name-", count: 4)
            let prefixes = ["Library/Application Support/CrossOver/Bottles/Sample Bottle", "Games/Sample Prefix",
                            "Games/\(longFolder)/Deep Prefix"]
            for path in prefixes {
                let folder = home.appendingPathComponent(path, isDirectory: true)
                try? FileManager.default.createDirectory(at: folder.appendingPathComponent("drive_c/windows"), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: folder.appendingPathComponent("system.reg").path, contents: Data())
            }
            let steam = home.appendingPathComponent(prefixes[0]).appendingPathComponent("drive_c/Program Files (x86)/Steam")
            try? FileManager.default.createDirectory(at: steam, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: steam.appendingPathComponent("steam.exe").path, contents: Data())
            return EnvironmentFinder.find(home: home, excluding: [], gptkInstalled: false)
        }
    }
}
