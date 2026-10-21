import Foundation

/// Loads and saves `library.json`. Writes are atomic so a crash never leaves half a file.
public struct LibraryStore: Sendable {
    public let paths: LibraryPaths

    public init(paths: LibraryPaths) { self.paths = paths }

    public func load() throws -> LibraryState {
        guard FileManager.default.fileExists(atPath: paths.libraryFile.path) else { return LibraryState() }
        let data = try Data(contentsOf: paths.libraryFile)
        return try Self.decoder.decode(LibraryState.self, from: data)
    }

    public func save(_ state: LibraryState) throws {
        try paths.createFolders()
        let data = try Self.encoder.encode(state)
        try data.write(to: paths.libraryFile, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(LibraryStore.dateFormatter.string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = LibraryStore.dateFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        return d
    }()

    /// ISO 8601 with milliseconds, so dates survive a save exactly.
    nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
