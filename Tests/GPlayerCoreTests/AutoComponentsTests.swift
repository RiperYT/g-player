import Foundation
import Testing
@testable import GPlayerCore

/// Components a game's files ask for go in before it first starts; the common set is the answer to "it didn't start".
@Suite struct AutoComponentsTests {
    @Test func importsBecomeComponentsUnlessTheGameShipsTheDLL() {
        let imports: Set<String> = ["KERNEL32.dll", "d3dx9_43.dll", "XINPUT1_3.dll", "openal32.dll", "msvcr100.dll",
                                    "mscoree.dll", "MSVCP140.dll"]
        let found = GameAnalyzer.components(forImports: imports, shipped: ["openal32.dll", "game.exe"])
        // openal32 comes with the game, .NET is left to Wine Mono; vcrun2022 is in every space anyway but harmless.
        #expect(found == ["d3dx9", "vcrun2010", "vcrun2022", "xinput"])
    }

    @Test func theResolverInstallsThemWithANote() {
        let analysis = GameAnalysis(neededComponents: ["d3dx9", "xinput", "vcrun2022", "dotnet48"])
        let plan = CompatResolver.resolve(.init(engine: EngineCatalog.wineStaging, analysis: analysis, fixes: [],
                                                options: .default))
        #expect(plan.components == CompatResolver.baseComponents + ["d3dx9", "xinput"])
        #expect(plan.notes.contains { $0.kind == .applied && $0.title.hasPrefix("Adds DirectX 9 helpers") })
    }

    @Test func aCrashWithoutACauseOffersTheCommonSetThenCompatible() {
        let crash = "wine: Unhandled page fault on read access to 0000010C at address 00490698"
        let first = LogDiagnosis.diagnose(log: crash, exitStatus: 1, seconds: 30, profile: .recommended, installed: ["d3dx9"])
        #expect(first.first?.remedy == .installComponents(["d3dx11_43", "xact", "xinput", "openal", "corefonts"]))
        let all = Set(RuntimeCatalog.commonSet)
        let second = LogDiagnosis.diagnose(log: crash, exitStatus: 1, seconds: 30, profile: .recommended, installed: all)
        #expect(second.first?.remedy == .useProfile(.compatible))
        let last = LogDiagnosis.closedRightAway(seconds: 3, profile: .compatible, installed: all)
        #expect(last.remedy == .none && last.kind == .closedRightAway)
    }

    @Test func theCommonSetIsInstallable() {
        #expect(RuntimeCatalog.commonSet.allSatisfy { RuntimeCatalog.isInstallable($0) && RuntimeCatalog.component($0) != nil })
    }
}
