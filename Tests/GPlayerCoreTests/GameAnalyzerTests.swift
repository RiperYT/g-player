import Foundation
import Testing
@testable import GPlayerCore

// MARK: Helpers

/// A PE image with an import table and a delay-load table, built in memory: headers, one section at 0x1000
/// (file offset 0x200) that holds the descriptors and the DLL names. It can't run.
private struct ImportImage {
    var is64 = false
    var imports: [String] = []
    var delayImports: [String] = []
    /// The delay-load descriptors hold RVAs (the modern format) rather than addresses.
    var delayUsesRVA = true
    var imageBase = 0x40_0000

    static let lfanew = 0x40
    static let sectionRaw = 0x200
    static let sectionVA = 0x1000
    static let importTable = 0x1000                       // RVA of the import descriptors
    static let delayTable = 0x1100                        // RVA of the delay-load descriptors
    static let names = 0x1180                             // RVA of the first name

    var optionalSize: Int { is64 ? 240 : 224 }
    var optional: Int { Self.lfanew + 24 }
    /// Where the data directories start.
    var directories: Int { optional + (is64 ? 112 : 96) }

    var data: Data {
        var d = Data(count: 0x600)
        func put(_ o: Int, _ v: Int, bytes: Int) { for i in 0..<bytes { d[o + i] = UInt8((v >> (8 * i)) & 0xFF) } }
        put(0, 0x5A4D, bytes: 2); put(0x3C, Self.lfanew, bytes: 4)
        put(Self.lfanew, 0x4550, bytes: 4)
        let coff = Self.lfanew + 4
        put(coff, is64 ? 0x8664 : 0x014C, bytes: 2); put(coff + 2, 1, bytes: 2); put(coff + 16, optionalSize, bytes: 2)
        put(optional, is64 ? 0x20B : 0x10B, bytes: 2)
        if is64 { put(optional + 24, imageBase, bytes: 8) } else { put(optional + 28, imageBase, bytes: 4) }
        put(optional + 60, 0x200, bytes: 4)                                   // size of headers
        put(optional + (is64 ? 108 : 92), 16, bytes: 4)                       // number of data directories
        put(directories + 1 * 8, Self.importTable, bytes: 4); put(directories + 1 * 8 + 4, 40, bytes: 4)
        put(directories + 13 * 8, Self.delayTable, bytes: 4); put(directories + 13 * 8 + 4, 64, bytes: 4)
        let section = optional + optionalSize
        put(section + 8, 0x1000, bytes: 4); put(section + 12, Self.sectionVA, bytes: 4)
        put(section + 16, 0x400, bytes: 4); put(section + 20, Self.sectionRaw, bytes: 4)

        func raw(_ rva: Int) -> Int { rva - Self.sectionVA + Self.sectionRaw }
        var nameAt = Self.names
        func place(_ name: String) -> Int {
            let at = nameAt
            for (i, b) in Array(name.utf8).enumerated() { d[raw(at) + i] = b }
            nameAt += name.utf8.count + 1                                     // the byte after is already 0
            return at
        }
        for (i, name) in imports.enumerated() {
            let entry = raw(Self.importTable) + i * 20
            put(entry + 12, place(name), bytes: 4); put(entry + 16, 0x1300, bytes: 4)    // name, first thunk
        }
        for (i, name) in delayImports.enumerated() {
            let entry = raw(Self.delayTable) + i * 32
            put(entry, delayUsesRVA ? 1 : 0, bytes: 4)
            put(entry + 4, place(name) + (delayUsesRVA ? 0 : imageBase), bytes: 4)
        }
        return d
    }

    /// An entry of the import table, for tests that damage it: the name RVA is at +12.
    func importEntry(_ index: Int) -> Int { Self.sectionRaw + (Self.importTable - Self.sectionVA) + index * 20 }
}

private func write(_ data: Data, in tmp: TempFolder, as name: String = "a.exe") -> URL {
    tmp.file(name, contents: data)
}

private func realFixture(_ name: String) -> Data {
    try! Data(contentsOf: fixture(name))
}

/// The analysis of a program in `Fixtures`, with the Fixtures folder as the game folder.
private func analyzeFixture(_ name: String) -> GameAnalysis {
    let exe = fixture(name)
    return GameAnalyzer.analyze(executable: exe, gameFolder: exe.deletingLastPathComponent())
}

/// Small repeatable random numbers for the damage tests.
private struct Rng {
    var state: UInt64
    mutating func next() -> Int {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Int(truncatingIfNeeded: state >> 1)
    }
    mutating func below(_ n: Int) -> Int { next() % n }
}

// MARK: Detection rules

@Suite struct DetectionRulesTests {
    @Test func bundledRulesAllCompile() {
        let rules = DetectionRules.shared
        #expect(rules.rejected.isEmpty, "rules that failed to compile: \(rules.rejected)")
        #expect((rules.ruleCounts["Engine"] ?? 0) > 150)
        #expect((rules.ruleCounts["SDK"] ?? 0) > 100)
        #expect((rules.ruleCounts["AntiCheat"] ?? 0) > 15)
        #expect((rules.ruleCounts["Launcher"] ?? 0) > 5)
        #expect(rules.ruleCounts["Evidence"] != nil && rules.ruleCounts["Container"] != nil && rules.ruleCounts["Emulator"] != nil)
    }

    @Test func matchesAreCaseInsensitiveAndFindFilesInSubfolders() {
        let rules = DetectionRules.shared
        for path in ["UnityPlayer.dll", "unityplayer.DLL", "Sub/Folder/UnityPlayer.dll", "Game_Data/globalgamemanagers.assets"] {
            #expect(rules.matches(relativePaths: [path])["Engine"] == ["Unity"], "\(path)")
        }
    }

    @Test func rulesAreAnchoredTheWaySteamDBWritesThem() {
        let rules = DetectionRules.shared
        // `fna\.dll$` and friends: a dot is a dot, the name starts at a folder, the extension ends the path.
        for path in ["fna_dll", "notactuallyfna.dll", "fna.dllwhoops", "sub/dir/notactuallyfna.dll", "sub/dir/fna.dllwhoops"] {
            #expect(rules.matches(relativePaths: [path])["Engine"]?.contains("FNA") != true, "\(path)")
        }
        for path in ["fna.dll", "Sub/Folder/FNA.dll"] {
            #expect(rules.matches(relativePaths: [path])["Engine"]?.contains("FNA") == true, "\(path)")
        }
        // `^` rules only match at the top of the game folder.
        #expect(rules.matches(relativePaths: ["bootstrap.cfg"])["Engine"] == ["Amazon_Lumberyard"])
        #expect(rules.matches(relativePaths: ["Sub/bootstrap.cfg"])["Engine"] == nil)
        #expect(rules.matches(relativePaths: ["Unrelated/readme.txt", "UnityPlayerX.dll", "MyUnityPlayer.dll"]).isEmpty)
    }

    @Test func atomicGroupsAndPossessiveQuantifiersWork() {
        let rules = DetectionRules.shared
        #expect(rules.matches(relativePaths: ["RGSS104E.dll"])["Engine"] == ["RPGMaker"])          // (?>…)
        #expect(rules.matches(relativePaths: ["PhysX3_x64.dll"])["SDK"] == ["NVIDIA_PhysX"])       // (?>…)
        #expect(rules.matches(relativePaths: ["Steamworks.NET.dll"])["SDK"] == ["SteamworksNET"])
        #expect(rules.matches(relativePaths: ["libcurl.so.4.8.0"])["SDK"] == ["cURL"])              // {1,3}+
        #expect(rules.matches(relativePaths: ["a/mus_theme.ogg"]).isEmpty)                          // Evidence stays out
    }

    @Test func eachSectionReportsItsOwnMatches() {
        let found = DetectionRules.shared.matches(relativePaths: [
            "Game.exe", "UnityPlayer.dll", "EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe", "BEService_x64.exe",
            "Rockstar-Games-Launcher.exe", "dosbox.exe", "fmod.dll", "LICENSE.electron.txt",
        ])
        #expect(found["Engine"] == ["Unity"])
        #expect(found["AntiCheat"] == ["EasyAntiCheat", "BattlEye"])
        #expect(found["Launcher"] == ["Rockstar"])
        #expect(found["Emulator"] == ["DOSBOX"])
        #expect(found["SDK"] == ["FMOD"])
        #expect(found["Container"] == ["Electron"])
        #expect(found["Evidence"] == nil)
    }

    @Test func electronIsFoundByItsAppFolderToo() {
        let rules = DetectionRules.shared
        for path in ["resources/app.asar", "resources/app/package.json", "Game/resources/default_app.asar"] {
            #expect(rules.matches(relativePaths: [path])["Container"] == ["Electron"], "\(path)")
        }
        #expect(rules.matches(relativePaths: ["app/package.json", "resources/app.asar.unpacked/x.node"]).isEmpty)
    }

    // MARK: Second pass

    @Test func godotNeedsAProgramAndItsPackTogether() {
        let rules = DetectionRules.shared
        #expect(rules.matches(relativePaths: ["Game.exe", "Game.pck"])["Engine"] == ["Godot"])
        #expect(rules.matches(relativePaths: ["Folder/Game.exe", "Folder/Game.pck"])["Engine"] == ["Godot"])
        #expect(rules.matches(relativePaths: ["Game.exe", "data.pck"])["Engine"] == ["Godot"])      // the only pack
        // SteamDB's own negative cases.
        #expect(rules.matches(relativePaths: ["Game.exe", "Sound/Game.pck"]).isEmpty)
        #expect(rules.matches(relativePaths: ["Folder/Game", "Sound/Game.pck"]).isEmpty)
        #expect(rules.matches(relativePaths: ["Folder/Game.exe", "Game.pck"]).isEmpty)
    }

    @Test func gameMakerNeedsTwoOfThreeSigns() {
        let rules = DetectionRules.shared
        #expect(rules.matches(relativePaths: ["Game.exe", "data.win", "options.ini"])["Engine"] == ["GameMaker"])
        #expect(rules.matches(relativePaths: ["Game.exe", "data.win", "snd_music.ogg"])["Engine"] == ["GameMaker"])
        #expect(rules.matches(relativePaths: ["Game.exe", "data.win"]).isEmpty)
        #expect(rules.matches(relativePaths: ["Game.exe", "options.ini", "unrelated.txt"]).isEmpty)
    }

    @Test func otherEnginesComeFromEvidence() {
        let rules = DetectionRules.shared
        #expect(rules.matches(relativePaths: ["Game.exe", "hlboot.dat", "Sub/x.hdll"])["Engine"] == ["Heaps"])
        #expect(rules.matches(relativePaths: ["Maps/level.u"])["Engine"] == ["Unreal"])
        #expect(rules.matches(relativePaths: ["dosbox.exe", "game/vswap.wl6"])["Engine"] == ["idTech"])
    }

    // MARK: INI syntax

    @Test func iniSyntaxFollowsPHPRawMode() {
        let rules = DetectionRules(iniText: """
            ; a comment
            [Engine]
            Alpha = \\.alpha$ ; trailing comment
            Alpha = \\.alpha2$
            Beta[] = (?:^|/)beta\\.dll$
            Beta[] = "quoted\\.txt$"

            [SDK]
              Gamma = ^gamma/
            Empty =
            """)
        #expect(rules.ruleCounts == ["Engine": 3, "SDK": 1])                  // the second `Alpha` replaced the first
        #expect(rules.rejected.isEmpty)
        #expect(rules.matches(relativePaths: ["x.alpha"]).isEmpty)
        #expect(rules.matches(relativePaths: ["x.alpha2"])["Engine"] == ["Alpha"])
        #expect(rules.matches(relativePaths: ["a/Beta.dll"])["Engine"] == ["Beta"])
        #expect(rules.matches(relativePaths: ["quoted.txt"])["Engine"] == ["Beta"])
        #expect(rules.matches(relativePaths: ["gamma/a", "other/gamma/b"])["SDK"] == ["Gamma"])
        #expect(rules.matches(relativePaths: ["a.beta"]).isEmpty)
    }

    @Test func brokenRulesAreSkippedNotFatal() {
        let rules = DetectionRules(iniText: """
            [Engine]
            Broken = (unclosed
            Capturing = (a)b
            Fine = fine\\.txt$
            """)
        #expect(rules.rejected == ["Engine.Broken", "Engine.Capturing"])
        #expect(rules.matches(relativePaths: ["fine.txt"])["Engine"] == ["Fine"])
        #expect(DetectionRules(iniText: "").matches(relativePaths: ["UnityPlayer.dll"]).isEmpty)
    }

    @Test func manyFilesOfOneKindStillReportTheRuleOnce() {
        let paths = (0..<500).map { "Audio/Banks/sound\($0).wem" } + ["Audio/Init.bnk"]
        #expect(DetectionRules.shared.matches(relativePaths: paths) == ["SDK": ["Wwise"]])
    }

    @Test func emptyAndOddPathsAreHarmless() {
        let rules = DetectionRules.shared
        #expect(rules.matches(relativePaths: []).isEmpty)
        #expect(rules.matches(relativePaths: ["", "/", "//", ".", "..", "a.", ".dll", "日本語/ファイル.txt", String(repeating: "a/", count: 500)]).isEmpty)
    }
}

// MARK: PE imports

@Suite struct PEImportsTests {
    @Test func readsTheImportsOfRealPrograms() {
        let d3d11 = PEImports.importedDLLs(ofExecutableAt: fixture("D3D11Fixture.exe"))             // PE32+
        #expect(d3d11?.contains("d3d11.dll") == true)
        #expect(d3d11?.contains("kernel32.dll") == true)
        #expect(d3d11?.contains("d3d9.dll") == false)
        let d3d9 = PEImports.importedDLLs(ofExecutableAt: fixture("D3D9Fixture.exe"))               // PE32
        #expect(d3d9?.contains("d3d9.dll") == true)
        #expect(d3d9?.contains("d3d11.dll") == false)
        #expect(d3d9?.allSatisfy { $0 == $0.lowercased() } == true)
        #expect(Set(d3d9 ?? []).count == d3d9?.count)
        let plain = PEImports.importedDLLs(ofExecutableAt: fixture("X86Fixture.exe"))
        #expect(plain?.contains("kernel32.dll") == true)
        #expect(plain?.contains { $0.hasPrefix("d3d") } == false)
    }

    @Test func nonPEFilesAndMissingFilesAreNil() {
        let tmp = TempFolder()
        #expect(PEImports.importedDLLs(ofExecutableAt: fixture("Steam.lnk")) == nil)
        #expect(PEImports.importedDLLs(ofExecutableAt: URL(fileURLWithPath: "/nonexistent.exe")) == nil)
        #expect(PEImports.importedDLLs(ofExecutableAt: tmp.url) == nil)                              // a folder
        #expect(PEImports.importedDLLs(ofExecutableAt: write(Data(), in: tmp)) == nil)
        #expect(PEImports.importedDLLs(ofExecutableAt: write(Data("MZ".utf8), in: tmp)) == nil)
    }

    @Test func readsImportsAndDelayImportsOfBothFormats() {
        let tmp = TempFolder()
        for is64 in [false, true] {
            let image = ImportImage(is64: is64, imports: ["KERNEL32.dll", "D3D9.DLL"], delayImports: ["d3d11.dll", "Kernel32.dll", "vulkan-1.dll"])
            #expect(PEImports.importedDLLs(ofExecutableAt: write(image.data, in: tmp)) ==
                    ["kernel32.dll", "d3d9.dll", "d3d11.dll", "vulkan-1.dll"], "64-bit: \(is64)")
        }
    }

    @Test func oldDelayLoadTablesHoldAddressesNotRVAs() {
        let tmp = TempFolder()
        for is64 in [false, true] {
            let image = ImportImage(is64: is64, imports: ["a.dll"], delayImports: ["d3d12.dll"], delayUsesRVA: false)
            #expect(PEImports.importedDLLs(ofExecutableAt: write(image.data, in: tmp)) == ["a.dll", "d3d12.dll"])
        }
        // An address below the image base can't be one.
        var broken = ImportImage(imports: [], delayImports: ["d3d12.dll"], delayUsesRVA: false)
        broken.imageBase = 0x40_0000
        var data = broken.data
        let delayName = ImportImage.sectionRaw + (ImportImage.delayTable - ImportImage.sectionVA) + 4
        data[delayName + 2] = 0                                                                       // 0x0040_1180 → 0x0000_1180
        #expect(PEImports.importedDLLs(ofExecutableAt: write(data, in: tmp)) == nil)
    }

    @Test func aValidImageWithoutImportsIsEmptyNotNil() {
        let tmp = TempFolder()
        #expect(PEImports.importedDLLs(ofExecutableAt: write(ImportImage().data, in: tmp)) == [])
    }

    @Test func damagedTablesAreNil() throws {
        let tmp = TempFolder()
        let image = ImportImage(imports: ["kernel32.dll", "d3d9.dll"], delayImports: ["d3d11.dll"])
        let base = image.data
        func check(_ why: String, _ edit: (inout Data) -> Void) {
            var d = base
            edit(&d)
            #expect(PEImports.importedDLLs(ofExecutableAt: write(d, in: tmp)) == nil, "\(why)")
        }
        func put32(_ d: inout Data, _ o: Int, _ v: Int) { for i in 0..<4 { d[o + i] = UInt8((v >> (8 * i)) & 0xFF) } }

        check("import table outside every section") { put32(&$0, image.directories + 8, 0x9000) }
        check("import table past the end of the file") { put32(&$0, image.directories + 8, 0x1000 + 0x3F8) }
        check("name outside every section") { put32(&$0, image.importEntry(0) + 12, 0x7000_0000) }
        check("name RVA of 0xFFFFFFFF") { put32(&$0, image.importEntry(1) + 12, 0xFFFF_FFFF) }
        check("name that never ends") { d in for i in 0..<300 { d[ImportImage.sectionRaw + 0x180 + i] = 0x41 }; d[ImportImage.sectionRaw + 0x180 + 400] = 0 }
        check("name with control characters") { $0[ImportImage.sectionRaw + 0x180] = 0x07 }
        check("name with non-ASCII bytes") { $0[ImportImage.sectionRaw + 0x180] = 0xE9 }
        check("empty name") { $0[ImportImage.sectionRaw + 0x180] = 0 }
        check("delay-load table outside every section") { put32(&$0, image.directories + 13 * 8, 0x8000) }
        check("table with no end marker") { d in
            // Valid, non-zero descriptors up to the end of the section's data (0x400 bytes), all naming "x.dll".
            for (i, b) in Array("x.dll".utf8).enumerated() { d[0x1C0 + i] = b }                       // in the headers, which an RVA below 0x200 reaches
            for i in 0..<51 { put32(&d, ImportImage.sectionRaw + i * 20 + 12, 0x1C0); put32(&d, ImportImage.sectionRaw + i * 20 + 16, 1) }
        }
        check("section that claims more than the file has") { d in
            let section = image.optional + image.optionalSize
            put32(&d, section + 16, 0x10_0000)
            d.removeSubrange(0x300..<d.count)
        }
        check("more sections than Windows allows") { $0[ImportImage.lfanew + 6] = 200 }
        check("section table beyond the file") { $0.removeSubrange(0x140..<$0.count) }
        check("optional header too small for directories") { $0[ImportImage.lfanew + 20] = 0x40; $0[ImportImage.lfanew + 21] = 0 }
        check("unknown optional header magic") { $0[image.optional] = 0x07 }
    }

    /// An image whose import table has `count` descriptors that all name "x.dll", then `terminator` zero entries.
    private func imageWithDescriptors(_ count: Int, terminator: Bool) -> Data {
        let base = ImportImage().data
        var data = Data(count: 0x200 + (count + 1) * 20 + 0x200)
        data.replaceSubrange(0..<0x200, with: base.prefix(0x200))
        func put32(_ o: Int, _ v: Int) { for i in 0..<4 { data[o + i] = UInt8((v >> (8 * i)) & 0xFF) } }
        let section = ImportImage().optional + ImportImage().optionalSize
        put32(section + 8, data.count - 0x200); put32(section + 16, data.count - 0x200)
        for (i, b) in Array("x.dll".utf8).enumerated() { data[0x1C0 + i] = b }
        for i in 0..<(count + (terminator ? 0 : 1)) {
            put32(0x200 + i * 20 + 12, 0x1C0); put32(0x200 + i * 20 + 16, 1)
        }
        return data
    }

    @Test func aLongTableIsReadUpToTheCap() {
        let tmp = TempFolder()
        #expect(PEImports.importedDLLs(ofExecutableAt: write(imageWithDescriptors(100, terminator: true), in: tmp)) == ["x.dll"])
        #expect(PEImports.importedDLLs(ofExecutableAt: write(imageWithDescriptors(PEImports.maxDescriptors - 1, terminator: true), in: tmp)) == ["x.dll"])
    }

    @Test func tooManyDescriptorsAreRefused() {
        let tmp = TempFolder()
        #expect(PEImports.importedDLLs(ofExecutableAt: write(imageWithDescriptors(PEImports.maxDescriptors, terminator: false), in: tmp)) == nil)
        #expect(PEImports.importedDLLs(ofExecutableAt: write(imageWithDescriptors(PEImports.maxDescriptors + 50, terminator: true), in: tmp)) == nil)
    }

    // MARK: Damage

    @Test func everyTruncationOfARealProgramIsHandled() throws {
        let tmp = TempFolder()
        let whole = realFixture("D3D9Fixture.exe")
        let url = tmp.url.appendingPathComponent("cut.exe")
        var lengths = Array(0..<min(whole.count, 2048))
        lengths += stride(from: 2048, to: whole.count, by: 61)
        lengths.append(whole.count)
        for length in lengths {
            try whole.prefix(length).write(to: url)
            let names = PEImports.importedDLLs(ofExecutableAt: url)
            if length == whole.count { #expect(names?.contains("d3d9.dll") == true) }
            for name in names ?? [] { #expect(!name.isEmpty && name.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }) }
        }
    }

    @Test func randomBytesAndBitFlipsNeverCrash() throws {
        let tmp = TempFolder()
        let url = tmp.url.appendingPathComponent("fuzz.exe")
        var rng = Rng(state: 0x9E37_79B9_7F4A_7C15)
        // Pure noise, with and without a believable start.
        for round in 0..<300 {
            var d = Data((0..<(rng.below(3000) + 1)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            if round % 2 == 0, d.count > 0x60 { d[0] = 0x4D; d[1] = 0x5A; d[0x3C] = 0x40; d[0x3D] = 0; d[0x3E] = 0; d[0x3F] = 0
                d[0x40] = 0x50; d[0x41] = 0x45; d[0x42] = 0; d[0x43] = 0 }
            try d.write(to: url)
            _ = PEImports.importedDLLs(ofExecutableAt: url)
        }
        // Real programs and hand-built ones with a few bytes changed anywhere in the headers or the tables.
        let bases = [realFixture("D3D11Fixture.exe"), realFixture("D3D9Fixture.exe"), ImportImage(imports: ["a.dll", "b.dll"], delayImports: ["c.dll"]).data,
                     ImportImage(is64: true, imports: ["a.dll"], delayImports: ["c.dll"], delayUsesRVA: false).data]
        for round in 0..<800 {
            var d = bases[round % bases.count]
            for _ in 0..<(rng.below(8) + 1) {
                let at = rng.below(round % 3 == 0 ? d.count : min(d.count, 0x600))
                d[at] = round % 5 == 0 ? 0xFF : UInt8(truncatingIfNeeded: rng.next())
            }
            try d.write(to: url)
            for name in PEImports.importedDLLs(ofExecutableAt: url) ?? [] { #expect(!name.isEmpty) }
        }
    }
}

// MARK: Game analysis

@Suite struct GameAnalyzerTests {
    /// A game folder `name` in a fresh temp folder, and the .exe in it.
    private func analyze(_ files: [String], exe: String, gameFolder: String? = nil, in tmp: TempFolder = TempFolder()) -> GameAnalysis {
        for f in files { tmp.file(f) }
        return GameAnalyzer.analyze(executable: tmp.url.appendingPathComponent(exe), gameFolder: gameFolder.map { tmp.url.appendingPathComponent($0) })
    }

    // MARK: Engines

    @Test func unityGame() {
        let a = analyze(["Hollow/Hollow.exe", "Hollow/Hollow_Data/globalgamemanagers", "Hollow/UnityPlayer.dll"], exe: "Hollow/Hollow.exe")
        #expect(a.engineName == "Unity")
        #expect(a.engine == .unity)
        #expect(a.antiCheat.isEmpty && a.launchers.isEmpty)
    }

    @Test func unrealGameFromItsShippingProgramFindsEngineFolderAbove() {
        let tmp = TempFolder()
        tmp.file("Root/Engine/Binaries/ThirdParty/DbgHelp/dbghelp.dll")
        tmp.file("Root/Engine/Content/Slate/Cursor.png")
        tmp.file("Root/Hunt/Content/Paks/Hunt-WindowsNoEditor.pak")
        tmp.file("Root/Hunt/Binaries/Win64/Hunt-Win64-Shipping.exe", contents: realFixture("D3D11Fixture.exe"))
        let a = GameAnalyzer.analyze(executable: tmp.url.appendingPathComponent("Root/Hunt/Binaries/Win64/Hunt-Win64-Shipping.exe"))
        #expect(a.engineName == "Unreal")
        #expect(a.engine == .unreal)
        #expect(a.graphics == [.d3d11])
        #expect(a.architecture == .x64)
    }

    @Test func unrealGameFromItsLauncherReadsTheShippingProgram() {
        let tmp = TempFolder()
        tmp.file("Root/Engine/Binaries/ThirdParty/DbgHelp/dbghelp.dll")
        tmp.file("Root/Hunt.exe", contents: realFixture("X86Fixture.exe"))                          // a small launcher
        tmp.file("Root/Hunt/Binaries/Win64/Hunt-Win64-Shipping.exe", contents: realFixture("D3D11Fixture.exe"))
        tmp.file("Root/Engine/Binaries/Win64/CrashReportClient-Win64-Shipping.exe", contents: realFixture("D3D9Fixture.exe"))
        let a = GameAnalyzer.analyze(executable: tmp.url.appendingPathComponent("Root/Hunt.exe"))
        #expect(a.engine == .unreal)
        #expect(a.graphics == [.d3d11])                                                              // not the engine's crash reporter
        #expect(a.architecture == .x86)                                                              // of the program that was asked about
    }

    @Test func rpgMakerMZ() {
        let a = analyze(["Game/Game.exe", "Game/js/rmmz_core.js", "Game/package.json", "Game/nw.dll"], exe: "Game/Game.exe")
        #expect(a.engineName == "RPGMaker")
        #expect(a.engine == .rpgMaker)                                                               // not NW.js, which it runs in
    }

    @Test func rpgMakerOlderVariants() {
        #expect(analyze(["G/Game.exe", "G/RGSS301.dll", "G/Game.rgss3a"], exe: "G/Game.exe").engine == .rpgMaker)
        #expect(analyze(["G/Game.exe", "G/RPG_RT.ini"], exe: "G/Game.exe").engine == .rpgMaker)
        #expect(analyze(["G/Game.exe", "G/www/js/rpg_core.js"], exe: "G/Game.exe").engine == .rpgMaker)
    }

    @Test func electronByLicenseFileOrByAppFolder() {
        let byLicense = analyze(["G/Game.exe", "G/LICENSE.electron.txt", "G/resources/app.asar"], exe: "G/Game.exe")
        #expect(byLicense.engineName == "Electron")
        #expect(byLicense.engine == .electron)
        #expect(analyze(["G/Game.exe", "G/resources/app.asar"], exe: "G/Game.exe").engine == .electron)
        #expect(analyze(["G/Game.exe", "G/resources/app/package.json", "G/resources/app/main.js"], exe: "G/Game.exe").engine == .electron)
    }

    @Test func nwjsGameWithoutAKnownEngine() {
        let a = analyze(["G/Game.exe", "G/nw.dll", "G/nw.pak", "G/package.nw"], exe: "G/Game.exe")
        #expect(a.engine == .nwjs)
    }

    @Test func browserWinsOverAnUnknownEngineOnTopOfIt() {
        // SteamDB sees "Construct" in the app folder; what matters here is that it starts Chromium.
        let a = analyze(["G/Game.exe", "G/resources/app.asar", "G/resources/app/c3runtime.js"], exe: "G/Game.exe")
        #expect(a.engine == .electron)
        #expect(a.engineName == "Electron")
    }

    @Test func godotGameFromItsPack() {
        let a = analyze(["G/Game.exe", "G/Game.pck"], exe: "G/Game.exe")
        #expect(a.engineName == "Godot")
        #expect(a.engine == .godot)
        #expect(analyze(["G/Game.exe", "G/Sound/Game.pck"], exe: "G/Game.exe").engine == nil)
    }

    @Test func gameMakerGame() {
        #expect(analyze(["G/Game.exe", "G/data.win", "G/options.ini"], exe: "G/Game.exe").engine == .gameMaker)
    }

    @Test func renPySourceAndOtherKnownEngines() {
        #expect(analyze(["G/Game.exe", "G/renpy/common/00start.rpy"], exe: "G/Game.exe").engine == .renPy)
        #expect(analyze(["G/hl2.exe", "G/bin/vphysics.dll"], exe: "G/hl2.exe").engine == .source)
        // The program sits in game/bin/win64, nothing marks that as a nested folder: the caller names the game folder.
        #expect(analyze(["G/game/bin/win64/cs2.exe", "G/game/csgo/gameinfo.gi"], exe: "G/game/bin/win64/cs2.exe", gameFolder: "G").engine == .source2)
    }

    @Test func otherEnginesKeepTheirNameFromTheRules() {
        let air = analyze(["G/Game.exe", "G/Adobe AIR/Versions/1.0/Adobe AIR.dll"], exe: "G/Game.exe")
        #expect(air.engine == .other)
        #expect(air.engineName == "Adobe AIR")                                                       // from Adobe_AIR
        let heaps = analyze(["G/Game.exe", "G/hlboot.dat", "G/game.hdll"], exe: "G/Game.exe")
        #expect(heaps.engine == .other && heaps.engineName == "Heaps")                               // deduced
        let none = analyze(["G/Game.exe", "G/readme.txt"], exe: "G/Game.exe")
        #expect(none.engine == nil && none.engineName == nil)
    }

    @Test func aKnownEngineWinsOverMatchesSteamDBMakesOnTheSideOfIt() {
        // A Unity game with Lua scripts and a stray evidence-only `.u` file.
        let a = analyze(["G/Game.exe", "G/UnityPlayer.dll", "G/Scripts/ai.lua", "G/Data/thing.u"], exe: "G/Game.exe")
        #expect(a.engine == .unity)
    }

    // MARK: Anti-cheat and launchers

    @Test func antiCheatAndLaunchers() {
        let a = analyze(["G/Game.exe", "G/EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe", "G/BEService_x64.exe",
                         "G/Rockstar-Games-Launcher.exe", "G/EAappInstaller.exe"], exe: "G/Game.exe")
        #expect(a.antiCheat == ["BattlEye", "EasyAntiCheat"])
        #expect(a.launchers == ["EA App", "Rockstar"])
    }

    // MARK: Graphics

    @Test func graphicsFromTheProgramsOwnImports() {
        let d3d11 = analyzeFixture("D3D11Fixture.exe")
        #expect(d3d11.graphics == [.d3d11])
        #expect(d3d11.architecture == .x64)
        #expect(d3d11.newestDirect3D == .d3d11)
        let d3d9 = analyzeFixture("D3D9Fixture.exe")
        #expect(d3d9.graphics == [.d3d9])
        #expect(d3d9.architecture == .x86)
        #expect(analyzeFixture("X86Fixture.exe").graphics.isEmpty)
    }

    @Test func graphicsFromTheUnityPlayerNextToTheProgram() {
        let tmp = TempFolder()
        tmp.file("Hollow/Hollow.exe", contents: realFixture("X86Fixture.exe"))                      // starts UnityPlayer.dll, imports no Direct3D
        tmp.file("Hollow/Hollow_Data/globalgamemanagers")
        tmp.file("Hollow/UnityPlayer.dll", contents: realFixture("D3D9Fixture.exe"))
        tmp.file("Hollow/Other/UnityPlayer.dll", contents: realFixture("D3D11Fixture.exe"))           // a stray copy elsewhere
        let a = GameAnalyzer.analyze(executable: tmp.url.appendingPathComponent("Hollow/Hollow.exe"))
        #expect(a.graphics == [.d3d9])
        #expect(a.engine == .unity)
        #expect(a.architecture == .x86)
    }

    @Test func graphicsAreTheUnionOfProgramAndEngineRuntime() {
        let tmp = TempFolder()
        tmp.file("G/Game.exe", contents: realFixture("D3D9Fixture.exe"))
        tmp.file("G/UnityPlayer.dll", contents: realFixture("D3D11Fixture.exe"))
        let a = GameAnalyzer.analyze(executable: tmp.url.appendingPathComponent("G/Game.exe"))
        #expect(a.graphics == [.d3d9, .d3d11])                                                       // in API order
    }

    @Test func theDirectX12RuntimeNextToTheGameMeansDX12() {
        for path in ["G/D3D12/D3D12Core.dll", "G/d3d12core.dll", "G/bin/x64/D3D12Core.dll"] {
            let a = analyze(["G/Game.exe", path], exe: "G/Game.exe")
            #expect(a.graphics == [.d3d12], "\(path)")
            #expect(a.newestDirect3D == .d3d12)
        }
        #expect(analyze(["G/Game.exe", "G/dxgi.dll", "G/d3d12_notcore.dll"], exe: "G/Game.exe").graphics.isEmpty)
    }

    @Test func dllNamesMapToGraphicsAPIs() {
        let table: [(String, GraphicsAPI?)] = [
            ("d3d8.dll", .d3d8), ("d3d9.dll", .d3d9), ("d3d10.dll", .d3d10), ("d3d10_1.dll", .d3d10), ("d3d10core.dll", .d3d10),
            ("d3d11.dll", .d3d11), ("d3d12.dll", .d3d12), ("opengl32.dll", .opengl), ("vulkan-1.dll", .vulkan),
            ("dxgi.dll", nil), ("d3dcompiler_47.dll", nil), ("d3dx9_43.dll", nil), ("kernel32.dll", nil), ("d3d10", nil), ("d3d1.dll", nil),
        ]
        for (dll, api) in table { #expect(GameAnalyzer.graphicsAPI(forDLL: dll) == api, "\(dll)") }
    }

    // MARK: Program facts

    @Test func architectureOfTheRealFixtures() {
        #expect(analyzeFixture("IconFixture.exe").architecture == .x64)
        #expect(analyzeFixture("X86Fixture.exe").architecture == .x86)
        #expect(analyzeFixture("IconFixture.exe").isDotNet == false)
    }

    @Test func aProgramThatIsNotPEOrNotThereYieldsAnEmptyAnalysisWithoutFailing() {
        #expect(analyzeFixture("Steam.lnk").architecture == nil)
        #expect(GameAnalyzer.analyze(executable: URL(fileURLWithPath: "/nonexistent/game/Game.exe"))
                == GameAnalysis(programPath: "/nonexistent/game/Game.exe", version: GameAnalysis.currentVersion))
        #expect(GameAnalyzer.analyze(executable: fixture("X86Fixture.exe"), gameFolder: URL(fileURLWithPath: "/nonexistent")).architecture == .x86)
    }

    // MARK: Which folder

    @Test func gameFolderGivenByTheCallerIsUsedAsIs() {
        let tmp = TempFolder()
        tmp.file("Lib/Game/bin/Game.exe")
        tmp.file("Lib/Game/UnityPlayer.dll")
        #expect(GameAnalyzer.analyze(executable: tmp.url.appendingPathComponent("Lib/Game/bin/Game.exe")).engine == nil)
        #expect(GameAnalyzer.analyze(executable: tmp.url.appendingPathComponent("Lib/Game/bin/Game.exe"),
                                     gameFolder: tmp.url.appendingPathComponent("Lib/Game")).engine == .unity)
    }

    @Test func gameRootWalksUpOnlyToAnEngineFolderOrUnityData() {
        let tmp = TempFolder()
        tmp.file("U/Game_Data/globalgamemanagers")
        tmp.file("U/bin/x64/Game.exe")                                                                // two levels below the Unity data
        tmp.file("E/Engine/Binaries/ThirdParty/a.dll")
        tmp.file("E/Proj/Binaries/Win64/Proj-Win64-Shipping.exe")                                     // three levels below Engine
        tmp.file("N/Plain/bin/Game.exe")
        tmp.file("One/Other_Data/globalgamemanagers")                                                 // a Unity game next to a library's other games
        tmp.file("One/Neighbour/Neighbour.exe")
        tmp.file("N/Stuff_Data/readme.txt")                                                           // a "_Data" folder that isn't Unity's
        tmp.file("Far/Engine/Content/a.uasset")
        tmp.file("Far/a/b/c/d/Game.exe")                                                              // too far below it
        func root(_ exe: String) -> String { GameAnalyzer.gameRoot(forExecutable: tmp.url.appendingPathComponent(exe)).standardizedFileURL.path }
        let base = tmp.url.standardizedFileURL.path
        #expect(root("U/bin/x64/Game.exe") == base + "/U")
        #expect(root("E/Proj/Binaries/Win64/Proj-Win64-Shipping.exe") == base + "/E")
        #expect(root("N/Plain/bin/Game.exe") == base + "/N/Plain/bin")
        #expect(root("One/Neighbour/Neighbour.exe") == base + "/One/Neighbour")                        // one level up is not enough
        #expect(root("Far/a/b/c/d/Game.exe") == base + "/Far/a/b/c/d")
    }

    // MARK: Listing

    @Test func listingSkipsJunkAndHiddenFiles() {
        let tmp = TempFolder()
        for f in ["Game.exe", "data/a.bin", ".DS_Store", ".git/config", "__MACOSX/x", "node_modules/pkg/index.js",
                  "steamapps/common/Other/Other.exe", "Thumbs.db", "sub/.hidden", "sub/real.txt"] { tmp.file(f) }
        let files = GameAnalyzer.listFiles(in: tmp.url)
        #expect(Set(files) == ["Game.exe", "data/a.bin", "sub/real.txt"])
    }

    @Test func listingStopsAtTheCapWithTheShallowFilesFirst() {
        let tmp = TempFolder()
        for i in 0..<5 { tmp.file("top\(i).txt") }
        for i in 0..<20 { tmp.file("a/b/c/deep\(i).txt") }
        let files = GameAnalyzer.listFiles(in: tmp.url, maxFiles: 8)
        #expect(files.count == 8)
        #expect((0..<5).allSatisfy { files.contains("top\($0).txt") })
    }

    @Test func listingStopsAtTheDepthLimit() {
        let tmp = TempFolder()
        tmp.file("one.txt"); tmp.file("a/two.txt"); tmp.file("a/b/three.txt"); tmp.file("a/b/c/four.txt")
        #expect(Set(GameAnalyzer.listFiles(in: tmp.url, maxDepth: 3)) == ["one.txt", "a/two.txt", "a/b/three.txt"])
        #expect(GameAnalyzer.listFiles(in: URL(fileURLWithPath: "/nonexistent")).isEmpty)
    }

    @Test func listingDoesNotFollowSymbolicLinks() throws {
        let tmp = TempFolder()
        tmp.file("real/a.txt")
        try FileManager.default.createSymbolicLink(at: tmp.url.appendingPathComponent("link"), withDestinationURL: tmp.url.appendingPathComponent("real"))
        #expect(GameAnalyzer.listFiles(in: tmp.url) == ["real/a.txt"])
    }

    // MARK: Safety and speed

    @Test func analyzingFromManyThreadsAtOnceAgrees() {
        let tmp = TempFolder()
        tmp.file("G/Game.exe", contents: realFixture("D3D11Fixture.exe"))
        tmp.file("G/UnityPlayer.dll", contents: realFixture("D3D9Fixture.exe"))
        tmp.file("G/EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe")
        let exe = tmp.url.appendingPathComponent("G/Game.exe")
        let expected = GameAnalyzer.analyze(executable: exe)
        var results = [GameAnalysis](repeating: GameAnalysis(), count: 32)
        results.withUnsafeMutableBufferPointer { out in
            let slots = out
            DispatchQueue.concurrentPerform(iterations: 32) { slots[$0] = GameAnalyzer.analyze(executable: exe) }
        }
        #expect(results.allSatisfy { $0 == expected })
        #expect(expected.engine == .unity && expected.antiCheat == ["EasyAntiCheat"] && expected.graphics == [.d3d9, .d3d11])
    }

    @Test func aBigGameFolderIsAnalyzedQuickly() {
        let tmp = TempFolder()
        tmp.file("G/Game.exe")
        for i in 0..<3000 { tmp.file("G/Content/Folder\(i % 30)/asset\(i).\(["png", "ogg", "dll", "uasset", "json"][i % 5])", bytes: 1) }
        let start = Date()
        let a = GameAnalyzer.analyze(executable: tmp.url.appendingPathComponent("G/Game.exe"))
        #expect(Date().timeIntervalSince(start) < 3)                                                  // typically ~0.1 s; the bound is loose on purpose
        #expect(a.engine == .unreal)                                                                  // from the .uasset files
    }
}
