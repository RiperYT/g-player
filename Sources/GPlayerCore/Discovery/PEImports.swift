import Foundation

/// Which DLLs a Windows program links to, read from its PE import tables.
public enum PEImports {
    /// Lower-cased DLL names from the import table and the delay-load import table, without duplicates, in file
    /// order. Empty for a valid image that imports nothing. nil when the file isn't a PE image or its tables are
    /// damaged. Reads only the headers, the tables and the name strings, never the whole file.
    public static func importedDLLs(ofExecutableAt url: URL) -> [String]? {
        guard let reader = Reader(url), let image = Image(reader) else { return nil }
        var names: [String] = []
        for table in [Table.imports, Table.delayImports] {
            guard let found = image.dllNames(in: table) else { return nil }
            for name in found where !names.contains(name) { names.append(name) }
        }
        return names
    }

    // MARK: Limits

    /// Real programs link to a few dozen DLLs; a table with more entries than this is not trusted.
    static let maxDescriptors = 512
    /// Longest DLL name read (a Windows path is at most 260 characters).
    static let maxNameLength = 260
    static let maxSections = 96

    // MARK: Tables

    private enum Table {
        case imports, delayImports

        var directoryIndex: Int { self == .imports ? 1 : 13 }
        var descriptorSize: Int { self == .imports ? 20 : 32 }
        /// Offset of the DLL name inside one descriptor.
        var nameField: Int { self == .imports ? 12 : 4 }
    }

    // MARK: Image

    /// The parts of the PE headers the import tables need.
    private struct Image {
        let reader: Reader
        let isPE32: Bool
        let imageBase: Int
        let sizeOfHeaders: Int
        /// (virtual address, raw size, raw pointer) per section.
        let sections: [(va: Int, rawSize: Int, rawPointer: Int)]
        /// RVA of each data directory the file has room for, by index.
        let directories: [Int]

        init?(_ reader: Reader) {
            guard reader.u16(0) == 0x5A4D, let lfanew = reader.u32(0x3C),                    // "MZ"
                  lfanew > 0, lfanew < 16 << 20, reader.u32(lfanew) == 0x0000_4550,          // "PE\0\0"
                  let sectionCount = reader.u16(lfanew + 6), sectionCount <= PEImports.maxSections,
                  let optionalSize = reader.u16(lfanew + 20) else { return nil }
            let optional = lfanew + 24
            guard let magic = reader.u16(optional), magic == 0x10B || magic == 0x20B else { return nil }
            let isPE32 = magic == 0x10B
            let end = optional + optionalSize
            let countAt = optional + (isPE32 ? 92 : 108)
            let firstDirectory = optional + (isPE32 ? 96 : 112)
            guard countAt + 4 <= end, let directoryCount = reader.u32(countAt),
                  let headersSize = reader.u32(optional + 60) else { return nil }

            let base: Int?
            if isPE32 {
                base = reader.u32(optional + 28)
            } else if let low = reader.u32(optional + 24), let high = reader.u32(optional + 28) {
                base = high < 1 << 30 ? low | high << 32 : nil                         // user-mode addresses are far below 2^62
            } else {
                base = nil
            }
            guard let imageBase = base else { return nil }

            // Only the directories we read, and only the ones that fit inside the optional header.
            var directories: [Int] = []
            for index in 0...13 {
                let at = firstDirectory + index * 8
                guard index < min(directoryCount, 16), at + 8 <= end else { break }
                guard let rva = reader.u32(at) else { return nil }
                directories.append(rva)
            }

            var sections: [(va: Int, rawSize: Int, rawPointer: Int)] = []
            if sectionCount > 0 {
                guard let table = reader.bytes(at: end, count: sectionCount * 40) else { return nil }
                for s in 0..<sectionCount {
                    let entry = table.startIndex + s * 40
                    func u32(_ o: Int) -> Int {
                        Int(table[entry + o]) | Int(table[entry + o + 1]) << 8 | Int(table[entry + o + 2]) << 16 | Int(table[entry + o + 3]) << 24
                    }
                    sections.append((va: u32(12), rawSize: u32(16), rawPointer: u32(20)))
                }
            }
            self.reader = reader; self.isPE32 = isPE32; self.imageBase = imageBase
            self.sizeOfHeaders = headersSize; self.sections = sections; self.directories = directories
        }

        /// File offset of an RVA and how many bytes of the file are mapped from there on.
        func locate(_ rva: Int) -> (offset: Int, room: Int)? {
            for s in sections {
                let delta = rva - s.va
                if delta >= 0, delta < s.rawSize { return (s.rawPointer + delta, s.rawSize - delta) }
            }
            if rva < sizeOfHeaders, sizeOfHeaders <= reader.size { return (rva, sizeOfHeaders - rva) }   // tables inside the headers
            return nil
        }

        /// The DLL names of one table: [] when the image has none, nil when it is damaged.
        func dllNames(in table: Table) -> [String]? {
            guard table.directoryIndex < directories.count, directories[table.directoryIndex] != 0 else { return [] }
            guard let start = locate(directories[table.directoryIndex]) else { return nil }
            var names: [String] = []
            for index in 0..<PEImports.maxDescriptors {
                // A table that runs off its section without an end marker is damaged.
                guard (index + 1) * table.descriptorSize <= start.room,
                      let descriptor = reader.bytes(at: start.offset + index * table.descriptorSize, count: table.descriptorSize)
                else { return nil }
                func field(_ at: Int) -> Int {
                    let i = descriptor.startIndex + at
                    return Int(descriptor[i]) | Int(descriptor[i + 1]) << 8 | Int(descriptor[i + 2]) << 16 | Int(descriptor[i + 3]) << 24
                }
                var nameRVA = field(table.nameField)
                if table == .imports {
                    if nameRVA == 0 || field(16) == 0 { return names }                    // the loader stops here
                } else {
                    if nameRVA == 0 { return names }
                    // Old delay-load tables hold addresses, not RVAs, unless the first attribute bit says so.
                    if field(0) & 1 == 0 {
                        guard nameRVA >= imageBase else { return nil }
                        nameRVA -= imageBase
                    }
                }
                guard let name = dllName(atRVA: nameRVA) else { return nil }
                names.append(name)
            }
            return nil                                                                    // more entries than any real program has
        }

        /// A NUL-ended printable ASCII name, lower-cased.
        func dllName(atRVA rva: Int) -> String? {
            guard let spot = locate(rva), spot.room > 0,
                  let data = reader.bytes(upTo: min(PEImports.maxNameLength + 1, spot.room), at: spot.offset),
                  let end = data.firstIndex(of: 0), end > data.startIndex else { return nil }
            let name = data[data.startIndex..<end]
            guard name.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
            return String(decoding: name, as: UTF8.self).lowercased()
        }
    }

    // MARK: Reading

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

        /// Up to `count` bytes from `offset`; fewer when the file ends first. nil when `offset` is outside the file.
        func bytes(upTo count: Int, at offset: Int) -> Data? {
            guard offset >= 0, offset < size else { return nil }
            return bytes(at: offset, count: min(count, size - offset))
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
