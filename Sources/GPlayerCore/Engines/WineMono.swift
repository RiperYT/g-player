import Foundation

/// A Wine Mono release: .NET for Wine, which programs built on .NET (installers with managed custom actions, launchers, some
/// games) need. It belongs to an engine (`EngineInfo.mono`), because Wine looks for the version it was built against.
public struct WineMonoPackage: Sendable, Hashable {
    public let version: String
    /// The release's tarball, `wine-mono-<version>-x86.tar.xz`, which unpacks to one folder named `folderName`.
    public let download: PinnedDownload
    /// The room it takes unpacked, measured and rounded up.
    public let installedBytes: Int64

    public var folderName: String { "wine-mono-\(version)" }
}

/// Wine Mono for G-Player Wine, fetched into the engine when something needs it and registered in a space once.
///
/// Wine finds a shared Wine Mono at `<engine>/share/wine/mono/wine-mono-<version>`, so one copy serves every space. A space
/// then needs the release's "Wine Mono Windows Support" package (`support/winemono-support.msi`) installed once, which makes
/// it look as if .NET is there, and `mscoree` must not be turned off for its programs (`LaunchTweaks.dotNetAvailable`).
/// Without that, an installer with managed custom actions fails with "SFXCA: Failed to load mscoree.dll (Error code 126)".
public enum WineMono {
    /// The name the support package registers in the space (its `DisplayName`), with `DisplayVersion` the Wine Mono version.
    static let productName = "Wine Mono Windows Support"

    /// Where the engine's Wine looks for this Wine Mono: `<wine root>/share/wine/mono/wine-mono-<version>`.
    public static func folder(of package: WineMonoPackage, in wineRoot: URL) -> URL {
        wineRoot.appendingPathComponent("share/wine/mono", isDirectory: true)
            .appendingPathComponent(package.folderName, isDirectory: true)
    }

    /// The package that registers it in a space.
    public static func supportInstaller(of package: WineMonoPackage, in wineRoot: URL) -> URL {
        supportInstaller(in: folder(of: package, in: wineRoot))
    }

    static func supportInstaller(in folder: URL) -> URL { folder.appendingPathComponent("support/winemono-support.msi") }

    /// The folder holds a Wine Mono: it has its support package. What an unpack made is checked with this before it is moved
    /// into place.
    static func isWhole(_ folder: URL) -> Bool { FileManager.default.fileExists(atPath: supportInstaller(in: folder).path) }

    /// Written into the folder last, once it is in place, with the SHA-256 of the archive it came from. A move that stopped halfway
    /// (a copy, when the engine's folder is on another disk than G-Player's work folder) leaves a folder without it.
    static let markerName = ".gplayer-unpacked"

    static func markerFile(in folder: URL) -> URL { folder.appendingPathComponent(markerName) }

    /// Marks `folder` (the one `folder(of:in:)` names) as a whole copy of `package`.
    static func writeMarker(for package: WineMonoPackage, in folder: URL) throws {
        try Data(package.download.sha256.utf8).write(to: markerFile(in: folder), options: .atomic)
    }

    /// Wine Mono is in the engine: its folder is there with its support package, and the marker says the copy is whole and is
    /// this release's.
    public static func isUnpacked(_ package: WineMonoPackage, in wineRoot: URL) -> Bool {
        let folder = folder(of: package, in: wineRoot)
        guard isWhole(folder), let marker = try? String(contentsOf: markerFile(in: folder), encoding: .utf8) else { return false }
        return marker == package.download.sha256
    }

    // MARK: How long its path is

    /// What Wine's `mscoree` builds in a buffer of 260 characters (`WCHAR mono_dll_path[MAX_PATH]` in `dlls/mscoree/metahost.c`,
    /// filled with `lstrcpyW` and no check) to find Mono: the DOS name of the engine's data folder (`WINEDATADIR`: `Z:` and the
    /// path), `\mono\wine-mono-<version>`, and this.
    static let libmonoSuffix = "\\bin\\libmono-2.0-x86_64.dll"

    /// The length of that path, with the `Z:` drive. Counted as `PrefixPath` counts: /var, /tmp and /etc by their longer /private form.
    public static func loadPathLength(of package: WineMonoPackage, in wineRoot: URL) -> Int {
        2 + PrefixPath.length(of: folder(of: package, in: wineRoot).path) + libmonoSuffix.utf16.count
    }

    /// Wine can load this Wine Mono: the path `mscoree` builds for it, and its end, fit in 260 characters (the last being the
    /// terminator). A longer one would overflow the buffer; the library folder `PrefixPath` allows leaves room for it (114
    /// characters, 206 here), a folder an older G-Player allowed may not.
    public static func pathFits(_ package: WineMonoPackage, in wineRoot: URL) -> Bool {
        loadPathLength(of: package, in: wineRoot) < 260
    }

    // MARK: In a space

    /// The text of a space's `system.reg` says the support package of exactly this version is installed. Installing it writes the
    /// product under `Installer\UserData\S-1-5-18\Products\…\InstallProperties` and `Uninstall\{…}`, each with
    ///
    ///     "DisplayName"="Wine Mono Windows Support"
    ///     "DisplayVersion"="10.4.1"
    ///
    /// A key that has the name with another version (an older Wine Mono) doesn't count: the support package of this one is
    /// installed over it. Both values must be in the same key.
    public static func isRegistered(_ package: WineMonoPackage, inRegistry text: String) -> Bool {
        let name = "\"DisplayName\"=\"\(productName)\""
        let version = "\"DisplayVersion\"=\"\(package.version)\""
        var named = false, versioned = false
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("[") || line.allSatisfy(\.isWhitespace) {   // a new key, or the blank line that ends one
                named = false; versioned = false
                continue
            }
            if line.hasPrefix(name) { named = true } else if line.hasPrefix(version) { versioned = true }
            if named && versioned { return true }
        }
        return false
    }

    /// The space has it registered. Reads the space's `system.reg`, which Wine writes when its server quits and every
    /// half minute: a space where a Windows program is running may not have it on disk yet. A few MB: not for a view's `body`.
    public static func isRegistered(_ package: WineMonoPackage, in space: Space) -> Bool {
        guard let data = try? Data(contentsOf: space.url.appendingPathComponent("system.reg")) else { return false }
        return isRegistered(package, inRegistry: String(decoding: data, as: UTF8.self))
    }

    /// The command line that installs the support package in a space: quietly, from where it is in the engine (a `Z:` path).
    public static func registerArguments(_ package: WineMonoPackage, wineRoot: URL, in space: Space) -> [String] {
        ["msiexec", "/i", space.windowsPath(for: supportInstaller(of: package, in: wineRoot)), "/qn"]
    }

    /// Installing the support package takes seconds; one that runs longer than this is stopped.
    public static let registerTimeout: TimeInterval = 120

    // MARK: What a launch has to do

    /// What a program that needs .NET still has to have done for it, so that Wine can load Mono.
    public struct Plan: Equatable, Sendable {
        public var package: WineMonoPackage
        /// The engine doesn't have Wine Mono yet: it is downloaded into it.
        public var fetch: Bool
        /// The space doesn't have the support package registered: it is installed there once, which writes into the space.
        public var register: Bool

        /// Nothing is left to do: `mscoree` can stay on.
        public var isReady: Bool { !fetch && !register }
    }

    /// The steps for a program that needs `wanted` (the engine's Wine Mono, when something needs .NET), or nil when nothing
    /// asks for it. `inEngine` and `registered` are what `isUnpacked` and `isRegistered` found.
    public static func plan(wanted: WineMonoPackage?, inEngine: Bool, registered: Bool) -> Plan? {
        wanted.map { Plan(package: $0, fetch: !inEngine, register: !registered) }
    }

    /// What the sidebar calls the download: "Downloading Wine Mono".
    public static let downloadTitle = String(localized: "Downloading Wine Mono")
    /// What it is called to those who wait behind it in a space's queue.
    public static let registerTitle = String(localized: "Setting up Wine Mono")

    /// The room fetching it takes: the tarball and what it unpacks to, less what a stopped download already has on disk.
    public static func neededBytes(_ package: WineMonoPackage, alreadyDownloaded: Int64) -> Int64 {
        max(0, package.download.approximateBytes - alreadyDownloaded) + package.installedBytes
    }

    /// "Wine Mono, 40 MB", for the line that says what is being fetched.
    public static func sizeLabel(_ package: WineMonoPackage) -> String {
        String(localized: "\(EngineCatalog.megabytes(package.download.approximateBytes)) MB")
    }

    // MARK: Registering

    /// Installs the support package in `space` with the engine's own `msiexec`, with `mscoree` allowed (the package's setup is
    /// the first program there that may want it), and checks that the space lists it afterwards. Waits for the space's Wine server
    /// to quit so the registry is on disk when it looks: call it only when no program runs in the space.
    public static func register(_ package: WineMonoPackage, engine: Engine, space: Space, logsFolder: URL) async throws {
        guard isUnpacked(package, in: engine.wineRoot) else {
            throw ShellError.failed(String(localized: "Wine Mono isn't in \(engine.info.name) yet."))
        }
        let status = try await WineLauncher.runAndWait(
            engine: engine, space: space, arguments: registerArguments(package, wineRoot: engine.wineRoot, in: space),
            workingDirectory: space.driveC, backend: .wined3d, tweaks: LaunchTweaks(dotNetAvailable: true),
            logsFolder: logsFolder, logName: "Wine Mono", timeout: registerTimeout)
        try Task.checkCancellation()
        await WineLauncher.waitForAll(engine: engine, space: space, timeout: 30)
        try Task.checkCancellation()
        guard isRegistered(package, in: space) else {
            throw ShellError.failed(String(localized: "Wine Mono's setup finished (code \(status)), but “\(space.name)” doesn't list it. The log is in \(logsFolder.path)."))
        }
    }
}
