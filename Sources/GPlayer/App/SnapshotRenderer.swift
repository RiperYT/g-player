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
                let sandbox = Sandbox(firstRunSpaces: shot.firstRunSpaces)
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
        /// The first spaces the first run still has to make, as the settings would say after a first launch.
        var firstRunSpaces: [String] = []
        let view: (Sandbox) -> AnyView
    }

    private static let windowSize = CGSize(width: 900, height: 600)
    private static let mainSize = CGSize(width: 1100, height: 700)
    private static let settingsSize = CGSize(width: 560, height: 820)

    private static var shots: [Shot] {
        func onboarding(_ name: String, _ preview: @escaping (Sandbox) -> OnboardingView.Preview) -> Shot {
            Shot(name: name, size: windowSize) { box in AnyView(OnboardingView(preview: preview(box)).environment(box.model)) }
        }
        func problem(_ name: String, _ problem: LibraryProblem) -> Shot {
            Shot(name: name, size: windowSize) { box in
                AnyView(LibraryProblemView(problem: problem).frame(width: windowSize.width, height: windowSize.height).environment(box.model))
            }
        }
        return [
            onboarding("onboarding-1-welcome") { _ in .init(step: .welcome) },
            onboarding("onboarding-2-location") { _ in .init(step: .location) },
            onboarding("onboarding-2-location-too-long") { box in .init(step: .location, root: box.tooLongFolder) },
            onboarding("onboarding-3-engines") { _ in .init(step: .engine) },
            onboarding("onboarding-3-engines-no-rosetta") { _ in .init(step: .engine, rosetta: false) },
            onboarding("onboarding-3-engines-installing-rosetta") { _ in .init(step: .engine, rosetta: false, installingRosetta: true) },
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
            Shot(name: "main-library-setting-up-engines", size: mainSize, firstRunSpaces: ["main", "steam"]) { box in
                box.finishedOnboarding()
                box.downloadingFirstEngine()
                return AnyView(MainWindow(detail: LibraryView(filter: .all)).environment(box.model))
            },
            Shot(name: "main-library-setting-up-spaces", size: mainSize, firstRunSpaces: ["main", "steam"]) { box in
                box.finishedOnboarding()
                box.installEngine(EngineCatalog.crossover)
                _ = box.model.begin("Creating “Main”", "Setting up Windows. This takes about a minute the first time.")
                return AnyView(MainWindow(detail: LibraryView(filter: .all)).environment(box.model))
            },
            Shot(name: "main-library-updating-engine", size: mainSize) { box in
                box.libraryWithGames()
                _ = box.model.begin(AppModel.downloadTitle(EngineCatalog.crossover), "Downloading 120 of 446 MB", progress: 0.27,
                                    note: EngineMigration.shortUpdateNote(for: EngineCatalog.crossover))
                return AnyView(MainWindow(detail: LibraryView(filter: .all)).environment(box.model))
            },
            Shot(name: "main-library-notes", size: mainSize) { box in
                box.libraryWithGames()
                return AnyView(MainWindow(detail: LibraryView(filter: .all)).environment(box.model))
            },
            Shot(name: "inspector-launcher", size: CGSize(width: 340, height: 760)) { box in
                box.libraryWithGames()
                let steam = box.model.games.first { $0.kind == .app }!
                return AnyView(GameInspector(game: steam).environment(box.model))
            },
            Shot(name: "main-space-new", size: mainSize) { box in
                let space = box.newSpace()
                return AnyView(MainWindow(detail: SpaceView(space: space)).environment(box.model))
            },
            // A space made before G-Player Wine was the one engine: it says what it runs on, and offers the move.
            Shot(name: "main-space-on-staging", size: mainSize) { box in
                let space = box.newSpace(on: EngineCatalog.wineStaging)
                return AnyView(MainWindow(detail: SpaceView(space: space)).environment(box.model))
            },
            Shot(name: "main-space-on-toolkit-off", size: mainSize) { box in
                let space = box.newSpace(on: EngineCatalog.gptk)
                return AnyView(MainWindow(detail: SpaceView(space: space)).environment(box.model))
            },
            // With "Choose the Wine engine for each space" on, the engine menu is back.
            Shot(name: "main-space-on-staging-choosing", size: mainSize) { box in
                let space = box.newSpace(on: EngineCatalog.wineStaging)
                box.model.choosesEngines = true
                return AnyView(MainWindow(detail: SpaceView(space: space)).environment(box.model))
            },
            // The screen over the window when the library can't be opened, in each of its four cases.
            problem("library-problem-folder-missing", LibraryProblem(kind: .folderMissing, root: URL(fileURLWithPath: "/Volumes/Games/G-Player"))),
            problem("library-problem-file-missing", LibraryProblem(kind: .fileMissing, root: LibraryPaths.defaultRoot, previousIsUsable: true)),
            problem("library-problem-damaged", LibraryProblem(kind: .damaged, root: LibraryPaths.defaultRoot, reason: "spaces[2].engineID: missing",
                                                              brokenCopy: LibraryPaths.defaultRoot.appendingPathComponent("library.json.broken-2026-10-23-142530"),
                                                              previousIsUsable: true)),
            problem("library-problem-unreadable", LibraryProblem(kind: .unreadable, root: LibraryPaths.defaultRoot,
                                                                 reason: "you don’t have permission to view it")),
            Shot(name: "sheet-new-space") { box in AnyView(NewSpaceSheet().environment(box.model)) },
            Shot(name: "sheet-new-space-choosing-engine") { box in
                box.finishedOnboarding()
                box.installEngine(EngineCatalog.wineStaging)
                box.model.choosesEngines = true
                return AnyView(NewSpaceSheet().environment(box.model))
            },
            Shot(name: "sheet-add-existing-space") { box in
                AnyView(ExistingSpacesView(found: box.foundEnvironments(), back: {}, done: {}).environment(box.model))
            },
            Shot(name: "sheet-add-existing-space-none") { box in
                AnyView(ExistingSpacesView(found: [], back: {}, done: {}).environment(box.model))
            },
            Shot(name: "sheet-add-game") { box in AnyView(AddGameSheet(initialSource: nil).environment(box.model)) },
            Shot(name: "sheet-changes-request") { box in
                let space = box.adoptedSpace()
                return AnyView(ChangesRequestSheet(request: ChangesRequest(spaceID: space.id, then: [])).environment(box.model))
            },
            Shot(name: "sheet-failed-launch") { box in
                AnyView(FailedLaunchSheet(game: box.failedGame(tryOthers: true)).environment(box.model))
            },
            Shot(name: "sheet-failed-launch-nothing-left") { box in
                AnyView(FailedLaunchSheet(game: box.failedGame(tryOthers: false)).environment(box.model))
            },
            Shot(name: "settings-engines", size: settingsSize) { box in AnyView(EngineSettings(focus: .constant("")).environment(box.model)) },
            Shot(name: "settings-engines-advanced", size: settingsSize) { box in
                box.installEngine(EngineCatalog.wineStaging)
                return AnyView(Form { AdvancedEngineSection(expanded: true) }.formStyle(.grouped).environment(box.model))
            },
            Shot(name: "settings-advanced", size: CGSize(width: 560, height: 330)) { box in
                AnyView(AdvancedSettings().environment(box.model))
            },
            Shot(name: "settings-engines-from-d3dmetal-alert", size: CGSize(width: 560, height: 410)) { box in
                AnyView(EngineSettings(focus: .constant(SettingsTab.Focus.toolkit.rawValue)).environment(box.model))
            },
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
        let model: AppModel

        /// - Parameter firstRunSpaces: the first spaces still to make, as a first launch leaves them in the settings.
        init(firstRunSpaces: [String] = []) {
            let defaults = MemoryDefaults()
            if !firstRunSpaces.isEmpty { defaults.set(firstRunSpaces, forKey: "firstRunSpaces") }
            model = AppModel(defaults: defaults, watching: false)
        }

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
        func newSpace(on engine: EngineInfo = EngineCatalog.defaultForNewSpaces) -> Space {
            finishedOnboarding()
            let folder = model.paths!.spaces.appendingPathComponent("Main", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent("drive_c/windows"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("system.reg").path, contents: Data())
            let space = Space(name: "Main", path: folder.path, engineID: engine.id, origin: .managed)
            model.mutate { $0.spaces.append(space) }
            model.selection = .space(space.id)
            return space
        }

        /// An engine that looks installed to `EngineManager`: a `wine` file that can run. Nothing of it is real.
        func installEngine(_ info: EngineInfo) {
            model.libraryRoot = root.appendingPathComponent("G-Player", isDirectory: true)
            let folder = model.engineManager!.folder(for: info)
            let bin = info.kind == .wineStaging ? folder.appendingPathComponent("Wine Staging.app/Contents/Resources/wine/bin", isDirectory: true)
                                                : folder.appendingPathComponent("wine/bin", isDirectory: true)
            try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: bin.appendingPathComponent("wine").path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }

        /// G-Player Wine on its way, nothing else installed: the engine step a minute into the first run.
        func downloadingEngines() {
            model.libraryRoot = root.appendingPathComponent("G-Player", isDirectory: true)
            _ = model.begin(AppModel.downloadTitle(EngineCatalog.crossover), "Downloading 268 of 639 MB", progress: 0.42)
        }

        /// Nothing installed yet, G-Player Wine just started: the first minute of the first run.
        func downloadingFirstEngine() {
            model.libraryRoot = root.appendingPathComponent("G-Player", isDirectory: true)
            _ = model.begin(AppModel.downloadTitle(EngineCatalog.crossover), "Downloading 115 of 639 MB", progress: 0.18)
        }

        /// Spaces on both engines, a few games, and what the library says to someone who just updated and just got Steam.
        func libraryWithGames() {
            finishedOnboarding()
            try? model.paths?.createFolders()
            let spaces = model.paths!.spaces
            let main = Space(name: "Main", path: spaces.appendingPathComponent("Main").path, engineID: EngineCatalog.wineStaging.id,
                             origin: .managed, colorIndex: 0)
            let steam = Space(name: "Steam", path: spaces.appendingPathComponent("Steam").path, engineID: EngineCatalog.crossover.id,
                              origin: .managed, presetID: AppPresets.steam.id, colorIndex: 1)
            let launcher = Game(title: "Steam", kind: .app, spaceID: steam.id, executablePath: "C:\\Program Files (x86)\\Steam\\steam.exe")
            model.mutate { state in
                state.spaces += [main, steam]
                state.games += [Game(title: "Overcooked", spaceID: main.id, executablePath: "C:\\Games\\Overcooked\\Overcooked.exe"),
                                Game(title: "Cossacks 3", spaceID: steam.id, executablePath: "C:\\Games\\Cossacks 3\\cossacks.exe"),
                                launcher]
            }
            model.storeReadyID = AppPresets.steam.id
        }

        /// A space found on the Mac and added, which belongs to CrossOver.
        func adoptedSpace() -> Space {
            finishedOnboarding()
            try? model.paths?.createFolders()
            let space = Space(name: "Sample Bottle", path: root.appendingPathComponent("Sample Bottle").path,
                              engineID: EngineCatalog.crossover.id, origin: .external, originNote: "CrossOver")
            model.mutate { $0.spaces.append(space) }
            return space
        }

        /// A game that didn't start, with a log that said nothing: Try Other Graphics is on offer, or nothing is.
        func failedGame(tryOthers: Bool) -> Game {
            finishedOnboarding()
            try? model.paths?.createFolders()
            let space = Space(name: "Main", path: root.appendingPathComponent("Main").path,
                              engineID: EngineCatalog.crossover.id, origin: .managed)
            var game = Game(title: "Overcooked", spaceID: space.id, executablePath: "C:\\Games\\Overcooked\\Overcooked.exe")
            game.analysis = GameAnalysis(graphics: [.d3d11], architecture: .x64)
            model.mutate { $0.spaces.append(space); $0.games.append(game) }
            // With Try Other Graphics on offer the log named the graphics; without it, nothing left to try.
            model.diagnoses[game.id] = [tryOthers
                ? Diagnosis(kind: .graphics, title: "Graphics didn't start", detail: "The game couldn't create its graphics device.",
                            remedy: .useProfile(.compatible))
                : Diagnosis(kind: .crash, title: "The game closed right away", detail: "It quit after 3 seconds without saying why.",
                            remedy: .none)]
            if tryOthers {
                model.failedAutoLaunches[game.id] = AutoLaunch(backend: .dxvk, engineID: space.engineID, startedAt: Date(), retried: false)
            }
            return game
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
