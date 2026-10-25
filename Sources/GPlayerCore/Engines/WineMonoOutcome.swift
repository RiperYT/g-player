import Foundation

/// How an attempt to bring Wine Mono into place ended, what is remembered of a failure, and what is said about it. Decided
/// without touching Wine or the network, so it can be tested; `AppModel+WineMono` does the work and shows the words.
extension WineMono {
    /// A failed attempt in a space, kept in the space (`.gplayer-wine-mono.json`) so that a restart doesn't forget it: like a Windows
    /// component that failed (`RuntimeInstaller`), it isn't tried again on every start for a while.
    public struct Failure: Codable, Equatable, Sendable {
        /// The Wine Mono it was about: another release is tried at once.
        public var version: String
        public var date: Date
        /// The Mac couldn't reach the server (no connection, a timeout): nothing was wrong with Wine Mono.
        public var offline: Bool
        /// What went wrong, as the error said it.
        public var reason: String

        public init(version: String, date: Date, offline: Bool, reason: String) {
            self.version = version; self.date = date; self.offline = offline; self.reason = reason
        }
    }

    /// How long a failure is waited out: the three days a failed component waits (`RuntimeInstaller.retryAfter`), and for a Mac that
    /// was offline only ten minutes, since it is likely to be back.
    public static let retryAfter: TimeInterval = 3 * 24 * 60 * 60
    public static let offlineRetryAfter: TimeInterval = 10 * 60

    /// An attempt isn't made: `failure` is of this release and still within its wait. A date in the future (a clock set back)
    /// is not waited for.
    public static func isWaiting(_ failure: Failure?, for package: WineMonoPackage, now: Date = Date()) -> Bool {
        guard let failure, failure.version == package.version else { return false }
        let age = now.timeIntervalSince(failure.date)
        return age >= 0 && age < (failure.offline ? offlineRetryAfter : retryAfter)
    }

    static let failureFileName = ".gplayer-wine-mono.json"

    static func failureFile(in space: Space) -> URL { space.url.appendingPathComponent(failureFileName) }

    /// What was kept of the last failure in the space, nil when there is none or it can't be read.
    public static func failure(in space: Space) -> Failure? {
        guard let data = try? Data(contentsOf: failureFile(in: space)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Failure.self, from: data)
    }

    /// Keeps a failure. Only for a space G-Player may change. A write that fails only means the next start tries again.
    public static func record(_ failure: Failure, in space: Space) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(failure) else { return }
        try? data.write(to: failureFile(in: space), options: .atomic)
    }

    public static func forgetFailure(in space: Space) { try? FileManager.default.removeItem(at: failureFile(in: space)) }

    // MARK: Outcome

    public enum Outcome: Equatable, Sendable {
        /// In the engine and registered in the space: .NET can be on.
        case ready
        /// The space may not be changed (an external one the user didn't allow).
        case notAllowed
        /// The path Wine builds to Wine Mono is this long, over what `mscoree` can hold (`pathFits`).
        case tooLong(Int)
        /// Programs run in the space (the launcher is open): they keep the environment they started with, so nothing was fetched.
        case spaceBusy
        /// An earlier attempt failed and its wait isn't over: nothing was tried.
        case waiting(Failure)
        /// This attempt failed.
        case failed(Failure)
        /// The user stopped it. `everything`: they stopped everything in the space (Stop All, the tile's Stop), which also ends
        /// the start the setup was for; otherwise only the setup (its Stop in the sidebar), and the start goes on without .NET.
        case stopped(everything: Bool)
    }

    /// The outcome of an attempt that threw `error`. Work cut short because the user stopped everything in the space isn't a failure,
    /// whatever error the killed program left behind; a connection that was down is an offline one.
    public static func outcome(after error: Error, stoppedEverything: Bool, package: WineMonoPackage,
                               now: Date = Date()) -> Outcome {
        if stoppedEverything { return .stopped(everything: true) }
        if error is CancellationError { return .stopped(everything: false) }
        return .failed(Failure(version: package.version, date: now, offline: EngineManager.isConnectionFailure(error),
                               reason: error.localizedDescription))
    }

    // MARK: Words

    /// A short title and one line, for the note a space and the library show.
    public struct Note: Equatable, Sendable {
        public var title: String
        public var text: String
    }

    /// What to tell the user about an outcome, or nil when there is nothing to tell. `program` is what the .NET is for ("Epic
    /// Games Launcher"), `purpose` why ("Epic Online Services").
    public static func note(for outcome: Outcome, program: String, purpose: String) -> Note? {
        switch outcome {
        case .ready, .notAllowed, .stopped:
            return nil
        case .spaceBusy:
            return Note(title: String(localized: ".NET isn't added yet"),
                        text: String(localized: "Quit \(program) and open it again to add .NET (needed for \(purpose))."))
        case .tooLong(let length):
            return Note(title: String(localized: "Wine Mono's path is too long"),
                        text: String(localized: "Wine loads Wine Mono only from a path under 260 characters, and this library's is \(length). Move the library folder closer to the top of a disk, such as your home folder, then open \(program) again."))
        case .waiting(let failure), .failed(let failure):
            if failure.offline {
                return Note(title: String(localized: "Couldn't add .NET"),
                            text: String(localized: "Wine Mono (.NET, needed for \(purpose)) couldn't be downloaded: this Mac isn't online. \(program) starts without it, and G-Player tries again when you open it later."))
            }
            return Note(title: String(localized: "Couldn't add .NET"),
                        text: String(localized: "Wine Mono (.NET, needed for \(purpose)) wasn't added. \(sentence(failure.reason)) \(program) starts without it, and G-Player tries again in a few days."))
        }
    }

    /// What a space that G-Player may not change loses for a program that needs .NET, for the notes that say the space is kept as it is.
    public static func refusedLine(program: String, purpose: String) -> String {
        String(localized: "Without .NET (Wine Mono), \(program) can't set up \(purpose).")
    }

    /// Whether the note is shown now, or has been before in this run: what is said in answer to something the user just did (a
    /// launcher that is open, a failure) is always shown; what is only repeated by a start that skips the attempt (a wait that isn't
    /// over, a path too long) is said once.
    public static func showsNote(for outcome: Outcome, alreadyShown: Bool) -> Bool {
        switch outcome {
        case .spaceBusy, .failed: true
        case .waiting, .tooLong: !alreadyShown
        case .ready, .notAllowed, .stopped: false
        }
    }

    /// The alert for an attempt that failed now, or nil: a Mac that was offline (the note says so, once) and everything else gets none.
    /// `consequence` says what happens next ("Epic Games Launcher starts without .NET.").
    public static func alert(for outcome: Outcome, space: String, consequence: String) -> String? {
        guard case .failed(let failure) = outcome, !failure.offline else { return nil }
        return String(localized: "Couldn't set up Wine Mono in “\(space)”: \(sentence(failure.reason)) \(consequence)")
    }

    /// `text` ended with a full stop, unless it ends with a mark already.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
        return trimmed + "."
    }

    /// The room Wine Mono takes unpacked, for the card that says what the first start adds: "245 MB".
    public static func installedSizeLabel(_ package: WineMonoPackage) -> String {
        String(localized: "\(EngineCatalog.megabytes(package.installedBytes)) MB", comment: "A size in megabytes")
    }
}
