import Foundation
import Testing
@testable import GPlayerCore

@Suite struct PEIconTests {
    /// Built from tools/test-fixtures/icon-fixture: sizes 16, 32 and 48 as BMP, 256 as PNG.
    let exe = fixture("IconFixture.exe")

    func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }

    @Test func readsTheIconAsAValidICO() throws {
        let ico = try #require(PEIcon.icoData(fromExecutableAt: exe))
        #expect(u16(ico, 0) == 0)                      // reserved
        #expect(u16(ico, 2) == 1)                      // type: icon
        let count = u16(ico, 4)
        #expect(count == 4)
        #expect(ico.count >= 6 + count * 16)
        for i in 0..<count {
            let e = 6 + i * 16
            let size = u32(ico, e + 8), offset = u32(ico, e + 12)
            #expect(size > 0)
            #expect(offset >= 6 + count * 16)
            #expect(offset + size <= ico.count)
        }
    }

    @Test func keepsEveryImageAsItIs() throws {
        let ico = try #require(PEIcon.icoData(fromExecutableAt: exe))
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var widths: [Int] = []
        for i in 0..<u16(ico, 4) {
            let e = 6 + i * 16
            let width = Int(ico[e]) == 0 ? 256 : Int(ico[e])
            let offset = u32(ico, e + 12)
            widths.append(width)
            if width == 256 {
                #expect(Array(ico[offset..<offset + 8]) == png)   // PNG blob
            } else {
                #expect(u32(ico, offset) == 40)                   // BITMAPINFOHEADER of a DIB
                #expect(u32(ico, offset + 4) == width)
                #expect(u32(ico, offset + 8) == width * 2)        // XOR and AND masks stacked
            }
        }
        #expect(widths == [16, 32, 48, 256])
    }

    @Test func largestEntryIsTheBiggestPackedSize() throws {
        let ico = try #require(PEIcon.icoData(fromExecutableAt: exe))
        #expect(ico[6 + 3 * 16] == 0)                  // 256 is stored as 0
        #expect(PEIcon.largestEntrySize(inICO: ico) == 256)
    }

    @Test func largestEntrySizeReadsPlainWidths() {
        func ico(_ widths: [UInt8]) -> Data {
            var d = Data([0, 0, 1, 0, UInt8(widths.count), 0])
            for w in widths { d += [w, w] + Data(repeating: 0, count: 14) }
            return d
        }
        #expect(PEIcon.largestEntrySize(inICO: ico([16, 48, 32])) == 48)
        #expect(PEIcon.largestEntrySize(inICO: ico([16, 0])) == 256)
        #expect(PEIcon.largestEntrySize(inICO: ico([])) == nil)
        #expect(PEIcon.largestEntrySize(inICO: Data([0, 0, 2, 0, 1, 0])) == nil)         // a cursor, not an icon
        #expect(PEIcon.largestEntrySize(inICO: Data([0, 0, 1, 0, 3, 0, 16, 16])) == nil) // truncated
        #expect(PEIcon.largestEntrySize(inICO: Data()) == nil)
    }

    @Test func readsFromDataThatIsASlice() throws {
        let whole = try Data(contentsOf: exe)
        let padded = Data([1, 2, 3, 4, 5]) + whole
        let slice = padded.dropFirst(5)
        #expect(slice.startIndex == 5)
        #expect(PEIcon.icoData(fromPE: slice) == PEIcon.icoData(fromPE: whole))
        #expect(PEIcon.icoData(fromPE: whole) != nil)
    }

    @Test func programWithoutAnIconGivesNothing() {
        // The Chromium helper wrapper is built without a resource file.
        let wrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GPlayerCore/Resources/chromium-helper-wrapper.exe")
        #expect(FileManager.default.fileExists(atPath: wrapper.path))
        #expect(PEIcon.icoData(fromExecutableAt: wrapper) == nil)
    }

    @Test func missingFileOrGarbageGivesNothing() {
        #expect(PEIcon.icoData(fromExecutableAt: URL(fileURLWithPath: "/nonexistent/game.exe")) == nil)
        #expect(PEIcon.icoData(fromPE: Data()) == nil)
        #expect(PEIcon.icoData(fromPE: Data("MZ".utf8)) == nil)
        #expect(PEIcon.icoData(fromPE: Data(repeating: 0, count: 4096)) == nil)
        #expect(PEIcon.icoData(fromPE: Data(repeating: 0xFF, count: 4096)) == nil)
    }

    @Test func randomBytesGiveNothing() {
        var rng = SplitMix64(seed: 1)
        for size in [1, 63, 64, 300, 1024, 20_000] {
            let noise = Data((0..<size).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            #expect(PEIcon.icoData(fromPE: noise) == nil)
            // Even with a believable start.
            var mz = noise
            if mz.count > 0x40 { mz[0] = 0x4D; mz[1] = 0x5A; mz[0x3C] = 0x40; mz[0x3D] = 0; mz[0x3E] = 0; mz[0x3F] = 0 }
            #expect(PEIcon.icoData(fromPE: mz) == nil)
        }
    }

    @Test func truncatedProgramGivesNothingAndDoesNotCrash() throws {
        let whole = try Data(contentsOf: exe)
        let full = try #require(PEIcon.icoData(fromPE: whole))
        // Cut the file at every byte of the headers, then at a stride through the rest. The icon is
        // either complete (the cut is past the resource section) or nil; never half an icon.
        let cuts = Array(0..<1024) + Array(stride(from: 1024, to: whole.count, by: 97))
        var firstComplete: Int?
        for cut in cuts {
            let ico = PEIcon.icoData(fromPE: whole.prefix(cut))
            if let ico {
                #expect(ico == full, "cut at \(cut)")
                firstComplete = firstComplete ?? cut
            } else {
                #expect(firstComplete == nil, "cut at \(cut)")
            }
        }
        #expect(try #require(firstComplete) > 1024)
    }

    @Test func damagedProgramNeverCrashes() throws {
        let whole = try Data(contentsOf: exe)
        var rng = SplitMix64(seed: 42)
        for round in 0..<3000 {
            var d = whole
            // Hit the headers and the resource tree harder than the code.
            for _ in 0..<(1 + round % 6) {
                let limit = round % 2 == 0 ? min(512, d.count) : d.count
                d[Int(rng.next() % UInt64(limit))] = UInt8(truncatingIfNeeded: rng.next())
            }
            if let ico = PEIcon.icoData(fromPE: d) {
                #expect(ico.count <= PEIcon.maxICOSize)
                #expect(PEIcon.largestEntrySize(inICO: ico) != nil)
            }
        }
    }

    @Test func hugeSizesInTheResourceTreeAreRefused() throws {
        // Point every 32-bit field in the file at 0xFFFFFFFF, one at a time. No crash, no giant result.
        let whole = try Data(contentsOf: exe)
        for offset in stride(from: 0, to: 0x400, by: 4) {
            var d = whole
            for i in 0..<4 { d[offset + i] = 0xFF }
            if let ico = PEIcon.icoData(fromPE: d) { #expect(ico.count <= PEIcon.maxICOSize) }
        }
    }
}

/// A seeded generator, so a failure can be repeated.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
