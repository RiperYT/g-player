import CryptoKit
import Foundation
import Testing
@testable import GPlayerCore

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Wine Mono for G-Player Wine: what is pinned, which engines and launchers use it, what a launch still has to do for it.
@Suite struct WineMonoCatalogTests {
    let mono = EngineCatalog.wineMono10_4_1

    @Test func theCatalogPinsWineMono1041ByItsPublishedDigest() {
        #expect(mono.version == "10.4.1" && mono.folderName == "wine-mono-10.4.1")
        #expect(mono.download.url.absoluteString == "https://dl.winehq.org/wine/wine-mono/10.4.1/wine-mono-10.4.1-x86.tar.xz")
        #expect(mono.download.fileName == "wine-mono-10.4.1-x86.tar.xz")
        #expect(mono.download.sha256 == "a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb")
        #expect(mono.download.approximateBytes == 39_590_692 && mono.download.role == .wineMono)
        // Unpacked: 242 MB on disk, 236 MB of files; the figure is rounded up.
        #expect(mono.installedBytes >= 242_421_760 && mono.installedBytes <= 260_000_000)
    }

    @Test func wineMonoBelongsToTheEngineRevisionThatExpectsIt() {
        #expect(EngineCatalog.crossover.mono == mono)
        #expect(EngineCatalog.crossoverRevision1.mono == mono)            // the same Wine, the same Wine Mono
        #expect(EngineCatalog.wineStaging.mono == nil)                    // no Mono is known to go with it: .NET stays off there
        #expect(EngineCatalog.gptk.mono == nil)
        // A decision about what an engine can run now keeps it.
        #expect(EngineCatalog.crossover.limited(to: [.wined3d]).mono == mono)
    }

    @Test func wineMonoIsFetchedWhenNeededAndNeverWithTheEngine() {
        for info in EngineCatalog.known { #expect(!info.downloads.contains { $0.role == .wineMono }, "\(info.id)") }
        #expect(EngineCatalog.crossover.downloads.map(\.role) == [.engine, .runtimeLibraries, .dxvk, .gstreamer])
        // So it is neither downloaded by the first run nor counted in what that needs.
        #expect(EngineCatalog.crossover.installWorkBytes == EngineCatalog.crossover.downloads.reduce(0) { $0 + $1.approximateBytes }
                    + EngineCatalog.gstreamer.scratchBytes)
    }

    @Test func onlyEpicsLauncherNeedsDotNet() {
        #expect(AppPresets.all.filter(\.needsDotNet).map(\.id) == ["epic"])
        #expect(AppPresets.epic.wineMono(on: EngineCatalog.crossover) == mono)
        #expect(AppPresets.epic.wineMono(on: EngineCatalog.crossoverRevision1) == mono)
        #expect(AppPresets.epic.wineMono(on: EngineCatalog.wineStaging) == nil)         // nothing to give it there
        for preset in AppPresets.all where preset.id != "epic" {
            #expect(preset.wineMono(on: EngineCatalog.crossover) == nil, "\(preset.id)")
        }
    }

    @Test func wineLooksForASharedWineMonoInItsOwnDataFolder() {
        let root = URL(fileURLWithPath: "/Users/someone/Games/G-Player/Engines/wine-cx-26.3.0-2/wine")
        #expect(WineMono.folder(of: mono, in: root).path == root.path + "/share/wine/mono/wine-mono-10.4.1")
        #expect(WineMono.supportInstaller(of: mono, in: root).path
                == root.path + "/share/wine/mono/wine-mono-10.4.1/support/winemono-support.msi")
    }

    @Test func theSupportPackageIsInstalledQuietlyFromTheEnginesFolder() {
        let root = URL(fileURLWithPath: "/Users/someone/Games/G-Player/Engines/wine-cx-26.3.0-2/wine")
        let epic = Space(name: "Epic Games Launcher", path: "/Users/someone/Games/G-Player/Spaces/Epic Games Launcher",
                         engineID: EngineCatalog.crossover.id, origin: .managed, presetID: "epic")
        #expect(WineMono.registerArguments(mono, wineRoot: root, in: epic)
                == ["msiexec", "/i",
                    #"Z:\Users\someone\Games\G-Player\Engines\wine-cx-26.3.0-2\wine\share\wine\mono\wine-mono-10.4.1\support\winemono-support.msi"#,
                    "/qn"])
    }

    @Test func theDownloadIsCalledWhatItIsAndTheRoomItNeedsIsTheFileAndWhatItUnpacksTo() {
        #expect(WineMono.sizeLabel(mono) == "40 MB")
        #expect(WineMono.neededBytes(mono, alreadyDownloaded: 0) == 39_590_692 + mono.installedBytes)
        // A stopped download that came part of the way is room already taken.
        #expect(WineMono.neededBytes(mono, alreadyDownloaded: 30_000_000) == 9_590_692 + mono.installedBytes)
        #expect(WineMono.neededBytes(mono, alreadyDownloaded: 50_000_000) == mono.installedBytes)
    }

    @Test func theWinePathMsCoreeBuildsForWineMonoMustFitIn260Characters() {
        // "Z:" + the folder + "\bin\libmono-2.0-x86_64.dll" (27), in a buffer of 260 with its terminator.
        let usual = URL(fileURLWithPath: "/Users/someone/Games/G-Player/Engines/wine-cx-26.3.0-2/wine")
        #expect(WineMono.loadPathLength(of: mono, in: usual) == 2 + usual.path.count + "/share/wine/mono/wine-mono-10.4.1".count + 27)
        #expect(WineMono.pathFits(mono, in: usual))
        // The longest library folder `PrefixPath` accepts (114 characters) leaves 54 to spare.
        let longest = URL(fileURLWithPath: "/" + String(repeating: "a", count: PrefixPath.maxLibraryRootLength - 1)
                          + "/Engines/wine-cx-26.3.0-2/wine")
        #expect(WineMono.loadPathLength(of: mono, in: longest) == 206 && WineMono.pathFits(mono, in: longest))
        // A folder an older G-Player allowed can be longer, and then the buffer would overflow: 167 characters is the last that fits.
        func atRoot(_ n: Int) -> URL {
            URL(fileURLWithPath: "/" + String(repeating: "a", count: n - 1) + "/Engines/wine-cx-26.3.0-2/wine")
        }
        #expect(WineMono.pathFits(mono, in: atRoot(167)) && !WineMono.pathFits(mono, in: atRoot(168)))
        // /var, /tmp and /etc count as /private/…, which is the path Wine gets.
        let tmp = URL(fileURLWithPath: "/tmp/e/wine")
        #expect(WineMono.loadPathLength(of: mono, in: tmp) == 2 + "/private/tmp/e/wine/share/wine/mono/wine-mono-10.4.1".count + 27)
    }

    @Test func whatALaunchStillHasToDoForWineMono() {
        // Nothing asks for it: nothing to do.
        #expect(WineMono.plan(wanted: nil, inEngine: false, registered: false) == nil)
        #expect(WineMono.plan(wanted: nil, inEngine: true, registered: true) == nil)
        // Each step by itself, from what is there.
        let neither = WineMono.plan(wanted: mono, inEngine: false, registered: false)
        #expect(neither == .init(package: mono, fetch: true, register: true) && neither?.isReady == false)
        let engineOnly = WineMono.plan(wanted: mono, inEngine: true, registered: false)
        #expect(engineOnly == .init(package: mono, fetch: false, register: true) && engineOnly?.isReady == false)
        let spaceOnly = WineMono.plan(wanted: mono, inEngine: false, registered: true)      // the engine was installed again
        #expect(spaceOnly == .init(package: mono, fetch: true, register: false) && spaceOnly?.isReady == false)
        let both = WineMono.plan(wanted: mono, inEngine: true, registered: true)
        #expect(both == .init(package: mono, fetch: false, register: false) && both?.isReady == true)
    }
}

/// What a space's `system.reg` says about the support package: read from the registry Wine wrote after installing it.
@Suite struct WineMonoRegistryTests {
    let mono = EngineCatalog.wineMono10_4_1

    /// The keys Wine writes for an installed "Wine Mono Windows Support" (copied from a real space), between other keys.
    func registry(version: String = "10.4.1", name: String = "Wine Mono Windows Support") -> String {
        #"""
        WINE REGISTRY Version 2
        ;; All keys relative to \\Machine

        #arch=win64

        [Software\\CodeWeavers\\CrossOver\\cxoffice] 1792759996
        "Version"="26.3.0"

        [Software\\Microsoft\\Windows\\CurrentVersion\\Installer\\UserData\\S-1-5-18\\Products\\C90019507D5733F55BFDF474111155CE\\InstallProperties] 1792769138
        #time=1dd6302c1d219ae
        "AuthorizedCDFPrefix"=""
        "Comments"=""
        "Contact"=""
        "DisplayName"="\#(name)"
        "DisplayVersion"="\#(version)"
        "EstimatedSize"=dword:00000000
        "InstallDate"="20261023"

        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\CXHTML] 1792759996
        "DisplayName"="CrossOver HTML engine"
        "UninstallString"="iexplore -unregserver"

        """#
    }

    @Test func theSupportPackageOfThisVersionCounts() {
        #expect(WineMono.isRegistered(mono, inRegistry: registry()))
    }

    @Test func anotherVersionAnotherNameOrNothingDoesNot() {
        #expect(!WineMono.isRegistered(mono, inRegistry: registry(version: "10.3.0")))           // an older Wine Mono: set up again
        #expect(!WineMono.isRegistered(mono, inRegistry: registry(version: "10.4.10")))
        #expect(!WineMono.isRegistered(mono, inRegistry: registry(name: "Wine Mono Runtime")))
        #expect(!WineMono.isRegistered(mono, inRegistry: registry(name: "Wine Mono Windows Support (old)")))
        #expect(!WineMono.isRegistered(mono, inRegistry: ""))
        #expect(!WineMono.isRegistered(mono, inRegistry: "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1\n\"Version\"=\"win10\"\n"))
    }

    @Test func theNameAndTheVersionMustBeInTheSameKey() {
        let split = #"""
            [Software\\A] 1
            "DisplayName"="Wine Mono Windows Support"
            "DisplayVersion"="9.0.0"

            [Software\\B] 2
            "DisplayName"="Something else"
            "DisplayVersion"="10.4.1"

            """#
        #expect(!WineMono.isRegistered(mono, inRegistry: split))
        // A key header ends the key before it even without a blank line.
        #expect(!WineMono.isRegistered(mono, inRegistry: "[Software\\\\A] 1\n\"DisplayName\"=\"Wine Mono Windows Support\"\n[Software\\\\B] 2\n\"DisplayVersion\"=\"10.4.1\"\n"))
    }

    @Test func aFileWithWindowsLineEndingsReadsTheSame() {
        #expect(WineMono.isRegistered(mono, inRegistry: registry().replacingOccurrences(of: "\n", with: "\r\n")))
    }

    @Test func aSpaceIsRegisteredByItsSystemRegAndNotWithoutOne() {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Epic"), preset: "epic")
        #expect(!WineMono.isRegistered(mono, in: s))                       // the stand-in file holds nothing
        tmp.file("Epic/system.reg", contents: Data(registry().utf8))
        #expect(WineMono.isRegistered(mono, in: s))
        #expect(!WineMono.isRegistered(mono, in: space(at: tmp.url.appendingPathComponent("Missing"))))
    }
}

/// What a launch of Epic's launcher plans for Wine Mono, and the DLL overrides that follow.
@Suite struct WineMonoLaunchTests {
    let mono = EngineCatalog.wineMono10_4_1
    let gplayerWine = EngineCatalog.crossover
    let launcherPath = "Epic/drive_c/Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"

    private func epicSpace(_ tmp: TempFolder, on engine: EngineInfo = EngineCatalog.crossover, registered: String? = nil,
                           origin: Space.Origin = .managed) -> Space {
        var s = space(at: tmp.prefix("Epic"), preset: "epic")
        s.engineID = engine.id
        s.origin = origin
        tmp.file(launcherPath)
        if let registered { tmp.file("Epic/system.reg", contents: Data(registered.utf8)) }
        return s
    }

    private func supportKey(version: String) -> String {
        #"""
        [Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{0591009C-75D7-5F33-B5DF-4F47111155EC}] 1792769138
        "DisplayName"="Wine Mono Windows Support"
        "DisplayVersion"="\#(version)"

        """#
    }

    private func launcher(in s: Space) -> Game {
        Game(title: "Epic Games Launcher", kind: .app, spaceID: s.id,
             executablePath: "drive_c/Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe")
    }

    private func overrides(_ plan: LaunchPlan, in s: Space) -> String {
        let root = URL(fileURLWithPath: "/tmp/engine/wine")
        let engine = Engine(info: gplayerWine, wineRoot: root, wine: root.appendingPathComponent("bin/wine"), dxvk: nil)
        return WineEnvironment.make(engine: engine, space: s, backend: .wined3d, tweaks: plan.tweaks, base: [:])["WINEDLLOVERRIDES"] ?? ""
    }

    @Test func aFirstStartHasToFetchAndRegisterAndStartsWithDotNetOffUntilThen() throws {
        let tmp = TempFolder()
        let s = epicSpace(tmp)
        let plan = try LaunchPlanner.plan(for: launcher(in: s), in: s)
        #expect(plan.wineMono == .init(package: mono, fetch: true, register: true))
        #expect(!plan.tweaks.dotNetAvailable)
        #expect(overrides(plan, in: s).hasPrefix("mscoree,mshtml=;"))      // as for every space: no Wine Mono prompt
    }

    @Test func withWineMonoInTheEngineOnlyTheSpaceStillNeedsIt() throws {
        let tmp = TempFolder()
        let s = epicSpace(tmp)
        let plan = try LaunchPlanner.plan(for: launcher(in: s), in: s, monoInstalled: true)
        #expect(plan.wineMono == .init(package: mono, fetch: false, register: true))
        #expect(!plan.tweaks.dotNetAvailable)
    }

    @Test func withBothInPlaceMscoreeStaysOnAndMshtmlOff() throws {
        let tmp = TempFolder()
        let s = epicSpace(tmp, registered: supportKey(version: "10.4.1"))
        let plan = try LaunchPlanner.plan(for: launcher(in: s), in: s, monoInstalled: true)
        #expect(plan.wineMono?.isReady == true)
        #expect(plan.tweaks.dotNetAvailable)
        let text = overrides(plan, in: s)
        #expect(text.hasPrefix("mshtml=;") && !text.contains("mscoree"))      // keeps Wine's Gecko prompt away, lets .NET load
    }

    @Test func aSpaceRegisteredBeforeTheEngineWasInstalledAgainStillNeedsTheFetch() throws {
        let tmp = TempFolder()
        let s = epicSpace(tmp, registered: supportKey(version: "10.4.1"))
        let plan = try LaunchPlanner.plan(for: launcher(in: s), in: s, monoInstalled: false)
        #expect(plan.wineMono == .init(package: mono, fetch: true, register: false))
        #expect(!plan.tweaks.dotNetAvailable)                                   // Wine would ask to download Mono itself
    }

    @Test func aSpaceThatHasAnOlderWineMonoIsRegisteredAgain() throws {
        let tmp = TempFolder()
        let s = epicSpace(tmp, registered: supportKey(version: "10.3.0"))
        let plan = try LaunchPlanner.plan(for: launcher(in: s), in: s, monoInstalled: true)
        #expect(plan.wineMono == .init(package: mono, fetch: false, register: true))
    }

    @Test func gamesStartedThroughTheLauncherNeedItToo() throws {
        let tmp = TempFolder()
        let s = epicSpace(tmp)
        // The launcher is the process when it isn't open yet, and it installs Epic Online Services for the game.
        let game = Game(title: "G", spaceID: s.id, source: .epic(appName: "x", launchURI: "com.epicgames.launcher://apps/x?action=launch"))
        let plan = try LaunchPlanner.plan(for: game, in: s)
        #expect(plan.wineMono == .init(package: mono, fetch: true, register: true))
    }

    @Test func nothingChangesWhereNothingNeedsIt() throws {
        let tmp = TempFolder()
        // Epic's launcher on Wine Staging: no Wine Mono goes with that Wine, so .NET stays off as before.
        let onStaging = epicSpace(tmp, on: EngineCatalog.wineStaging)
        let staging = try LaunchPlanner.plan(for: launcher(in: onStaging), in: onStaging, monoInstalled: true)
        #expect(staging.wineMono == nil && !staging.tweaks.dotNetAvailable)
        // Steam, a plain space and the Epic Games space of Legendary.
        for preset in ["steam", "legendary", nil] as [String?] {
            let other = TempFolder()
            var s = space(at: other.prefix("S"), preset: preset)
            s.engineID = gplayerWine.id
            other.file("S/drive_c/Games/x.exe")
            let game = Game(title: "X", spaceID: s.id, executablePath: "drive_c/Games/x.exe")
            let plan = try LaunchPlanner.plan(for: game, in: s, monoInstalled: true)
            #expect(plan.wineMono == nil && !plan.tweaks.dotNetAvailable, "\(preset ?? "none")")
        }
    }

    @Test func registeringWritesIntoTheSpaceSoAnExternalOneIsAsked() throws {
        let launch = LaunchPlan(arguments: [], backend: .wined3d, tweaks: LaunchTweaks(), chromiumHelpers: [])
        #expect(!launch.writesToSpace(engine: gplayerWine))
        var fetching = launch
        fetching.wineMono = .init(package: mono, fetch: true, register: false)         // the engine's own folder: not the space
        #expect(!fetching.writesToSpace(engine: gplayerWine))
        var registering = launch
        registering.wineMono = .init(package: mono, fetch: false, register: true)
        #expect(registering.writesToSpace(engine: gplayerWine))
        // Epic's launcher in a bottle of another app, the first time: it asks (DXMT's files are written too).
        let tmp = TempFolder()
        let s = epicSpace(tmp, origin: .external)
        #expect(s.allowsChanges == nil && !s.mayChange)
        #expect(try LaunchPlanner.plan(for: launcher(in: s), in: s).writesToSpace(engine: gplayerWine))
    }
}

/// Fetching Wine Mono into an installed engine, from stand-in archives that wait where the download would put them (a file with
/// the pinned checksum is not downloaded again), so nothing goes over the network.
@Suite struct WineMonoInstallTests {
    let version = "9.9.9"

    private func make(_ tmp: TempFolder, files: [String: String], installedBytes: Int64 = 1000)
        async throws -> (manager: EngineManager, engine: Engine, package: WineMonoPackage) {
        let source = tmp.dir("source")
        for (path, text) in files { tmp.file("source/\(path)", contents: Data(text.utf8)) }
        let archive = tmp.url.appendingPathComponent("wine-mono-\(version)-x86.tar")
        let made = try await Shell.runStoppable(Shell.tool("tar"), ["-cf", archive.path, "-C", source.path, "."])
        try #require(made.succeeded, "\(made.stderr)")
        let data = try Data(contentsOf: archive)
        let package = WineMonoPackage(
            version: version,
            download: PinnedDownload(url: URL(string: "https://stub.test/\(archive.lastPathComponent)")!, fileName: archive.lastPathComponent,
                                     sha256: sha(data), approximateBytes: Int64(data.count), role: .wineMono),
            installedBytes: installedBytes)
        let info = EngineInfo(id: "wine-cx-test", name: "Test Wine", version: "11.0", kind: .crossover, summary: "",
                              backends: [.wined3d], downloads: [], mono: package)
        let manager = EngineManager(paths: LibraryPaths(root: tmp.url.appendingPathComponent("Lib")))
        try manager.paths.createFolders()
        let bin = manager.folder(for: info).appendingPathComponent("wine/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("wine").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let engine = try #require(manager.engine(info))
        // Where the download is waited for.
        let file = manager.wineMonoDownloadFile(package, of: info)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return (manager, engine, package)
    }

    @Test func itUnpacksIntoTheEnginesDataFolderAndLeavesNothingElse() async throws {
        let tmp = TempFolder()
        let (manager, engine, package) = try await make(tmp, files: [
            "wine-mono-\(version)/support/winemono-support.msi": "msi",
            "wine-mono-\(version)/lib/mono/4.5/mscorlib.dll": "dll"])
        #expect(!engine.hasWineMono)
        let notes = LockedValue<[String]>([])
        try await manager.installWineMono(into: engine) { _, note in notes.set(notes.get() + [note]) }

        let folder = WineMono.folder(of: package, in: engine.wineRoot)
        #expect(folder.path.hasSuffix("/wine/share/wine/mono/wine-mono-\(version)"))
        #expect(engine.hasWineMono)
        #expect(try String(contentsOf: folder.appendingPathComponent("lib/mono/4.5/mscorlib.dll"), encoding: .utf8) == "dll")
        #expect(notes.get().contains("Unpacking Wine Mono") && notes.get().last == "Ready")
        // The download and the folder it was unpacked in are gone.
        #expect(!FileManager.default.fileExists(atPath: manager.wineMonoDownloadFolder(for: engine.info).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: manager.paths.engines.path) == ["wine-cx-test"])
    }

    @Test func whenItIsThereNothingIsFetchedOrChanged() async throws {
        let tmp = TempFolder()
        let (manager, engine, package) = try await make(tmp, files: ["wine-mono-\(version)/support/winemono-support.msi": "msi"])
        let folder = WineMono.folder(of: package, in: engine.wineRoot)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("support"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: WineMono.supportInstaller(of: package, in: engine.wineRoot))
        try WineMono.writeMarker(for: package, in: folder)
        try await manager.installWineMono(into: engine) { _, _ in }
        #expect(try String(contentsOf: WineMono.supportInstaller(of: package, in: engine.wineRoot), encoding: .utf8) == "mine")
        #expect(FileManager.default.fileExists(atPath: manager.wineMonoDownloadFile(package, of: engine.info).path))   // untouched
    }

    @Test func aPackageWithoutItsSupportInstallerIsRefusedAndTheEngineStaysAsItWas() async throws {
        let tmp = TempFolder()
        let (manager, engine, package) = try await make(tmp, files: ["wine-mono-\(version)/lib/mono/4.5/mscorlib.dll": "dll"])
        let error = try await #require(throws: ShellError.self) { try await manager.installWineMono(into: engine) { _, _ in } }
        #expect(error.localizedDescription.contains("doesn't hold wine-mono-\(version)"))
        #expect(!engine.hasWineMono)
        #expect(!FileManager.default.fileExists(atPath: WineMono.folder(of: package, in: engine.wineRoot).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: manager.paths.engines.path) == ["wine-cx-test"])   // no staging left
    }

    @Test func anEngineWithoutAWineMonoOfItsOwnIsRefused() async throws {
        let tmp = TempFolder()
        let (manager, _, _) = try await make(tmp, files: ["wine-mono-\(version)/support/winemono-support.msi": "msi"])
        let root = URL(fileURLWithPath: "/tmp/engine/wine")
        let staging = Engine(info: EngineCatalog.wineStaging, wineRoot: root, wine: root.appendingPathComponent("bin/wine"), dxvk: nil)
        let error = try await #require(throws: ShellError.self) { try await manager.installWineMono(into: staging) { _, _ in } }
        #expect(error.localizedDescription.contains("doesn't know a Wine Mono for Wine Staging"))
        #expect(!staging.hasWineMono)
    }

    @Test func aFullDiskIsSaidBeforeAnythingIsUnpacked() async throws {
        let tmp = TempFolder()
        let (manager, engine, _) = try await make(tmp, files: ["wine-mono-\(version)/support/winemono-support.msi": "msi"],
                                                  installedBytes: 1 << 60)
        let problem = try #require(manager.wineMonoDiskProblem(for: engine.info))
        #expect(problem.hasPrefix("Installing Wine Mono needs about"))
        let error = try await #require(throws: ShellError.self) { try await manager.installWineMono(into: engine) { _, _ in } }
        #expect(error.localizedDescription == problem)
        #expect(!engine.hasWineMono)
        #expect(EngineCatalog.wineStaging.mono == nil)
        #expect(manager.wineMonoDiskProblem(for: EngineCatalog.wineStaging) == nil)
    }

    @Test func theStartsCleanUpKeepsAStoppedDownloadAndRemovesADoneOrStaleOne() async throws {
        let tmp = TempFolder()
        let manager = EngineManager(paths: LibraryPaths(root: tmp.url))
        try manager.paths.createFolders()
        let info = EngineCatalog.crossover
        let part = tmp.file("Downloads/\(info.id)-mono/wine-mono-10.4.1-x86.tar.xz.part")
        // The engine isn't installed (or Wine Mono isn't in it): a download to go on with, for a week.
        manager.cleanLeftovers()
        #expect(FileManager.default.fileExists(atPath: part.path))
        manager.cleanLeftovers(now: Date().addingTimeInterval(8 * 24 * 3600))
        #expect(!FileManager.default.fileExists(atPath: part.path))
        // Wine Mono in its engine: the download is done with.
        let bin = manager.folder(for: info).appendingPathComponent("wine/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("wine").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let again = tmp.file("Downloads/\(info.id)-mono/wine-mono-10.4.1-x86.tar.xz.part")
        manager.cleanLeftovers()
        #expect(FileManager.default.fileExists(atPath: again.path))             // installed engine, but no Wine Mono yet
        let folder = tmp.dir("Engines/\(info.id)/wine/share/wine/mono/wine-mono-10.4.1")
        tmp.file("Engines/\(info.id)/wine/share/wine/mono/wine-mono-10.4.1/support/winemono-support.msi")
        try WineMono.writeMarker(for: EngineCatalog.wineMono10_4_1, in: folder)
        manager.cleanLeftovers()
        #expect(!FileManager.default.fileExists(atPath: again.deletingLastPathComponent().path))
    }

    @Test func theMarkerIsWrittenLastAndWithoutItTheCopyIsNotCounted() async throws {
        let tmp = TempFolder()
        let (manager, engine, package) = try await make(tmp, files: ["wine-mono-\(version)/support/winemono-support.msi": "msi"])
        let folder = WineMono.folder(of: package, in: engine.wineRoot)
        // A move cut short: the folder and the support package are there, the marker isn't.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("support"), withIntermediateDirectories: true)
        try Data("msi".utf8).write(to: WineMono.supportInstaller(of: package, in: engine.wineRoot))
        #expect(!WineMono.isUnpacked(package, in: engine.wineRoot) && !engine.hasWineMono)
        // So it is fetched again, and the copy that was there is replaced.
        try await manager.installWineMono(into: engine) { _, _ in }
        #expect(engine.hasWineMono)
        #expect(try String(contentsOf: WineMono.markerFile(in: folder), encoding: .utf8) == package.download.sha256)
        // A marker from another archive (a pin that changed under the same version) doesn't count either.
        try Data("0".utf8).write(to: WineMono.markerFile(in: folder))
        #expect(!engine.hasWineMono)
    }

    @Test func anEngineThatWasRemovedWhileWineMonoDownloadedIsNotMadeAgain() async throws {
        let tmp = TempFolder()
        let (manager, engine, package) = try await make(tmp, files: ["wine-mono-\(version)/support/winemono-support.msi": "msi"])
        let engineFolder = manager.folder(for: engine.info)
        // Removed (by hand, in Finder) before the install began, and while it went on: no folder of the engine comes back.
        try FileManager.default.removeItem(at: engineFolder)
        let error = try await #require(throws: ShellError.self) { try await manager.installWineMono(into: engine) { _, _ in } }
        #expect(error.localizedDescription == "Test Wine was removed while Wine Mono was being added to it.")
        #expect(!FileManager.default.fileExists(atPath: engineFolder.path))
        #expect(!FileManager.default.fileExists(atPath: WineMono.folder(of: package, in: engine.wineRoot).path))
        // The download stays for the next try.
        #expect(FileManager.default.fileExists(atPath: manager.wineMonoDownloadFile(package, of: engine.info).path))
    }

    @Test func removingAnEngineRemovesItsWineMonoDownloadToo() async throws {
        let tmp = TempFolder()
        let (manager, engine, _) = try await make(tmp, files: ["wine-mono-\(version)/support/winemono-support.msi": "msi"])
        let folder = manager.wineMonoDownloadFolder(for: engine.info)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        try manager.remove(engine.info)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!manager.isInstalled(engine.info))
    }
}
