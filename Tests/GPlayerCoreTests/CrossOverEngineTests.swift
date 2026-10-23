import Foundation
import Testing
@testable import GPlayerCore

@Suite struct CrossOverEngineTests {
    /// A CrossOver engine folder with Wine's own Direct3D DLLs and, if asked, DXMT and DXVK.
    func engine(_ tmp: TempFolder, dxmt: Bool = true, dxvk: Bool = true) -> Engine {
        let folder = tmp.url.appendingPathComponent("Engines/\(EngineCatalog.crossover.id)")
        let root = folder.appendingPathComponent("wine")
        let builtin = Data("MZ".utf8) + Data(count: 0x3e) + Data("Wine builtin DLL".utf8) + Data("wine's own".utf8)
        for dll in ["d3d10", "d3d11", "d3d12", "dxgi", "winemetal"] {
            tmp.file("Engines/\(EngineCatalog.crossover.id)/wine/lib/wine/x86_64-windows/\(dll).dll", contents: builtin)
        }
        tmp.file("Engines/\(EngineCatalog.crossover.id)/wine/lib/wine/i386-windows/winemetal.dll", contents: builtin)
        tmp.file("Engines/\(EngineCatalog.crossover.id)/wine/bin/wine")
        if dxmt {
            for arch in ["x86_64-windows", "i386-windows"] {
                for dll in ["d3d11", "d3d10core", "dxgi"] {
                    tmp.file("Engines/\(EngineCatalog.crossover.id)/wine/lib/dxmt/\(arch)/\(dll).dll", contents: builtin + Data("dxmt \(dll)".utf8))
                }
            }
        }
        if dxvk { for arch in ["x64", "x32"] { tmp.file("Engines/\(EngineCatalog.crossover.id)/dxvk/\(arch)/d3d11.dll", contents: Data("dxvk".utf8)) } }
        return Engine(info: EngineCatalog.crossover, wineRoot: root, wine: root.appendingPathComponent("bin/wine"),
                      dxvk: dxvk ? folder.appendingPathComponent("dxvk") : nil,
                      dxmt: dxmt ? root.appendingPathComponent("lib/dxmt") : nil)
    }

    /// An imported D3DMetal in the library at `tmp` (Apple's signature isn't checked here: `link` takes what
    /// `importD3DMetal` checked before).
    func importedD3DMetal(_ tmp: TempFolder) -> D3DMetalStore {
        let paths = LibraryPaths(root: tmp.url)
        tmp.file("D3DMetal/external/libd3dshared.dylib")
        tmp.file("D3DMetal/external/D3DMetal.framework/Versions/A/D3DMetal")
        for dll in ["d3d10", "d3d11", "d3d12", "dxgi"] {
            tmp.file("D3DMetal/x86_64-windows/\(dll).dll", contents: Data("apple \(dll) D3DMetalDLLs".utf8))
        }
        let info = D3DMetalStore.Info(version: "3.0", source: "test", importedAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        tmp.file("D3DMetal/D3DMETAL.json", contents: try! encoder.encode(info))
        return D3DMetalStore(paths: paths)
    }

    @Test func d3dMetalIsReadyOnlyOnceItIsCopiedIn() throws {
        let tmp = TempFolder()
        let e = engine(tmp)
        #expect(e.readyBackends == [.dxvk, .dxmt, .wined3d])
        #expect(EngineCatalog.crossover.limited(to: e.readyBackends).backends == [.dxvk, .dxmt, .wined3d])
        #expect(e.resolve(.d3dmetal) == .dxvk)                                         // not there yet: the first ready one
        let store = importedD3DMetal(tmp)
        try store.link(into: e)
        #expect(e.readyBackends == [.dxvk, .d3dmetal, .dxmt, .wined3d])
        #expect(e.resolve(.auto) == .dxvk && e.resolve(.d3dmetal) == .d3dmetal)
        #expect(engine(TempFolder(), dxmt: false, dxvk: false).readyBackends == [.wined3d])
    }

    @Test func linkingPutsApplesDLLsInAndUnlinkingTakesThemOut() throws {
        let tmp = TempFolder()
        let e = engine(tmp)
        let store = importedD3DMetal(tmp)
        let windows = e.wineRoot.appendingPathComponent("lib/wine/x86_64-windows")
        let unix = e.wineRoot.appendingPathComponent("lib/wine/x86_64-unix")
        let wines = try Data(contentsOf: windows.appendingPathComponent("d3d11.dll"))
        try FileManager.default.createDirectory(at: unix, withIntermediateDirectories: true)

        try store.link(into: e)
        #expect(D3DMetalStore.isApples(windows.appendingPathComponent("d3d11.dll")))
        #expect(D3DMetalStore.isApples(windows.appendingPathComponent("dxgi.dll")))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: unix.appendingPathComponent("d3d12.so").path)
                == "../../external/libd3dshared.dylib")
        #expect(try Data(contentsOf: e.wineRoot.appendingPathComponent("lib/wine-d3d/x86_64-windows/d3d11.dll")) == wines)
        #expect(e.d3dMetalLibrary != nil)
        try store.link(into: e)                                                      // same version: nothing to do

        try store.unlink(from: e)
        #expect(try Data(contentsOf: windows.appendingPathComponent("d3d11.dll")) == wines)
        #expect(!FileManager.default.fileExists(atPath: unix.appendingPathComponent("d3d12.so").path))
        #expect(e.d3dMetalLibrary == nil)
        // Wine Staging engines are never touched.
        let staging = Engine(info: EngineCatalog.wineStaging, wineRoot: e.wineRoot, wine: e.wine, dxvk: nil)
        try store.link(into: staging)
        #expect(e.d3dMetalLibrary == nil)
    }

    @Test func crossOverLaunchesGetCrossOversSettings() throws {
        let tmp = TempFolder()
        let e = engine(tmp)
        try importedD3DMetal(tmp).link(into: e)
        let s = Space(name: "Steam", path: "/tmp/Steam", engineID: e.info.id, origin: .managed)
        let metal = WineEnvironment.make(engine: e, space: s, backend: .d3dmetal, base: [:])
        #expect(metal["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == e.wineRoot.appendingPathComponent("lib/external/libd3dshared.dylib").path)
        #expect(metal["CX_ACTIVE_GRAPHICS_BACKEND"] == "d3dmetal")
        #expect(metal["DYLD_FALLBACK_LIBRARY_PATH"] == nil)
        #expect(metal["WINEDLLOVERRIDES"]?.contains("msvcp140_2,") == true && metal["WINEDLLOVERRIDES"]?.contains("vcomp140=n,b") == true)
        #expect(!(metal["WINEDLLOVERRIDES"] ?? "").contains("d3d11"))         // D3DMetal's DLLs are the builtins
        let dxmt = WineEnvironment.make(engine: e, space: s, backend: .dxmt, base: [:])
        #expect(dxmt["WINEDLLOVERRIDES"]?.contains("dxgi,d3d11,d3d10core=n,b") == true)
        let staging = WineEnvironment.make(engine: fakeEngine(), space: s, backend: .dxvk, base: [:])
        #expect(staging["WINEDLLOVERRIDES"]?.contains("msvcp140") == false)          // Wine Staging picks by version itself
    }

    // MARK: GStreamer

    /// The three variables G-Player Wine's launches get once its GStreamer plugins are in.
    private let gstreamerVariables = ["GST_PLUGIN_SYSTEM_PATH_1_0", "GST_REGISTRY_1_0", "GST_REGISTRY_FORK"]

    @Test func gPlayerWineUsesItsOwnGStreamerOnceItsPluginsAreIn() throws {
        let tmp = TempFolder()
        let e = engine(tmp)
        let s = Space(name: "Main", path: "/tmp/Main", engineID: e.info.id, origin: .managed)
        #expect(e.gstreamerPlugins == nil)
        for variable in gstreamerVariables { #expect(WineEnvironment.make(engine: e, space: s, backend: .dxvk, base: [:])[variable] == nil) }

        let plugins = tmp.dir("Engines/\(EngineCatalog.crossover.id)/wine/lib/gstreamer-1.0")
        let env = WineEnvironment.make(engine: e, space: s, backend: .dxvk, base: [:])
        #expect(e.gstreamerPlugins == plugins)
        #expect(env["GST_PLUGIN_SYSTEM_PATH_1_0"] == plugins.path)
        // The registry is in the engine's own folder, not in `wine/`, so removing the engine removes it.
        #expect(env["GST_REGISTRY_1_0"] == tmp.url.appendingPathComponent("Engines/\(EngineCatalog.crossover.id)/gstreamer-1.0-registry.x86_64.bin").path)
        #expect(env["GST_REGISTRY_FORK"] == "no")
        // Every backend and every kind of launch (Wine's own tools too) gets them.
        for backend in [GraphicsBackend.d3dmetal, .dxmt, .wined3d, .auto] {
            #expect(WineEnvironment.make(engine: e, space: s, backend: backend, base: [:])["GST_REGISTRY_FORK"] == "no")
        }
        // What a game sets for itself wins, as for any variable.
        let own = LaunchTweaks(environment: ["GST_REGISTRY_FORK": "yes", "GST_DEBUG": "3"])
        let tweaked = WineEnvironment.make(engine: e, space: s, backend: .dxvk, tweaks: own, base: [:])
        #expect(tweaked["GST_REGISTRY_FORK"] == "yes" && tweaked["GST_DEBUG"] == "3" && tweaked["GST_REGISTRY_1_0"] == env["GST_REGISTRY_1_0"])
        // A GStreamer in the app's own environment is never passed on.
        let inherited = WineEnvironment.make(engine: e, space: s, backend: .dxvk,
                                             base: ["GST_PLUGIN_PATH": "/Library/Frameworks/GStreamer.framework/x", "HOME": "/h"])
        #expect(inherited["GST_PLUGIN_PATH"] == nil && inherited["HOME"] == "/h")
    }

    @Test func revisionOneAndWineStagingNeverGetG_PlayerWinesGStreamer() throws {
        let tmp = TempFolder()
        let e = engine(tmp)
        let s = Space(name: "Main", path: "/tmp/Main", engineID: e.info.id, origin: .managed)
        // Revision 1 has no plugin folder, so it gets nothing (and its spaces run as before).
        let revision1 = Engine(info: EngineCatalog.crossoverRevision1, wineRoot: e.wineRoot, wine: e.wine, dxvk: e.dxvk, dxmt: e.dxmt)
        for variable in gstreamerVariables { #expect(WineEnvironment.make(engine: revision1, space: s, backend: .dxvk, base: [:])[variable] == nil) }
        // Wine Staging links a GStreamer.framework the user installed, if there is one; a plugin folder in its tree changes nothing.
        tmp.dir("Engines/\(EngineCatalog.crossover.id)/wine/lib/gstreamer-1.0")
        let staging = Engine(info: EngineCatalog.wineStaging, wineRoot: e.wineRoot, wine: e.wine, dxvk: e.dxvk)
        #expect(staging.gstreamerPlugins == nil)
        for variable in gstreamerVariables { #expect(WineEnvironment.make(engine: staging, space: s, backend: .dxvk, base: [:])[variable] == nil) }
        let toolkit = Engine(info: EngineCatalog.gptk, wineRoot: e.wineRoot, wine: e.wine, dxvk: nil)
        for variable in gstreamerVariables { #expect(WineEnvironment.make(engine: toolkit, space: s, backend: .auto, base: [:])[variable] == nil) }
    }

    @Test func aLinkCutShortIsTakenBackAndANewImportGoesIn() throws {
        let tmp = TempFolder()
        let e = engine(tmp)
        let store = importedD3DMetal(tmp)
        let windows = e.wineRoot.appendingPathComponent("lib/wine/x86_64-windows")
        let wines = try Data(contentsOf: windows.appendingPathComponent("d3d11.dll"))
        try store.link(into: e)
        // As if link stopped before its marker: unlink still puts Wine's DLLs back.
        try FileManager.default.removeItem(at: e.externalLibraries.appendingPathComponent(".gplayer-d3dmetal"))
        #expect(D3DMetalStore.linkedVersion(in: e) == nil && !e.readyBackends.contains(.d3dmetal))
        try store.unlink(from: e)
        #expect(try Data(contentsOf: windows.appendingPathComponent("d3d11.dll")) == wines)
        // A new import of the same version still goes in.
        try store.link(into: e)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let newer = D3DMetalStore.Info(version: "3.0", source: "test", importedAt: Date(timeIntervalSince1970: 100))
        tmp.file("D3DMetal/D3DMETAL.json", contents: try encoder.encode(newer))
        tmp.file("D3DMetal/x86_64-windows/d3d11.dll", contents: Data("apple d3d11 v2 D3DMetalDLLs".utf8))
        try store.link(into: e)
        #expect(try Data(contentsOf: windows.appendingPathComponent("d3d11.dll")) == Data("apple d3d11 v2 D3DMetalDLLs".utf8))
    }

    @Test func runtimeLibrariesComeFromWineStagingWithoutMoltenVKOrTheLoader() throws {
        let tmp = TempFolder()
        let from = tmp.dir("staging/lib"), to = tmp.url.appendingPathComponent("cx/lib")
        for lib in EngineManager.runtimeLibraries + ["libMoltenVK.dylib", "libvulkan.1.dylib", "libbrotlidec.1.dylib"] {
            tmp.file("staging/lib/\(lib)")
        }
        try FileManager.default.createSymbolicLink(at: from.appendingPathComponent("libfreetype.dylib"), withDestinationURL: from.appendingPathComponent("libfreetype.6.dylib"))
        let manager = EngineManager(paths: LibraryPaths(root: tmp.url))
        try manager.copyRuntimeLibraries(from: from, into: to)
        let copied = try FileManager.default.contentsOfDirectory(atPath: to.path).sorted()
        #expect(copied == (EngineManager.runtimeLibraries + ["libbrotlidec.1.dylib", "libfreetype.dylib"]).sorted())
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: to.appendingPathComponent("libfreetype.dylib").path)) != nil)
        try FileManager.default.removeItem(at: from.appendingPathComponent("libSDL2-2.0.0.dylib"))
        #expect(throws: (any Error).self) { try manager.copyRuntimeLibraries(from: from, into: tmp.url.appendingPathComponent("cx2/lib")) }
    }

    @Test func steamRestartsOnlyWhenItsSettingsDiffer() throws {
        let tmp = TempFolder()
        let s = Space(name: "Steam", path: tmp.prefix("Steam").path, engineID: EngineCatalog.crossover.id, origin: .managed, presetID: "steam")
        tmp.file("Steam/drive_c/Program Files (x86)/Steam/steam.exe")
        var g = Game(title: "Example", spaceID: s.id, source: .steam(appID: "1"))
        g.analysis = GameAnalysis(engine: .unreal, graphics: [.d3d12], architecture: .x64)
        let ready: [GraphicsBackend] = [.dxvk, .d3dmetal, .dxmt, .wined3d]
        // Steam on D3DMetal by default there, like the game; on DXVK (started for a 32-bit game) it restarts.
        #expect(!(try LaunchPlanner.plan(for: g, in: s, ready: ready).needsFreshLauncher))
        #expect(try LaunchPlanner.plan(for: g, in: s, ready: ready, launcher: LauncherSettings(backend: .dxvk)).needsFreshLauncher)
        #expect(!(try LaunchPlanner.plan(for: g, in: s, ready: ready, launcher: LauncherSettings(backend: .d3dmetal)).needsFreshLauncher))
        let launcher = Game(title: "Steam", kind: .app, spaceID: s.id, executablePath: "drive_c/Program Files (x86)/Steam/steam.exe")
        #expect(try LaunchPlanner.plan(for: launcher, in: s, ready: ready).backend == .d3dmetal)
        #expect(try LaunchPlanner.plan(for: launcher, in: s, ready: [.dxvk, .dxmt, .wined3d]).backend == .auto)
        var old = g
        old.analysis = GameAnalysis(graphics: [.d3d11], architecture: .x86)
        #expect(try LaunchPlanner.plan(for: old, in: s, ready: ready, launcher: LauncherSettings(backend: .d3dmetal)).needsFreshLauncher)
        #expect(LaunchPlan(arguments: [], backend: .dxmt, tweaks: LaunchTweaks(), chromiumHelpers: [])
                    .writesToSpace(engine: EngineCatalog.crossover.limited(to: ready)))
    }

    @Test func dxmtsDLLsGoIntoTheSpaceAsNativeOnes() throws {
        let tmp = TempFolder()
        let e = engine(tmp)
        let s = space(at: tmp.prefix("Main"))
        tmp.dir("Main/drive_c/windows/syswow64")
        try SpaceManager(paths: LibraryPaths(root: tmp.url)).prepareGraphics(.dxmt, engine: e, space: s)
        let d3d11 = try Data(contentsOf: s.driveC.appendingPathComponent("windows/system32/d3d11.dll"))
        #expect(d3d11.range(of: Data("dxmt d3d11".utf8)) != nil)
        #expect(d3d11.range(of: Data("Wine builtin DLL".utf8)) == nil)                // loads as native with n,b
        #expect(FileManager.default.fileExists(atPath: s.driveC.appendingPathComponent("windows/syswow64/dxgi.dll").path))
        // winemetal stays Wine's builtin placeholder.
        let helper = try Data(contentsOf: s.driveC.appendingPathComponent("windows/system32/winemetal.dll"))
        #expect(helper.range(of: Data("Wine builtin DLL".utf8)) != nil)
        // A DXVK launch afterwards gets DXVK's d3d11 back.
        try SpaceManager(paths: LibraryPaths(root: tmp.url)).prepareGraphics(.dxvk, engine: e, space: s)
        #expect(try Data(contentsOf: s.driveC.appendingPathComponent("windows/system32/d3d11.dll")) == Data("dxvk".utf8))
    }

    @Test func dxvkGetsWinesOwnDXGIWhileD3DMetalIsIn() throws {
        let tmp = TempFolder()
        let e = engine(tmp)
        tmp.file("Engines/\(EngineCatalog.crossover.id)/wine/lib/wine/i386-windows/dxgi.dll", contents: Data("wine i386 dxgi".utf8))
        let s = space(at: tmp.prefix("Main"))
        tmp.dir("Main/drive_c/windows/syswow64")
        let manager = SpaceManager(paths: LibraryPaths(root: tmp.url))
        try manager.prepareGraphics(.dxmt, engine: e, space: s)                    // leaves DXMT's dxgi in both folders
        try importedD3DMetal(tmp).link(into: e)
        try manager.prepareGraphics(.dxvk, engine: e, space: s)
        let dxgi = try Data(contentsOf: s.driveC.appendingPathComponent("windows/system32/dxgi.dll"))
        #expect(dxgi.range(of: Data("wine's own".utf8)) != nil && dxgi.range(of: Data("Wine builtin DLL".utf8)) == nil)
        #expect(try Data(contentsOf: s.driveC.appendingPathComponent("windows/syswow64/dxgi.dll")) == Data("wine i386 dxgi".utf8))
        let env = WineEnvironment.make(engine: e, space: s, backend: .dxvk, base: [:])
        #expect(env["WINEDLLOVERRIDES"]?.contains("d3d11,d3d10core,dxgi=n,b") == true)
    }

    @Test func directX12GoesToD3DMetalOnlyWhenItIsThere() {
        let dx12 = GameAnalysis(engine: .unreal, graphics: [.d3d12], architecture: .x64, onlyDirect3D12: true)
        func resolve(_ a: GameAnalysis, _ ready: [GraphicsBackend], _ options: LaunchOptions = .default) -> CompatPlan {
            CompatResolver.resolve(.init(engine: EngineCatalog.crossover.limited(to: ready), analysis: a, fixes: [], options: options))
        }
        let ready = resolve(dx12, [.dxvk, .d3dmetal, .dxmt, .wined3d])
        #expect(ready.backend == .d3dmetal && ready.blockers.isEmpty && !ready.arguments.contains("-dx11"))
        let notYet = resolve(dx12, [.dxvk, .dxmt, .wined3d])
        #expect(notYet.backend == .dxvk)
        #expect(notYet.blockers.first?.detail?.contains("Turn on Apple's D3DMetal") == true)
        // DirectX 9 has nothing to gain from D3DMetal; a blocked game whose space has D3DMetal hears how to pick it.
        #expect(resolve(GameAnalysis(graphics: [.d3d9], architecture: .x64), [.dxvk, .d3dmetal, .dxmt, .wined3d]).backend == .dxvk)
        let compatible = resolve(dx12, [.dxvk, .d3dmetal, .dxmt, .wined3d], LaunchOptions(profile: .compatible))
        #expect(compatible.blockers.first?.detail?.contains("choose the Recommended profile") == true)
        // 64-bit DirectX 11 takes D3DMetal too once it is there, DXVK before; never a 32-bit program, whatever the profile.
        let dx11 = GameAnalysis(graphics: [.d3d11], architecture: .x64)
        #expect(resolve(dx11, [.d3dmetal, .dxvk, .dxmt, .wined3d]).backend == .d3dmetal)
        #expect(resolve(dx11, [.dxvk, .dxmt, .wined3d]).backend == .dxvk)
        let x86 = GameAnalysis(graphics: [.d3d11], architecture: .x86)
        #expect(resolve(x86, [.d3dmetal, .dxvk, .dxmt, .wined3d]).backend == .dxvk)
        #expect(resolve(x86, [.d3dmetal, .dxvk, .dxmt, .wined3d], LaunchOptions(profile: .fast)).backend == .dxvk)
        // On Wine Staging the blocker points to G-Player Wine.
        let staging = CompatResolver.resolve(.init(engine: EngineCatalog.wineStaging, analysis: dx12, fixes: [], options: .default))
        #expect(staging.blockers.first?.detail?.contains("Switch this space to G-Player Wine") == true)
    }
}
