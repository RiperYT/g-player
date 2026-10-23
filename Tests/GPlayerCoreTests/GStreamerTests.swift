import Foundation
import Testing
@testable import GPlayerCore

/// G-Player Wine's GStreamer: the list its archive carries, the check against the pinned package, and copying the listed files
/// out of the expanded official package.
@Suite struct GStreamerRuntimeTests {
    let pin = EngineCatalog.gstreamer
    let sha = "d371ab04a7632713626836c2fc234e863cc98484c74c473eba99b0fbd9b3a3fe"

    // MARK: The pin

    @Test func theOfficialPackageIsPinnedOnceAndNeededByG_PlayerWineAlone() {
        #expect(pin.url.absoluteString == "https://gstreamer.freedesktop.org/data/pkg/osx/1.28.8/gstreamer-1.0-1.28.8-universal.pkg")
        #expect(pin.fileName == "gstreamer-1.0-1.28.8-universal.pkg" && pin.sha256 == sha)
        #expect(pin.approximateBytes == 156_581_817 && pin.role == .gstreamer)
        // The expanded package is room the install needs for a while, and is counted by the disk check.
        #expect(pin.scratchBytes == 705_000_000)
        #expect(EngineCatalog.crossover.downloads.last == pin)
        #expect(EngineCatalog.crossover.downloads.map(\.role) == [.engine, .runtimeLibraries, .dxvk, .gstreamer])
        #expect(!EngineCatalog.wineStaging.downloads.contains { $0.role == .gstreamer })
        #expect(!EngineCatalog.crossoverRevision1.downloads.contains { $0.role == .gstreamer })
    }

    @Test func theDiskCheckCountsEveryArchiveAndTheExpandedPackage() {
        // G-Player Wine on its own: what it takes unpacked, every archive it downloads (they stay until it has installed, so a
        // failure in the last step doesn't download them again) and the room GStreamer's package takes while it is expanded,
        // the biggest scratch of the install.
        let gplayerWine = EngineCatalog.crossover
        let archives: Int64 = 285_662_140 + 193_105_336 + 3_900_000 + 156_581_817
        #expect(gplayerWine.installedBytes == 1_700_000_000)
        #expect(gplayerWine.downloads.map(\.approximateBytes).reduce(0, +) == archives)
        #expect(gplayerWine.installWorkBytes == archives + 705_000_000)
        #expect(EngineCatalog.diskBytes(installing: [gplayerWine]) == 1_700_000_000 + archives + 705_000_000)
        // Without a scratch size an engine's room is its archives: Wine Staging's two.
        let staging = EngineCatalog.wineStaging
        #expect(staging.installWorkBytes == 193_105_336 + 3_900_000)
        #expect(EngineCatalog.diskBytes(installing: [staging]) == 750_000_000 + 193_105_336 + 3_900_000)
        #expect(EngineCatalog.diskBytes(installing: []) == 0)
        // One after the other: every engine stays once unpacked, and the room for files is the biggest engine's, free again
        // after each.
        #expect(EngineCatalog.firstRunDiskBytes(installed: []) == 750_000_000 + 1_700_000_000 + archives + 705_000_000)
        #expect(EngineCatalog.firstRunDiskBytes(installed: [staging]) == 1_700_000_000 + archives + 705_000_000)
    }

    // MARK: The list

    @Test func theListNamesThePackageAndTheFiles() throws {
        let text = "package gstreamer-1.0-1.28.8-universal.pkg \(sha)\nlib/gstreamer-1.0/libgstapplemedia.dylib\nlib/libglib-2.0.0.dylib\n"
        let manifest = try GStreamerRuntime.parse(text)
        #expect(manifest.packageName == "gstreamer-1.0-1.28.8-universal.pkg" && manifest.sha256 == sha)
        #expect(manifest.files == ["lib/gstreamer-1.0/libgstapplemedia.dylib", "lib/libglib-2.0.0.dylib"])
        // Windows line ends, blank lines and spaces around a line change nothing.
        let untidy = "\r\npackage  gstreamer-1.0-1.28.8-universal.pkg   \(sha)\r\n\r\n  lib/libglib-2.0.0.dylib  \r\n"
        #expect(try GStreamerRuntime.parse(untidy).files == ["lib/libglib-2.0.0.dylib"])
    }

    @Test func aDamagedListIsRefused() {
        let head = "package gstreamer-1.0-1.28.8-universal.pkg \(sha)"
        let bad = ["", "lib/a.dylib", head, head + "\n",                                     // no files, or no first line
                   "packages x.pkg \(sha)\nlib/a.dylib", "package x.pkg abc\nlib/a.dylib",   // not a package line, a short checksum
                   "package x.pkg \(sha.uppercased())\nlib/a.dylib", "package dir/x.pkg \(sha)\nlib/a.dylib",
                   head + "\n/etc/passwd", head + "\n../lib/a.dylib", head + "\nlib/../../a.dylib", head + "\nlib//a.dylib",
                   head + "\n./a.dylib", head + "\nlib/./a.dylib"]
        for text in bad { #expect(throws: ShellError.self, "\(text)") { try GStreamerRuntime.parse(text) } }
    }

    @Test func aFolderWithoutAListHasNoGStreamerStep() throws {
        let tmp = TempFolder()
        #expect(try GStreamerRuntime.manifest(in: tmp.url) == nil)
        tmp.file("gstreamer-files.txt", contents: Data("package gstreamer-1.0-1.28.8-universal.pkg \(sha)\nlib/a.dylib\n".utf8))
        #expect(try GStreamerRuntime.manifest(in: tmp.url)?.files == ["lib/a.dylib"])
        tmp.file("gstreamer-files.txt", contents: Data("nonsense".utf8))
        #expect(throws: ShellError.self) { try GStreamerRuntime.manifest(in: tmp.url) }
    }

    @Test func onlyTheKnownPackageIsAccepted() throws {
        let known = GStreamerRuntime.Manifest(packageName: pin.fileName, sha256: pin.sha256, files: ["lib/a.dylib"])
        try GStreamerRuntime.check(known, against: pin)
        let newer = GStreamerRuntime.Manifest(packageName: "gstreamer-1.0-1.30.0-universal.pkg", sha256: pin.sha256, files: ["lib/a.dylib"])
        let other = GStreamerRuntime.Manifest(packageName: pin.fileName, sha256: String(repeating: "a", count: 64), files: ["lib/a.dylib"])
        for manifest in [newer, other] {
            let error = try #require(throws: ShellError.self) { try GStreamerRuntime.check(manifest, against: pin) }
            #expect(error.localizedDescription.contains("a GStreamer this version of G-Player doesn't know"))
        }
    }

    // MARK: Copying

    /// A package as `pkgutil --expand-full` leaves it: `<sub>.pkg/Payload/…` per sub-package.
    private func expanded(_ tmp: TempFolder, _ parts: [String: [String: String]]) -> URL {
        for (sub, files) in parts { for (path, text) in files { tmp.file("expanded/\(sub).pkg/Payload/\(path)", contents: Data(text.utf8)) } }
        return tmp.url.appendingPathComponent("expanded")
    }

    @Test func eachListedFileIsCopiedUnderItsNameAndNothingElse() throws {
        let tmp = TempFolder()
        let source = expanded(tmp, ["core": ["lib/libglib-2.0.0.dylib": "glib", "lib/unlisted.dylib": "x"],
                                    "plugins": ["lib/gstreamer-1.0/libgstapplemedia.dylib": "apple"]])
        let wine = tmp.dir("engine/wine")
        let manifest = GStreamerRuntime.Manifest(packageName: pin.fileName, sha256: pin.sha256,
                                                 files: ["lib/gstreamer-1.0/libgstapplemedia.dylib", "lib/libglib-2.0.0.dylib"])
        try GStreamerRuntime.copyFiles(of: manifest, from: source, into: wine)
        #expect(try String(contentsOf: wine.appendingPathComponent("lib/libglib-2.0.0.dylib"), encoding: .utf8) == "glib")
        #expect(try String(contentsOf: wine.appendingPathComponent("lib/gstreamer-1.0/libgstapplemedia.dylib"), encoding: .utf8) == "apple")
        #expect(!FileManager.default.fileExists(atPath: wine.appendingPathComponent("lib/unlisted.dylib").path))
    }

    @Test func theFirstSubPackageThatHasTheFileWins() throws {
        let tmp = TempFolder()
        let source = expanded(tmp, ["b-extras": ["lib/shared.dylib": "from b", "lib/only-b.dylib": "b"],
                                    "a-core": ["lib/shared.dylib": "from a"]])
        let wine = tmp.dir("engine/wine")
        let manifest = GStreamerRuntime.Manifest(packageName: pin.fileName, sha256: pin.sha256, files: ["lib/shared.dylib", "lib/only-b.dylib"])
        try GStreamerRuntime.copyFiles(of: manifest, from: source, into: wine)
        #expect(try String(contentsOf: wine.appendingPathComponent("lib/shared.dylib"), encoding: .utf8) == "from a")
        #expect(try String(contentsOf: wine.appendingPathComponent("lib/only-b.dylib"), encoding: .utf8) == "b")
    }

    @Test func aLinkIsFollowedAndTheRealFileCopiedUnderTheListedName() throws {
        let tmp = TempFolder()
        let source = expanded(tmp, ["core": ["lib/libglib-2.0.0.dylib.real": "glib"]])
        let payload = source.appendingPathComponent("core.pkg/Payload/lib")
        try FileManager.default.createSymbolicLink(atPath: payload.appendingPathComponent("libglib-2.0.0.dylib").path,
                                                   withDestinationPath: "libglib-2.0.0.dylib.real")
        let wine = tmp.dir("engine/wine")
        let manifest = GStreamerRuntime.Manifest(packageName: pin.fileName, sha256: pin.sha256, files: ["lib/libglib-2.0.0.dylib"])
        try GStreamerRuntime.copyFiles(of: manifest, from: source, into: wine)
        let copy = wine.appendingPathComponent("lib/libglib-2.0.0.dylib")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: copy.path)) == nil)        // a file, not a link
        #expect(try String(contentsOf: copy, encoding: .utf8) == "glib")
    }

    @Test func aLinkLeadingOutOfThePackageIsNotUsed() throws {
        // A link that points at the user's own GStreamer (or anything else on the Mac) would copy a file nobody checked.
        let tmp = TempFolder()
        let outside = tmp.file("outside/libglib-2.0.0.dylib", contents: Data("the user's own".utf8))
        let source = expanded(tmp, ["core": ["lib/other.dylib": "x"], "plugins": ["lib/libglib-2.0.0.dylib": "the package's"]])
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("core.pkg/Payload/lib/libglib-2.0.0.dylib").path,
                                                   withDestinationPath: outside.path)
        let wine = tmp.dir("engine/wine")
        let manifest = GStreamerRuntime.Manifest(packageName: pin.fileName, sha256: pin.sha256, files: ["lib/libglib-2.0.0.dylib"])
        try GStreamerRuntime.copyFiles(of: manifest, from: source, into: wine)                          // the next sub-package has it
        #expect(try String(contentsOf: wine.appendingPathComponent("lib/libglib-2.0.0.dylib"), encoding: .utf8) == "the package's")
        // With no other copy it is missing.
        try FileManager.default.removeItem(at: source.appendingPathComponent("plugins.pkg"))
        #expect(throws: ShellError.self) { try GStreamerRuntime.copyFiles(of: manifest, from: source, into: tmp.dir("engine2/wine")) }
    }

    @Test func aMissingFileFailsAndSaysWhich() throws {
        let tmp = TempFolder()
        let source = expanded(tmp, ["core": ["lib/a.dylib": "a"]])
        let manifest = GStreamerRuntime.Manifest(packageName: pin.fileName, sha256: pin.sha256, files: ["lib/a.dylib", "lib/gone.dylib"])
        let error = try #require(throws: ShellError.self) {
            try GStreamerRuntime.copyFiles(of: manifest, from: source, into: tmp.dir("engine/wine"))
        }
        #expect(error.localizedDescription.contains("lib/gone.dylib"))
        // A folder in place of the file isn't one either.
        tmp.dir("expanded/core.pkg/Payload/lib/folder.dylib")
        let folder = GStreamerRuntime.Manifest(packageName: pin.fileName, sha256: pin.sha256, files: ["lib/folder.dylib"])
        #expect(throws: ShellError.self) { try GStreamerRuntime.copyFiles(of: folder, from: source, into: tmp.dir("engine2/wine")) }
    }

    @Test func aFileAlreadyThereIsReplaced() throws {
        let tmp = TempFolder()
        let source = expanded(tmp, ["core": ["lib/a.dylib": "package's"]])
        let wine = tmp.dir("engine/wine")
        tmp.file("engine/wine/lib/a.dylib", contents: Data("older".utf8))
        let manifest = GStreamerRuntime.Manifest(packageName: pin.fileName, sha256: pin.sha256, files: ["lib/a.dylib"])
        try GStreamerRuntime.copyFiles(of: manifest, from: source, into: wine)
        #expect(try String(contentsOf: wine.appendingPathComponent("lib/a.dylib"), encoding: .utf8) == "package's")
    }
}

/// The install step with a real package made by the stock tools, expanded by the stock `pkgutil`. No network, no Wine.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/productbuild")
                    && FileManager.default.isExecutableFile(atPath: "/usr/bin/pkgbuild")))
struct GStreamerInstallTests {
    /// A product archive like GStreamer's: sub-packages whose payloads are parts of one tree (the framework's Versions/1.0).
    private func package(_ tmp: TempFolder) async throws -> URL {
        let core = tmp.dir("src/core"), plugins = tmp.dir("src/plugins")
        tmp.file("src/core/lib/libglib-2.0.0.dylib.real", contents: Data("glib".utf8))
        try FileManager.default.createSymbolicLink(atPath: core.appendingPathComponent("lib/libglib-2.0.0.dylib").path,
                                                   withDestinationPath: "libglib-2.0.0.dylib.real")
        tmp.file("src/plugins/lib/gstreamer-1.0/libgstapplemedia.dylib", contents: Data("apple".utf8))
        var parts: [URL] = []
        for (name, root) in [("core", core), ("plugins", plugins)] {
            let pkg = tmp.url.appendingPathComponent("\(name).pkg")
            let made = try await Shell.run(URL(fileURLWithPath: "/usr/bin/pkgbuild"), [
                "--root", root.path, "--identifier", "test.\(name)", "--version", "1",
                "--install-location", "/Library/Frameworks/GStreamer.framework/Versions/1.0", pkg.path])
            try #require(made.succeeded, "\(made.stderr)")
            parts.append(pkg)
        }
        let product = tmp.url.appendingPathComponent("gstreamer-test.pkg")
        let made = try await Shell.run(URL(fileURLWithPath: "/usr/bin/productbuild"), parts.flatMap { ["--package", $0.path] } + [product.path])
        try #require(made.succeeded, "\(made.stderr)")
        return product
    }

    private func manager(_ tmp: TempFolder) -> EngineManager { EngineManager(paths: LibraryPaths(root: tmp.url.appendingPathComponent("Lib"))) }

    @Test func theListedFilesComeOutOfTheExpandedPackageAndTheExpansionIsGone() async throws {
        let tmp = TempFolder()
        let product = try await package(tmp)
        let staging = tmp.dir("staging"), wine = tmp.dir("staging/wine")
        let manifest = GStreamerRuntime.Manifest(packageName: "gstreamer-test.pkg", sha256: String(repeating: "0", count: 64),
                                                 files: ["lib/gstreamer-1.0/libgstapplemedia.dylib", "lib/libglib-2.0.0.dylib"])
        try await manager(tmp).installGStreamer(from: product, manifest: manifest, into: wine)
        #expect(try String(contentsOf: wine.appendingPathComponent("lib/libglib-2.0.0.dylib"), encoding: .utf8) == "glib")
        #expect(try String(contentsOf: wine.appendingPathComponent("lib/gstreamer-1.0/libgstapplemedia.dylib"), encoding: .utf8) == "apple")
        // Only the engine's own files stay: the expansion was inside the staging folder and is deleted at once.
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path) == ["wine"])
    }

    @Test func aFileThePackageLacksFailsTheInstallAndLeavesNoExpansion() async throws {
        let tmp = TempFolder()
        let product = try await package(tmp)
        let staging = tmp.dir("staging"), wine = tmp.dir("staging/wine")
        let manifest = GStreamerRuntime.Manifest(packageName: "gstreamer-test.pkg", sha256: String(repeating: "0", count: 64),
                                                 files: ["lib/libglib-2.0.0.dylib", "lib/not-in-the-package.dylib"])
        await #expect(throws: ShellError.self) { try await manager(tmp).installGStreamer(from: product, manifest: manifest, into: wine) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path) == ["wine"])
    }

    @Test func somethingThatIsNotAPackageFailsWithWhatPkgutilSaid() async throws {
        let tmp = TempFolder()
        let notAPackage = tmp.file("gstreamer-test.pkg", contents: Data("not a package".utf8))
        let wine = tmp.dir("staging/wine")
        let manifest = GStreamerRuntime.Manifest(packageName: "gstreamer-test.pkg", sha256: String(repeating: "0", count: 64), files: ["lib/a.dylib"])
        let error = try await #require(throws: ShellError.self) {
            try await manager(tmp).installGStreamer(from: notAPackage, manifest: manifest, into: wine)
        }
        #expect(error.localizedDescription.contains("Couldn't unpack gstreamer-test.pkg"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.appendingPathComponent("staging").path) == ["wine"])
    }
}
