import Foundation

/// What a Windows executable is built for, read from its PE header.
public enum PEArchitecture: String, Codable, Sendable, Hashable {
    case x86, x64, arm64, other

    public var displayName: String {
        switch self {
        case .x86: String(localized: "32-bit")
        case .x64: String(localized: "64-bit")
        case .arm64: "ARM64"
        case .other: String(localized: "Unknown")
        }
    }
}

/// What the PE headers say about a program.
public struct PEDetails: Sendable, Equatable {
    public let architecture: PEArchitecture
    /// The image has a .NET (CLR) header.
    public let isDotNet: Bool
    /// The program starts as a 32-bit process. False for 64-bit images and for .NET "Any CPU" programs.
    public let runsAs32Bit: Bool

    /// The row text in the inspector: "64-bit", "32-bit (.NET)", "Any CPU (.NET)".
    public var label: String {
        let base = isDotNet && architecture == .x86 && !runsAs32Bit ? "Any CPU" : architecture.displayName
        return isDotNet ? "\(base) (.NET)" : base
    }
}

public enum PEInfo {
    /// The CPU an .exe targets, or nil when the file isn't a PE image.
    public static func architecture(ofExecutableAt url: URL) -> PEArchitecture? {
        guard let reader = Reader(url), let header = coffHeader(reader) else { return nil }
        return header.architecture
    }

    /// CPU, .NET and 32-bit facts of an .exe, or nil when the file isn't a complete PE image.
    /// Reads only the headers, never the whole file.
    public static func details(ofExecutableAt url: URL) -> PEDetails? {
        guard let reader = Reader(url), let coff = coffHeader(reader) else { return nil }
        let machineIs32 = coff.architecture == .x86
        let optional = coff.offset + 24                                      // after "PE\0\0" and the COFF header
        let plain = PEDetails(architecture: coff.architecture, isDotNet: false, runsAs32Bit: machineIs32)
        guard coff.optionalHeaderSize >= 2 else { return plain }             // no optional header
        guard let magic = reader.u16(optional) else { return nil }
        let isPE32 = magic == 0x10B
        guard isPE32 || magic == 0x20B else { return plain }

        // Data directories follow the fixed fields; the CLR runtime header is directory 14. A header that is
        // too short to have one is simply not .NET; a file that ends inside the header is not a PE image.
        let end = optional + coff.optionalHeaderSize
        let countAt = optional + (isPE32 ? 92 : 108)
        let clrAt = optional + (isPE32 ? 96 : 112) + 14 * 8
        guard countAt + 4 <= end else { return plain }
        guard let directoryCount = reader.u32(countAt) else { return nil }
        guard directoryCount > 14, clrAt + 8 <= end else { return plain }
        guard let clrRVA = reader.u32(clrAt), let clrSize = reader.u32(clrAt + 4) else { return nil }
        guard clrRVA > 0, clrSize > 0 else { return plain }

        // A .NET program built for "Any CPU" has a 32-bit header but starts as 64-bit on a 64-bit system.
        var flags: Int?
        if isPE32, machineIs32, clrSize >= 20,
           let table = reader.bytes(at: end, count: coff.sectionCount * 40),
           let corOffset = fileOffset(ofRVA: clrRVA, sections: table) {
            flags = reader.u32(corOffset + 16)                               // IMAGE_COR20_HEADER.Flags
        }
        return PEDetails(architecture: coff.architecture, isDotNet: true,
                         runsAs32Bit: runsAs32Bit(architecture: coff.architecture, corFlags: flags))
    }

    /// The warning for a program that starts as 32-bit, or nil.
    public static func compatibilityNote(for details: PEDetails) -> String? {
        details.runsAs32Bit
            ? String(localized: "This is a 32-bit Windows program. If it uses DirectX 10 or 11, keep a profile with DXVK (Recommended): Wine's own renderer can't give those on a Mac.")
            : nil
    }

    // MARK: Decisions

    static let corILOnly = 0x1
    static let cor32BitRequired = 0x2

    /// Whether the program starts as 32-bit. `corFlags` are the COR20 header flags of a .NET image, if they
    /// could be read. A 32-bit image counts as 32-bit unless the flags say IL only and not 32-bit required.
    static func runsAs32Bit(architecture: PEArchitecture, corFlags: Int?) -> Bool {
        guard architecture == .x86 else { return false }
        guard let flags = corFlags else { return true }
        return !(flags & corILOnly != 0 && flags & cor32BitRequired == 0)
    }

    // MARK: Reading

    private struct COFF {
        let offset: Int                                                       // of "PE\0\0"
        let architecture: PEArchitecture
        let sectionCount: Int
        let optionalHeaderSize: Int
    }

    /// DOS header → "PE\0\0" → the 20-byte COFF header.
    private static func coffHeader(_ reader: Reader) -> COFF? {
        guard reader.u16(0) == 0x5A4D, let lfanew = reader.u32(0x3C),                          // "MZ"
              lfanew > 0, lfanew < 16 << 20, reader.u32(lfanew) == 0x0000_4550,                // "PE\0\0"
              let machine = reader.u16(lfanew + 4), let sections = reader.u16(lfanew + 6),
              let optionalSize = reader.u16(lfanew + 20) else { return nil }
        let architecture: PEArchitecture
        switch machine {
        case 0x014C: architecture = .x86
        case 0x8664: architecture = .x64
        case 0xAA64: architecture = .arm64
        default: architecture = .other
        }
        return COFF(offset: lfanew, architecture: architecture, sectionCount: min(sections, 96), optionalHeaderSize: optionalSize)
    }

    /// Maps an RVA to a file offset through the section table (40 bytes per section).
    private static func fileOffset(ofRVA rva: Int, sections table: Data) -> Int? {
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o <= table.count - 4 else { return nil }
            let i = table.startIndex + o
            return Int(table[i]) | Int(table[i + 1]) << 8 | Int(table[i + 2]) << 16 | Int(table[i + 3]) << 24
        }
        for s in stride(from: 0, to: table.count - 39, by: 40) {
            guard let va = u32(s + 12), let rawSize = u32(s + 16), let rawPointer = u32(s + 20) else { return nil }
            let delta = rva - va
            if delta >= 0, delta < rawSize { return rawPointer + delta }
        }
        return nil
    }

    /// Bounds-checked reads from a file: anything past the end gives nil. Closes the file when it goes away.
    private final class Reader {
        let handle: FileHandle
        let size: Int

        init?(_ url: URL) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            guard let end = try? handle.seekToEnd() else { try? handle.close(); return nil }
            self.handle = handle
            self.size = Int(clamping: end)
        }

        deinit { try? handle.close() }

        func bytes(at offset: Int, count: Int) -> Data? {
            guard offset >= 0, count >= 0, offset <= size, count <= size - offset else { return nil }
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return data
        }

        func u16(_ offset: Int) -> Int? {
            guard let d = bytes(at: offset, count: 2) else { return nil }
            return Int(d[d.startIndex]) | Int(d[d.startIndex + 1]) << 8
        }

        func u32(_ offset: Int) -> Int? {
            guard let d = bytes(at: offset, count: 4) else { return nil }
            let i = d.startIndex
            return Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24
        }
    }
}
