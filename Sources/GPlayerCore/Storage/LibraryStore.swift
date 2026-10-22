import Foundation

/// Why a library can't be opened. While one stands the app writes nothing, so a library that is only out of reach
/// (a disk that isn't connected yet) or that a newer version wrote differently is never replaced by an empty one.
public struct LibraryProblem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The library folder isn't there: its disk isn't connected, or the folder was renamed or moved.
        case folderMissing
        /// The folder is there, library.json isn't, but a previous copy of it is: this was a library.
        case fileMissing
        /// library.json is there and can't be read.
        case unreadable
    }

    public let kind: Kind
    public let root: URL
    /// What failed, in a few words; empty when the folder is missing.
    public let reason: String
    /// Where an unreadable library.json was copied before anything else happened. Nil when it couldn't be copied.
    public let brokenCopy: URL?
    /// `library.json.previous` is there and reads fine, so it can take the place of the missing or unreadable file.
    public let previousIsUsable: Bool

    public init(kind: Kind, root: URL, reason: String = "", brokenCopy: URL? = nil, previousIsUsable: Bool = false) {
        self.kind = kind; self.root = root; self.reason = reason; self.brokenCopy = brokenCopy; self.previousIsUsable = previousIsUsable
    }
}

/// What opening a library found.
public enum LibraryOpening: Equatable, Sendable {
    case ready(LibraryState)
    case blocked(LibraryProblem)
}

/// Loads and saves `library.json`. Writes are atomic so a crash never leaves half a file, and the file as it was
/// before the last change stays as `library.json.previous`.
public struct LibraryStore: Sendable {
    public let paths: LibraryPaths

    public init(paths: LibraryPaths) { self.paths = paths }

    static let brokenPrefix = "library.json.broken-"

    /// Opens the library. A read that fails is a problem to show, never an empty library: the caller must not save
    /// anything until the user has decided what to do.
    /// - Parameter expectingLibrary: the library was set up before (onboarding is done), so a folder that is gone is
    ///   a problem too. Before that the folder is new and simply doesn't exist yet.
    public func open(expectingLibrary: Bool, now: Date = Date()) -> LibraryOpening {
        let fm = FileManager.default
        guard Files.isDirectory(paths.root) else {
            return expectingLibrary ? .blocked(problem(.folderMissing)) : .ready(LibraryState())
        }
        guard fm.fileExists(atPath: paths.libraryFile.path) else {
            // Nothing there. With a previous copy next to it this was a library, so the user decides; without, it is new.
            return fm.fileExists(atPath: paths.previousFile.path) ? .blocked(problem(.fileMissing)) : .ready(LibraryState())
        }
        do {
            return .ready(try Self.decoder.decode(LibraryState.self, from: try Data(contentsOf: paths.libraryFile)))
        } catch {
            return .blocked(problem(.unreadable, reason: Self.describe(error), brokenCopy: keepBrokenCopy(now: now)))
        }
    }

    /// The whole library, or an error. `open` is what the app uses.
    public func load() throws -> LibraryState {
        guard FileManager.default.fileExists(atPath: paths.libraryFile.path) else { return LibraryState() }
        return try Self.decoder.decode(LibraryState.self, from: try Data(contentsOf: paths.libraryFile))
    }

    /// Writes the library. The file it replaces is kept as `library.json.previous` when that file was a good one, so a
    /// wiped or damaged file never takes the last good copy with it. A save that changes nothing writes nothing.
    public func save(_ state: LibraryState) throws {
        try paths.createFolders()
        let data = try Self.encoder.encode(state)
        if let current = try? Data(contentsOf: paths.libraryFile) {
            if current == data { return }
            if (try? Self.decoder.decode(LibraryState.self, from: current)) != nil {
                try? current.write(to: paths.previousFile, options: .atomic)      // the library is saved either way
            }
        }
        try data.write(to: paths.libraryFile, options: .atomic)
    }

    /// Puts `library.json.previous` in the place of library.json and returns it. An unreadable library.json is kept
    /// as a `.broken-` copy first. Throws when the previous copy can't be read, and changes nothing then.
    public func restorePrevious(now: Date = Date()) throws -> LibraryState {
        let data = try Data(contentsOf: paths.previousFile)
        let state = try Self.decoder.decode(LibraryState.self, from: data)
        if FileManager.default.fileExists(atPath: paths.libraryFile.path), keepBrokenCopy(now: now) == nil {
            throw ShellError.failed("G-Player couldn't keep a copy of library.json, so it won't replace it.")
        }
        try data.write(to: paths.libraryFile, options: .atomic)
        return state
    }

    /// The library folder `chosen` stands for: the folder itself when library.json (or its previous copy) is in it, or
    /// its `G-Player` folder, for someone who chose the folder that holds the library. Nil when neither is.
    public static func libraryFolder(in chosen: URL) -> URL? {
        let fm = FileManager.default
        for folder in [chosen, chosen.appendingPathComponent("G-Player", isDirectory: true)] {
            let paths = LibraryPaths(root: folder)
            if fm.fileExists(atPath: paths.libraryFile.path) || fm.fileExists(atPath: paths.previousFile.path) { return paths.root }
        }
        return nil
    }

    // MARK: Pieces

    private func problem(_ kind: LibraryProblem.Kind, reason: String = "", brokenCopy: URL? = nil) -> LibraryProblem {
        LibraryProblem(kind: kind, root: paths.root, reason: reason, brokenCopy: brokenCopy,
                       previousIsUsable: (try? Data(contentsOf: paths.previousFile))
                           .flatMap { try? Self.decoder.decode(LibraryState.self, from: $0) } != nil)
    }

    /// `library.json.broken-2026-10-23-142530`
    static func brokenName(at date: Date, in zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return brokenPrefix + f.string(from: date)
    }

    /// Copies library.json next to itself and returns the copy, or nil when that failed. A copy with the same content is
    /// reused, so pressing Try Again on the same damaged file doesn't pile up copies.
    func keepBrokenCopy(now: Date) -> URL? {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: paths.root.path)) ?? [] where name.hasPrefix(Self.brokenPrefix) {
            let earlier = paths.root.appendingPathComponent(name)
            if fm.contentsEqual(atPath: earlier.path, andPath: paths.libraryFile.path) { return earlier }
        }
        let copy = Files.uniqueURL(in: paths.root, name: Self.brokenName(at: now))
        do { try fm.copyItem(at: paths.libraryFile, to: copy); return copy } catch { return nil }
    }

    /// The decoder's complaint in a few words: what is wrong and where ("games[2].title: no value").
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func place(_ path: [CodingKey]) -> String {
            path.enumerated().map { i, key in key.intValue.map { "[\($0)]" } ?? (i == 0 ? key.stringValue : "." + key.stringValue) }.joined()
        }
        switch error {
        case .keyNotFound(let key, let context): return "\(place(context.codingPath + [key])): missing"
        case .valueNotFound(_, let context): return "\(place(context.codingPath)): no value"
        case .typeMismatch(_, let context): return "\(place(context.codingPath)): wrong kind of value"
        case .dataCorrupted(let context):
            let at = place(context.codingPath)
            return at.isEmpty ? "not valid JSON" : "\(at): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
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
