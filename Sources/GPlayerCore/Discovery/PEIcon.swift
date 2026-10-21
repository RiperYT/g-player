import Foundation

/// Reads the icon of a Windows program (a PE file) and repackages it as a standard .ico file.
///
/// Walks the resource tree: RT_GROUP_ICON says which RT_ICON images make up the icon, and the images
/// are copied as they are (PNG or BMP). Every read is bounds-checked; anything unexpected gives `nil`.
public enum PEIcon {
    static let maxFileSize = 512 * 1024 * 1024
    static let maxICOSize = 8 * 1024 * 1024
    static let maxIconCount = 256

    private static let rtIcon = 3
    private static let rtGroupIcon = 14

    public static func icoData(fromExecutableAt url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return icoData(fromPE: data)
    }

    public static func icoData(fromPE data: Data) -> Data? {
        guard data.count <= maxFileSize, let file = PEFile(Bytes(data)), let tree = file.resources else { return nil }
        guard let groupDir = tree.subdirectory(ofType: rtGroupIcon),
              let firstGroup = tree.entries(at: groupDir)?.first,
              let group = tree.leaf(of: firstGroup),
              let images = icons(in: group, tree: tree) else { return nil }
        return ico(from: images)
    }

    /// The width of the largest image in an .ico, in pixels (a stored 0 means 256).
    static func largestEntrySize(inICO data: Data) -> Int? {
        let b = Bytes(data)
        guard b.u16(0) == 0, b.u16(2) == 1, let count = b.u16(4), count >= 1 else { return nil }
        var largest = 0
        for i in 0..<count {
            guard let w = b.u8(6 + i * 16) else { return nil }
            largest = max(largest, w == 0 ? 256 : w)
        }
        return largest
    }

    // MARK: Icon images

    private struct Image {
        var width: Int, height: Int, colorCount: Int, planes: Int, bitCount: Int
        var blob: Data
    }

    /// GRPICONDIR: reserved, type = 1, count, then 14-byte entries ending in the RT_ICON id.
    private static func icons(in group: Data, tree: ResourceTree) -> [Image]? {
        let g = Bytes(group)
        guard g.u16(0) == 0, g.u16(2) == 1, let count = g.u16(4), (1...maxIconCount).contains(count),
              let iconDir = tree.subdirectory(ofType: rtIcon), let iconEntries = tree.entries(at: iconDir) else { return nil }
        var byID: [Int: ResourceTree.Entry] = [:]
        for e in iconEntries where !e.isNamed && byID[e.id] == nil { byID[e.id] = e }

        var images: [Image] = []
        var total = 0
        for i in 0..<count {
            let at = 6 + i * 14
            guard let w = g.u8(at), let h = g.u8(at + 1), let colors = g.u8(at + 2),
                  let planes = g.u16(at + 4), let bits = g.u16(at + 6), let id = g.u16(at + 12) else { return nil }
            guard let entry = byID[id], let blob = tree.leaf(of: entry), !blob.isEmpty else { continue }
            total += blob.count
            guard total <= maxICOSize else { return nil }
            images.append(Image(width: w, height: h, colorCount: colors, planes: planes, bitCount: bits, blob: blob))
        }
        return images.isEmpty ? nil : images
    }

    /// ICONDIR, then ICONDIRENTRYs (16 bytes, with an offset instead of an id), then the images.
    private static func ico(from images: [Image]) -> Data? {
        var out = Data()
        out.reserveCapacity(6 + images.count * 16 + images.reduce(0) { $0 + $1.blob.count })
        out.le16(0); out.le16(1); out.le16(images.count)
        var offset = 6 + images.count * 16
        for image in images {
            out.append(UInt8(image.width)); out.append(UInt8(image.height))
            out.append(UInt8(image.colorCount)); out.append(0)
            out.le16(image.planes); out.le16(image.bitCount)
            out.le32(image.blob.count); out.le32(offset)
            offset += image.blob.count
        }
        for image in images { out.append(image.blob) }
        return out.count <= maxICOSize ? out : nil
    }
}

// MARK: - Bounds-checked reading

/// Little-endian reads that return `nil` instead of running past the end.
private struct Bytes {
    let data: Data
    init(_ data: Data) { self.data = data }

    var count: Int { data.count }

    func u8(_ o: Int) -> Int? {
        guard o >= 0, o < count else { return nil }
        return Int(data[data.startIndex + o])
    }

    func u16(_ o: Int) -> Int? {
        guard o >= 0, o <= count - 2 else { return nil }
        let i = data.startIndex + o
        return Int(data[i]) | Int(data[i + 1]) << 8
    }

    func u32(_ o: Int) -> Int? {
        guard o >= 0, o <= count - 4 else { return nil }
        let i = data.startIndex + o
        return Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24
    }

    func slice(_ o: Int, _ n: Int) -> Data? {
        guard o >= 0, n >= 0, o <= count, n <= count - o else { return nil }
        return data.subdata(in: (data.startIndex + o)..<(data.startIndex + o + n))
    }
}

private extension Data {
    mutating func le16(_ v: Int) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    mutating func le32(_ v: Int) { le16(v & 0xFFFF); le16((v >> 16) & 0xFFFF) }
}

// MARK: - PE headers

private struct PEFile {
    struct Section { var va: Int, virtualSize: Int, rawPointer: Int, rawSize: Int }

    let bytes: Bytes
    var sections: [Section] = []
    var resourceRVA = 0, resourceSize = 0

    /// DOS header → "PE\0\0" → COFF header → optional header (PE32 or PE32+) → section table.
    init?(_ bytes: Bytes) {
        self.bytes = bytes
        guard bytes.u16(0) == 0x5A4D, let pe = bytes.u32(0x3C), bytes.u32(pe) == 0x0000_4550,
              let sectionCount = bytes.u16(pe + 6), (1...96).contains(sectionCount),
              let optionalSize = bytes.u16(pe + 20), let magic = bytes.u16(pe + 24) else { return nil }
        let optional = pe + 24
        let directories: Int
        switch magic {
        case 0x10B: directories = optional + 96
        case 0x20B: directories = optional + 112
        default: return nil
        }
        // The resource table is data directory 2; it must fit in the optional header.
        guard directories + 3 * 8 <= optional + optionalSize,
              let rva = bytes.u32(directories + 16), let size = bytes.u32(directories + 20),
              rva > 0, size > 0 else { return nil }
        resourceRVA = rva
        resourceSize = size

        let table = optional + optionalSize
        for i in 0..<sectionCount {
            let s = table + i * 40
            guard let vsize = bytes.u32(s + 8), let va = bytes.u32(s + 12),
                  let rawSize = bytes.u32(s + 16), let rawPointer = bytes.u32(s + 20) else { return nil }
            sections.append(Section(va: va, virtualSize: vsize, rawPointer: rawPointer, rawSize: rawSize))
        }
    }

    /// Maps an RVA to a file offset through the section table.
    func fileOffset(ofRVA rva: Int) -> Int? {
        for s in sections {
            let delta = rva - s.va
            guard delta >= 0, delta < max(s.virtualSize, s.rawSize), delta < s.rawSize else { continue }
            return s.rawPointer + delta
        }
        return nil
    }

    var resources: ResourceTree? {
        guard let root = fileOffset(ofRVA: resourceRVA) else { return nil }
        return ResourceTree(file: self, root: root)
    }
}

// MARK: - Resource tree

private struct ResourceTree {
    /// One IMAGE_RESOURCE_DIRECTORY_ENTRY. The high bit of the first field marks a name (else an id);
    /// the high bit of the second marks a subdirectory (else a data entry).
    struct Entry {
        var name: Int, target: Int
        var isNamed: Bool { name & 0x8000_0000 != 0 }
        var id: Int { name & 0xFFFF }
        var isDirectory: Bool { target & 0x8000_0000 != 0 }
        var offset: Int { target & 0x7FFF_FFFF }
    }

    let file: PEFile
    let root: Int

    /// The entries of the directory at `offset` (from the start of the resource section), named ones first.
    func entries(at offset: Int) -> [Entry]? {
        let b = file.bytes
        let dir = root + offset
        guard let named = b.u16(dir + 12), let ids = b.u16(dir + 14) else { return nil }
        var result: [Entry] = []
        result.reserveCapacity(named + ids)
        for i in 0..<(named + ids) {
            guard let name = b.u32(dir + 16 + i * 8), let target = b.u32(dir + 20 + i * 8) else { return nil }
            result.append(Entry(name: name, target: target))
        }
        return result
    }

    /// The directory of one resource type (RT_ICON, RT_GROUP_ICON), from the top level.
    func subdirectory(ofType type: Int) -> Int? {
        guard let entry = entries(at: 0)?.first(where: { !$0.isNamed && $0.id == type }), entry.isDirectory else { return nil }
        return entry.offset
    }

    /// The bytes behind an entry. Subdirectories (languages) are followed to their first entry.
    func leaf(of entry: Entry) -> Data? {
        let b = file.bytes
        var entry = entry
        for _ in 0..<2 where entry.isDirectory {
            guard let first = entries(at: entry.offset)?.first else { return nil }
            entry = first
        }
        guard !entry.isDirectory,
              let rva = b.u32(root + entry.offset), let size = b.u32(root + entry.offset + 4),
              size <= PEIcon.maxICOSize, let start = file.fileOffset(ofRVA: rva) else { return nil }
        return b.slice(start, size)
    }
}
