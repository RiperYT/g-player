import Foundation
import Testing
@testable import GPlayerCore

/// A minimal PE image built in memory: DOS header, "PE\0\0", COFF header, an optional header with 16 data
/// directories, one section. Just enough for the header readers; it can't run.
private struct PEImage {
    var machine = 0x014C
    var pe32Plus = false
    /// The .NET (COR20) header flags. nil leaves the CLR directory empty.
    var corFlags: Int?

    var optionalSize: Int { pe32Plus ? 240 : 224 }
    static let lfanew = 0x40
    static let corRaw = 0x200                      // where the section's data (and the COR20 header) starts

    var data: Data {
        var d = Data(count: 0x400)
        func put16(_ o: Int, _ v: Int) { d[o] = UInt8(v & 0xFF); d[o + 1] = UInt8((v >> 8) & 0xFF) }
        func put32(_ o: Int, _ v: Int) { put16(o, v & 0xFFFF); put16(o + 2, (v >> 16) & 0xFFFF) }
        put16(0, 0x5A4D); put32(0x3C, Self.lfanew)
        put32(Self.lfanew, 0x4550)
        let coff = Self.lfanew + 4
        put16(coff, machine); put16(coff + 2, 1); put16(coff + 16, optionalSize); put16(coff + 18, 0x0102)
        let optional = Self.lfanew + 24
        put16(optional, pe32Plus ? 0x20B : 0x10B)
        put32(optional + (pe32Plus ? 108 : 92), 16)
        let directories = optional + (pe32Plus ? 112 : 96)
        let section = optional + optionalSize
        put32(section + 8, 0x1000); put32(section + 12, 0x1000)         // virtual size, virtual address
        put32(section + 16, 0x200); put32(section + 20, Self.corRaw)     // raw size, raw pointer
        if let flags = corFlags {
            put32(directories + 14 * 8, 0x1000); put32(directories + 14 * 8 + 4, 0x48)
            put32(Self.corRaw, 0x48); put16(Self.corRaw + 4, 2); put16(Self.corRaw + 6, 5)
            put32(Self.corRaw + 16, flags)
        }
        return d
    }

    var optional: Int { Self.lfanew + 24 }
    var directories: Int { optional + (pe32Plus ? 112 : 96) }
}

private func write(_ data: Data, in tmp: TempFolder, as name: String = "a.exe") -> URL {
    tmp.file(name, contents: data)
}

private func patched(_ data: Data, _ edit: (inout Data) -> Void) -> Data {
    var d = data
    edit(&d)
    return d
}

@Suite struct PEInfoTests {
    @Test func tellsThirtyTwoFromSixtyFourBit() {
        #expect(PEInfo.architecture(ofExecutableAt: fixture("X86Fixture.exe")) == .x86)
        #expect(PEInfo.architecture(ofExecutableAt: fixture("IconFixture.exe")) == .x64)
    }

    @Test func nonPEFilesAreNil() {
        #expect(PEInfo.architecture(ofExecutableAt: fixture("Steam.lnk")) == nil)
        #expect(PEInfo.architecture(ofExecutableAt: URL(fileURLWithPath: "/nonexistent.exe")) == nil)
        #expect(PEInfo.details(ofExecutableAt: fixture("Steam.lnk")) == nil)
        #expect(PEInfo.details(ofExecutableAt: URL(fileURLWithPath: "/nonexistent.exe")) == nil)
    }

    @Test func detailsOfTheRealFixtures() {
        let x86 = PEInfo.details(ofExecutableAt: fixture("X86Fixture.exe"))
        #expect(x86 == PEDetails(architecture: .x86, isDotNet: false, runsAs32Bit: true))
        let x64 = PEInfo.details(ofExecutableAt: fixture("IconFixture.exe"))
        #expect(x64 == PEDetails(architecture: .x64, isDotNet: false, runsAs32Bit: false))
    }

    @Test func architectureNames() {
        #expect(PEArchitecture.x86.displayName == "32-bit")
        #expect(PEArchitecture.x64.displayName == "64-bit")
        #expect(PEArchitecture.arm64.displayName == "ARM64")
        #expect(PEArchitecture.other.displayName == "Unknown")
    }

    // MARK: Damaged files

    @Test func truncatedFilesAreNil() throws {
        let tmp = TempFolder()
        let whole = try Data(contentsOf: fixture("X86Fixture.exe"))
        let lfanew = 0x80                                              // where the PE header starts in the fixture
        // Cut before the COFF header is complete: not a PE image at all.
        for length in [0, 1, 2, 63, 64, 100, lfanew + 3, lfanew + 21] {
            let url = write(whole.prefix(length), in: tmp)
            #expect(PEInfo.architecture(ofExecutableAt: url) == nil, "architecture at \(length) bytes")
            #expect(PEInfo.details(ofExecutableAt: url) == nil, "details at \(length) bytes")
        }
        // Cut inside the optional header: the CPU is known, the rest is not.
        for length in [lfanew + 24, lfanew + 25, lfanew + 24 + 50, lfanew + 24 + 93] {
            let url = write(whole.prefix(length), in: tmp)
            #expect(PEInfo.architecture(ofExecutableAt: url) == .x86, "architecture at \(length) bytes")
            #expect(PEInfo.details(ofExecutableAt: url) == nil, "details at \(length) bytes")
        }
    }

    @Test func cutInsideTheOptionalHeaderIsNil() {
        let tmp = TempFolder()
        let image = PEImage(corFlags: 1).data
        for length in [PEImage.lfanew + 24, PEImage.lfanew + 25, PEImage.lfanew + 24 + 93, PEImage.lfanew + 24 + 96 + 14 * 8 + 4] {
            let url = write(image.prefix(length), in: tmp)
            #expect(PEInfo.details(ofExecutableAt: url) == nil, "details at \(length) bytes")
        }
    }

    @Test func headerBeyondTheEndIsNil() {
        let tmp = TempFolder()
        let image = PEImage().data
        for lfanew in [0x400, 0x3FE, 0x10_0000, 0xFF_FFFF, 0x7FFF_FFFF, 0xFFFF_FFFF, 0] {
            let url = write(patched(image) { d in
                for i in 0..<4 { d[0x3C + i] = UInt8((lfanew >> (8 * i)) & 0xFF) }
            }, in: tmp)
            #expect(PEInfo.architecture(ofExecutableAt: url) == nil, "e_lfanew \(lfanew)")
            #expect(PEInfo.details(ofExecutableAt: url) == nil, "e_lfanew \(lfanew)")
        }
    }

    @Test func aHeaderThatPointsAtNothingIsNotMistakenForPE() {
        let tmp = TempFolder()
        let url = write(patched(PEImage().data) { $0[PEImage.lfanew] = 0x58 }, in: tmp)      // "XE\0\0"
        #expect(PEInfo.details(ofExecutableAt: url) == nil)
    }

    // MARK: .NET

    @Test func plainNativeImageIsNotDotNet() {
        let tmp = TempFolder()
        let d = PEInfo.details(ofExecutableAt: write(PEImage().data, in: tmp))
        #expect(d == PEDetails(architecture: .x86, isDotNet: false, runsAs32Bit: true))
        #expect(d?.label == "32-bit")
    }

    @Test func dotNetAnyCPUDoesNotRunAs32Bit() {
        let tmp = TempFolder()
        let d = PEInfo.details(ofExecutableAt: write(PEImage(corFlags: 0x1).data, in: tmp))
        #expect(d == PEDetails(architecture: .x86, isDotNet: true, runsAs32Bit: false))
        #expect(d?.label == "Any CPU (.NET)")
        #expect(d.flatMap(PEInfo.compatibilityNote) == nil)
    }

    @Test func dotNetBuiltFor32BitRunsAs32Bit() {
        let tmp = TempFolder()
        for flags in [0x3, 0x2, 0x2_0003, 0x0] {            // x86, 32-bit required, "prefer 32-bit", mixed mode
            let d = PEInfo.details(ofExecutableAt: write(PEImage(corFlags: flags).data, in: tmp))
            #expect(d == PEDetails(architecture: .x86, isDotNet: true, runsAs32Bit: true), "flags \(flags)")
            #expect(d?.label == "32-bit (.NET)")
        }
    }

    @Test func dotNetSixtyFourBit() {
        let tmp = TempFolder()
        let d = PEInfo.details(ofExecutableAt: write(PEImage(machine: 0x8664, pe32Plus: true, corFlags: 0x1).data, in: tmp))
        #expect(d == PEDetails(architecture: .x64, isDotNet: true, runsAs32Bit: false))
        #expect(d?.label == "64-bit (.NET)")
    }

    @Test func unreadableDotNetFlagsCountAsThirtyTwoBit() {
        let tmp = TempFolder()
        let image = PEImage(corFlags: 0x1)
        // The CLR directory points outside every section.
        let lost = write(patched(image.data) { d in d[image.directories + 14 * 8 + 1] = 0x90 }, in: tmp, as: "lost.exe")
        #expect(PEInfo.details(ofExecutableAt: lost) == PEDetails(architecture: .x86, isDotNet: true, runsAs32Bit: true))
        // The COR20 header is cut off before its flags.
        let cut = write(image.data.prefix(PEImage.corRaw + 8), in: tmp, as: "cut.exe")
        #expect(PEInfo.details(ofExecutableAt: cut) == PEDetails(architecture: .x86, isDotNet: true, runsAs32Bit: true))
        // The directory is too small to hold a COR20 header.
        let tiny = write(patched(image.data) { d in d[image.directories + 14 * 8 + 4] = 8 }, in: tmp, as: "tiny.exe")
        #expect(PEInfo.details(ofExecutableAt: tiny) == PEDetails(architecture: .x86, isDotNet: true, runsAs32Bit: true))
    }

    @Test func directoriesThatDontFitAreNotDotNet() {
        let tmp = TempFolder()
        let image = PEImage(corFlags: 0x1)
        let few = write(patched(image.data) { $0[image.optional + 92] = 14 }, in: tmp, as: "few.exe")          // 14 directories
        #expect(PEInfo.details(ofExecutableAt: few)?.isDotNet == false)
        let small = write(patched(image.data) { $0[PEImage.lfanew + 4 + 16] = 100 }, in: tmp, as: "small.exe") // optional header too short
        #expect(PEInfo.details(ofExecutableAt: small)?.isDotNet == false)
        let none = write(patched(image.data) { $0[PEImage.lfanew + 4 + 16] = 0; $0[PEImage.lfanew + 4 + 17] = 0 }, in: tmp, as: "none.exe")
        #expect(PEInfo.details(ofExecutableAt: none) == PEDetails(architecture: .x86, isDotNet: false, runsAs32Bit: true))
    }

    @Test func otherMachinesDontRunAs32Bit() {
        let tmp = TempFolder()
        let arm = PEInfo.details(ofExecutableAt: write(PEImage(machine: 0xAA64, pe32Plus: true).data, in: tmp))
        #expect(arm == PEDetails(architecture: .arm64, isDotNet: false, runsAs32Bit: false))
        #expect(arm?.label == "ARM64")
        let odd = PEInfo.details(ofExecutableAt: write(PEImage(machine: 0x01C4).data, in: tmp))
        #expect(odd?.architecture == .other)
        #expect(odd?.runsAs32Bit == false)
        #expect(odd?.label == "Unknown")
    }

    @Test func flagLogic() {
        #expect(PEInfo.runsAs32Bit(architecture: .x86, corFlags: nil))          // native 32-bit, or flags unreadable
        #expect(PEInfo.runsAs32Bit(architecture: .x86, corFlags: 0x3))
        #expect(PEInfo.runsAs32Bit(architecture: .x86, corFlags: 0x0))
        #expect(!PEInfo.runsAs32Bit(architecture: .x86, corFlags: 0x1))         // Any CPU
        #expect(!PEInfo.runsAs32Bit(architecture: .x64, corFlags: nil))
        #expect(!PEInfo.runsAs32Bit(architecture: .x64, corFlags: 0x3))
        #expect(!PEInfo.runsAs32Bit(architecture: .arm64, corFlags: nil))
        #expect(!PEInfo.runsAs32Bit(architecture: .other, corFlags: nil))
    }

    // MARK: Note

    @Test func onlyThirtyTwoBitProgramsGetANote() {
        let note = "This is a 32-bit Windows program. If it uses DirectX 10 or 11, keep a profile with DXVK (Recommended): Wine's own renderer can't give those on a Mac."
        #expect(PEInfo.compatibilityNote(for: PEDetails(architecture: .x86, isDotNet: false, runsAs32Bit: true)) == note)
        #expect(PEInfo.compatibilityNote(for: PEDetails(architecture: .x86, isDotNet: true, runsAs32Bit: true)) == note)
        #expect(PEInfo.compatibilityNote(for: PEDetails(architecture: .x86, isDotNet: true, runsAs32Bit: false)) == nil)
        #expect(PEInfo.compatibilityNote(for: PEDetails(architecture: .x64, isDotNet: false, runsAs32Bit: false)) == nil)
        #expect(PEInfo.compatibilityNote(for: PEDetails(architecture: .arm64, isDotNet: false, runsAs32Bit: false)) == nil)
    }

    @Test func labels() {
        #expect(PEDetails(architecture: .x64, isDotNet: false, runsAs32Bit: false).label == "64-bit")
        #expect(PEDetails(architecture: .x86, isDotNet: false, runsAs32Bit: true).label == "32-bit")
        #expect(PEDetails(architecture: .x86, isDotNet: true, runsAs32Bit: true).label == "32-bit (.NET)")
        #expect(PEDetails(architecture: .x86, isDotNet: true, runsAs32Bit: false).label == "Any CPU (.NET)")
    }
}
