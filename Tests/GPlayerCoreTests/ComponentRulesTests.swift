import Foundation
import Testing
@testable import GPlayerCore

// Which components can be installed, and what the resolver does with the ids fixes ask for. Real ids come from
// the shipped GameFixes.json.

@Suite struct ComponentRulesTests {
    private func fix(_ id: String) throws -> GameFix {
        try #require(GameFixDatabase.bundled.fix(id: id), "\(id) is not in GameFixes.json any more")
    }

    private func resolve(_ fixes: [GameFix], programs: [String] = [], store: Bool = true, profile: LaunchProfile = .recommended,
                         engine: EngineInfo = EngineCatalog.wineStaging) -> CompatPlan {
        CompatResolver.resolve(.init(engine: engine, analysis: nil, fixes: fixes, options: LaunchOptions(profile: profile),
                                     isStoreGame: store, programNames: programs))
    }

    // MARK: Aliases

    @Test func theOlderVisualCRuntimesAreTheNewestOne() {
        for id in ["vcrun2015", "vcrun2017", "vcrun2019"] {
            #expect(RuntimeCatalog.canonicalID(id) == "vcrun2022", "\(id)")
            #expect(RuntimeCatalog.isInstallable(id), "\(id)")
        }
        for id in ["vcrun2022", "vcrun2013", "d3dx9", "nonsense", ""] { #expect(RuntimeCatalog.canonicalID(id) == id) }
        #expect(!RuntimeCatalog.all.contains { $0.id == "vcrun2019" })
        #expect(RuntimeCatalog.component("vcrun2022") != nil)
    }

    @Test func aFixThatAsksForVcrun2019GetsVcrun2022Once() throws {
        let plan = resolve([try fix("steam-1532190")])                    // vcrun2019, d3dcompiler_47, msxml3
        #expect(plan.components == ["vcrun2022", "d3dcompiler_47"])
        let both = resolve([GameFix(id: "a", components: ["vcrun2015", "vcrun2019"], source: "t"),
                            GameFix(id: "b", components: ["vcrun2017"], source: "t")])
        #expect(both.components == ["vcrun2022", "d3dcompiler_47"])
    }

    // MARK: What can be installed

    @Test func theCatalogAndKnownVerbsCanBeInstalled() {
        for c in RuntimeCatalog.all { #expect(RuntimeCatalog.isInstallable(c.id), "\(c.id)") }
        for id in ["d3dx9_43", "d3dx9_31", "d3dcompiler_42", "dsound", "directplay", "mfc90", "mfc42", "ucrtbase2019", "verdana",
                   "arial", "sourcehansans", "xact_x64", "vcrun2012", "l3codecx"] {
            #expect(RuntimeCatalog.isInstallable(id), "\(id)")
        }
    }

    @Test func theseCanNeverBeInstalled() {
        // Not winetricks verbs, no checksum for the download, or an installer that doesn't work in a 64-bit space.
        for id in ["dgvoodoo2", "dotnetdesktop10", "eossdk", "segoe_script", "xliveless", "ubisoftconnect", "dotnet20", "dotnet35",
                   "dotnet20sp2", "dotnet30", "dotnet35sp1", "dotnet40", "d3dcompiler_46", "icodecs"] {
            #expect(!RuntimeCatalog.isInstallable(id), "\(id)")
        }
        // Settings are not components, and nothing with = is a component.
        for id in ["win7", "winxp", "win10", "win81", "win8", "vista", "win2k", "win98", "hidewineexports=enable", "vd=1280x720",
                   "sound=alsa", "a=b", "", "--self-update", "../x", "annihilate", "list", "prefix"] {
            #expect(!RuntimeCatalog.isInstallable(id), "\(id)")
        }
    }

    @Test func theInstallerRefusesWhatCantBeInstalledBeforeTouchingAnything() async {
        let tmp = TempFolder()
        let installer = RuntimeInstaller(paths: LibraryPaths(root: tmp.url.appendingPathComponent("Library")))
        let s = space(at: tmp.prefix("Main"))
        for id in ["dgvoodoo2", "win7", "ubisoftconnect", "hidewineexports=enable"] {
            do {
                try await installer.install(["vcrun2008", id], in: s, engine: fakeEngine()) { _, _ in }
                Issue.record("\(id) was accepted")
            } catch { #expect(error.localizedDescription.contains("isn't a component G-Player can install")) }
        }
        #expect(installer.installed(in: s).isEmpty)
        #expect(installer.failed(in: s).isEmpty)
    }

    @Test func everyComponentTheFixDataAsksForIsDecided() {
        // When GameFixes.json is imported again and a new id turns up, this fails until someone decides about it.
        let ids = Set(GameFixDatabase.bundled.fixes.flatMap(\.components))
        #expect(ids.count > 50)
        for id in ids {
            let classes = [RuntimeCatalog.isInstallable(id), RuntimeCatalog.unsupportedNames[id] != nil,
                           CompatResolver.windowsVersions[id] != nil, CompatResolver.hideWineExportsVerbs[id] != nil]
            #expect(classes.filter { $0 }.count == 1, "\(id) is in \(classes.filter { $0 }.count) classes: installable, unsupported, Windows version, hidewineexports")
        }
    }

    @Test func everyComponentTheLogDiagnosisSuggestsCanBeInstalled() {
        for (_, component) in LogDiagnosis.componentForDLL { #expect(RuntimeCatalog.isInstallable(component), "\(component)") }
    }

    // MARK: The resolver and the ids of real fixes

    @Test func componentsThatCantBeInstalledAreListedOnceInPlainWords() throws {
        let plan = resolve([try fix("steam-12840"), try fix("steam-730830")])        // xliveless; dgvoodoo2
        #expect(plan.components == ["vcrun2022", "d3dcompiler_47"])
        let notes = plan.warnings.filter { $0.title.hasPrefix("Needs ") }
        #expect(notes.count == 1)
        #expect(notes.first?.title == "Needs xliveless and DirectX wrapper dgVoodoo 2, which G-Player can't install yet.")
        #expect(plan.appliedFixIDs.isEmpty)                                          // nothing in them could be done
    }

    @Test func installableComponentsStayWhenOthersCantBeInstalled() throws {
        let plan = resolve([try fix("steam-1259970")])                               // vcrun2019, allfonts, dotnet462
        #expect(plan.components == ["vcrun2022", "d3dcompiler_47"])
        #expect(plan.warnings.contains { $0.title == "Needs every Windows font and .NET 4.6.2, which G-Player can't install yet." })
        let mixed = resolve([try fix("steam-105450")])                               // mfc42, l3codecx, corefonts, winxp
        #expect(mixed.components == ["vcrun2022", "d3dcompiler_47", "mfc42", "l3codecx", "corefonts"])
        #expect(!mixed.warnings.contains { $0.title.hasPrefix("Needs ") })
        #expect(mixed.appliedFixIDs == ["steam-105450"])
    }

    @Test func nothingBadReachesTheInstallerFromAnyFixInTheData() {
        for fix in GameFixDatabase.bundled.fixes {
            for profile in [LaunchProfile.recommended, .compatible] {
                let plan = resolve([fix], programs: ["Game.exe"], profile: profile)
                for id in plan.components {
                    #expect(RuntimeCatalog.isInstallable(id) && !id.contains("=") && CompatResolver.windowsVersions[id] == nil
                            && RuntimeCatalog.canonicalID(id) == id, "\(fix.id): \(id)")
                }
                #expect(Set(plan.components).count == plan.components.count, "\(fix.id)")
            }
        }
    }

    @Test func compatibleModeAlsoDropsWhatCantBeInstalled() throws {
        let plan = resolve([try fix("steam-12840")], profile: .compatible)
        #expect(plan.components == ["vcrun2022", "d3dcompiler_47"])
        #expect(plan.warnings.contains { $0.title.contains("xliveless") })
    }

    // MARK: Windows versions

    @Test func aWindowsVersionBecomesAPerProgramRegistryValue() throws {
        let plan = resolve([try fix("steam-268050")], programs: ["EvilWithin.exe", "Launcher.exe"])      // win7
        #expect(plan.registry.contains(RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\EvilWithin.exe"#, name: "Version", value: "win7")))
        #expect(plan.registry.contains(RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\Launcher.exe"#, name: "Version", value: "win7")))
        #expect(!plan.components.contains("win7"))
        #expect(plan.appliedFixIDs == ["steam-268050"])
        #expect(plan.notes.contains { $0.kind == .applied && $0.detail?.contains("Windows version win7") == true })
        #expect(RegistryFile.text(plan.registry).contains("[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\EvilWithin.exe]\n\"Version\"=\"win7\"\n"))
    }

    @Test func eachVersionVerbWritesWhatWinetricksPassesToWinecfg() {
        let expected = ["win11": "win11", "win10": "win10", "win81": "win81", "win8": "win8", "win7": "win7", "vista": "vista",
                        "win2k8r2": "win2008r2", "win2k8": "win2008", "win2k3": "win2003", "winxp": "winxp64", "win2k": "win2k",
                        "winme": "winme", "win98": "win98", "win95": "win95", "nt40": "nt40", "nt351": "nt351",
                        "win31": "win31", "win30": "win30", "win20": "win20"]
        #expect(CompatResolver.windowsVersions == expected)
        for (verb, value) in expected {
            let plan = resolve([GameFix(id: "x", components: [verb], source: "t")], programs: ["a.exe"])
            #expect(plan.registry.contains(RegistryValue(key: #"HKCU\Software\Wine\AppDefaults\a.exe"#, name: "Version", value: value)), "\(verb)")
            #expect(!plan.components.contains(verb))
        }
    }

    @Test func withoutAProgramNameTheVersionIsSkippedWithAWarning() throws {
        let plan = resolve([try fix("steam-268050")])
        #expect(!plan.registry.contains { $0.name == "Version" })
        #expect(plan.appliedFixIDs.isEmpty)
        #expect(plan.components == ["vcrun2022", "d3dcompiler_47"])
        let warning = try #require(plan.warnings.first { $0.title == "A known fix couldn't be applied" })
        #expect(warning.detail?.contains("Windows version") == true)
        // Names that can't be part of a key count as no name.
        #expect(resolve([try fix("steam-268050")], programs: ["Odd [x64].exe", "a\\b.exe"]).appliedFixIDs.isEmpty)
    }

    @Test func theLastVersionWinsAndNeverRepeats() {
        let plan = resolve([GameFix(id: "a", components: ["win7"], source: "t"), GameFix(id: "b", components: ["winxp", "win10"], source: "t")],
                           programs: ["g.exe"])
        let versions = plan.registry.filter { $0.name == "Version" }
        #expect(versions.map(\.value) == ["win10"])
    }

    @Test func versionsAreNotAppliedInCompatibleMode() throws {
        let plan = resolve([try fix("steam-268050")], programs: ["a.exe"], profile: .compatible)
        #expect(!plan.registry.contains { $0.name == "Version" })
        #expect(plan.appliedFixIDs.isEmpty)
    }

    // MARK: hidewineexports

    @Test func hidingWineExportsIsOneSpaceWideValueSetOnEveryLaunch() throws {
        let key = #"HKCU\Software\Wine"#
        let on = resolve([try fix("steam-230410")])                                  // Warframe
        #expect(on.registry.contains(RegistryValue(key: key, name: "HideWineExports", value: "Y")))
        #expect(!on.components.contains("hidewineexports=enable"))
        #expect(on.appliedFixIDs == ["steam-230410"])
        #expect(on.notes.contains { $0.kind == .applied && $0.title == "Hides Wine from the game" && $0.detail?.contains("every launch") == true })
        #expect(RegistryFile.text(on.registry).contains("[HKEY_CURRENT_USER\\Software\\Wine]\n\"HideWineExports\"=\"Y\"\n"))

        // The next game in the same space says it the other way round, so the setting doesn't stay behind.
        let off = resolve([])
        #expect(off.registry.contains(RegistryValue(key: key, name: "HideWineExports", value: "", delete: true)))
        #expect(RegistryFile.text(off.registry).contains("\"HideWineExports\"=-\n"))
        #expect(!off.notes.contains { $0.title == "Hides Wine from the game" })
        #expect(resolve([try fix("steam-230410")], profile: .compatible).registry.contains { $0.name == "HideWineExports" && $0.delete == true })
    }

    @Test func hidingWineExportsNeedsNoProgramName() throws {
        let plan = resolve([try fix("steam-3669060")])                               // hidewineexports=enable, dotnet48
        #expect(plan.components == ["vcrun2022", "d3dcompiler_47", "dotnet48"])
        #expect(plan.appliedFixIDs == ["steam-3669060"])
        #expect(!plan.warnings.contains { $0.title == "A known fix couldn't be applied" })
    }
}
