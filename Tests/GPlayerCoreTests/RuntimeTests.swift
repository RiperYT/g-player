import Foundation
import Testing
@testable import GPlayerCore

// Windows components: the catalog, the install state, native-vs-builtin detection, the registry text,
// winetricks' environment and safety edits, and the shell shims winetricks runs on. No network, no Wine.

// MARK: Catalog

@Suite struct RuntimeCatalogTests {
    @Test func idsAreUniqueAndTheBaseSetIsRight() {
        let ids = RuntimeCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(RuntimeCatalog.base.map(\.id) == ["vcrun2022", "d3dcompiler_47"])
        #expect(RuntimeCatalog.all.filter(\.isBase).map(\.id) == RuntimeCatalog.base.map(\.id))
        #expect(RuntimeCatalog.component("vcrun2022")?.isBase == true)
        #expect(RuntimeCatalog.component("d3dx9")?.isBase == false)
        #expect(RuntimeCatalog.component("nonsense") == nil)
    }

    @Test func theOnDemandSetIsThere() {
        let wanted = ["d3dx9", "d3dx10", "d3dx11_43", "d3dcompiler_43", "xact", "xinput", "dotnet48", "physx", "xna40",
                      "openal", "mfc140", "vcrun2013", "vcrun2010", "vcrun2008", "corefonts", "cjkfonts"]
        for id in wanted { #expect(RuntimeCatalog.component(id) != nil, "\(id) is missing") }
        #expect(RuntimeCatalog.component("vcrun2019") == nil)             // vcrun2022 stands in for it
    }

    @Test func everyComponentIsDescribedAndAWinetricksVerb() {
        for c in RuntimeCatalog.all {
            #expect(!c.name.isEmpty && !c.summary.isEmpty && !c.license.isEmpty, "\(c.id)")
            #expect((c.approximateBytes ?? 0) > 0, "\(c.id)")                    // every size is known
            #expect(Winetricks.isVerb(c.id), "\(c.id)")
        }
    }

    @Test func everyNativeDownloadIsPinned() {
        let downloads = RuntimeCatalog.native.values.flatMap(\.downloads) + [Winetricks.script]
        #expect(downloads.count == 5)
        for d in downloads {
            #expect(d.url.scheme == "https", "\(d.fileName)")
            #expect(d.sha256.count == 64 && d.sha256.allSatisfy { "0123456789abcdef".contains($0) }, "\(d.fileName)")
            #expect(d.approximateBytes > 0, "\(d.fileName)")
        }
        let names = downloads.map(\.fileName)
        #expect(Set(names).count == names.count)
    }

    @Test func microsoftLinksCarryTheHashOfTheFileTheyServe() {
        // download.visualstudio.microsoft.com/download/pr/<id>/<SHA-256>/<file>: the link can't serve another file.
        for setup in RuntimeCatalog.vcrun2022.setups {
            #expect(setup.file.url.absoluteString.contains(setup.file.sha256.uppercased()), "\(setup.file.fileName)")
        }
    }

    @Test func nativeSpecsMatchWhatWinetricksDoes() {
        let vc = RuntimeCatalog.vcrun2022
        #expect(vc.overrides.count == 11)
        #expect(vc.overrides.allSatisfy { $0.mode == .nativeThenBuiltin })
        #expect(vc.setups.map(\.file.fileName) == ["vc_redist.x86.exe", "vc_redist.x64.exe"])
        #expect(vc.setups.allSatisfy { $0.arguments == ["/install", "/quiet", "/norestart"] })
        let d3d = RuntimeCatalog.d3dcompiler47
        #expect(d3d.overrides.map(\.dll) == ["d3dcompiler_47"] && d3d.overrides.map(\.mode) == [.native])
        #expect(d3d.copies.map(\.arch) == [.x86, .x64])
        #expect(d3d.copies.allSatisfy { $0.name == "d3dcompiler_47.dll" })
    }
}

// MARK: State and detection

@Suite struct RuntimeStateTests {
    let installer = RuntimeInstaller(paths: LibraryPaths(root: URL(fileURLWithPath: "/tmp/gplayer-runtime-unused")))

    @Test func recordedComponentsRoundTrip() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Main"))
        #expect(installer.installed(in: s).isEmpty)
        try installer.record("d3dx9", in: s, at: Date(timeIntervalSince1970: 0))
        try installer.record("vcrun2008", in: s)
        #expect(installer.installed(in: s) == ["d3dx9", "vcrun2008"])

        // The file sits in the prefix root and has the documented shape.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: s.url.appendingPathComponent(".gplayer-components.json")))
        let installed = try #require((json as? [String: Any])?["installed"] as? [String: String])
        #expect(installed["d3dx9"] == "1970-01-01T00:00:00Z")
        #expect(installed.keys.sorted() == ["d3dx9", "vcrun2008"])
    }

    @Test func missingKeepsOrderAndDropsDuplicates() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Main"))
        try installer.record("d3dx9", in: s)
        #expect(installer.missing(["xact", "d3dx9", "vcrun2008", "xact"], in: s) == ["xact", "vcrun2008"])
        #expect(installer.missing([], in: s).isEmpty)
    }

    @Test func aDamagedStateFileCountsAsEmptyAndIsOverwritten() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Main"))
        tmp.file("Main/.gplayer-components.json", contents: Data("{ not json".utf8))
        #expect(installer.installed(in: s).isEmpty)
        try installer.record("physx", in: s)
        #expect(installer.installed(in: s) == ["physx"])
    }

    // MARK: Native or Wine's own?

    /// A DLL that starts like a PE file; `marker` is where Wine puts its own text.
    private func dll(_ marker: String? = nil) -> Data {
        var bytes = Data([0x4D, 0x5A]) + Data(repeating: 0, count: 62)
        if let marker { bytes += Data(marker.utf8) + Data([0]) }
        return bytes + Data(repeating: 0x90, count: 400)
    }

    @Test func nativeIsToldFromBuiltinPlaceholderLinkAndGarbage() throws {
        let tmp = TempFolder()
        let native = tmp.file("native.dll", contents: dll())
        let builtin = tmp.file("builtin.dll", contents: dll("Wine builtin DLL"))
        let placeholder = tmp.file("placeholder.dll", contents: dll("Wine placeholder DLL"))
        let notPE = tmp.file("garbage.dll", contents: Data(repeating: 0x41, count: 600))
        let empty = tmp.file("empty.dll", contents: Data())
        let link = tmp.url.appendingPathComponent("link.dll")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: native)

        #expect(RuntimeInstaller.isNativeDLL(at: native))
        #expect(!RuntimeInstaller.isNativeDLL(at: builtin))
        #expect(!RuntimeInstaller.isNativeDLL(at: placeholder))
        #expect(!RuntimeInstaller.isNativeDLL(at: notPE))
        #expect(!RuntimeInstaller.isNativeDLL(at: empty))
        #expect(!RuntimeInstaller.isNativeDLL(at: link))
        #expect(!RuntimeInstaller.isNativeDLL(at: tmp.url.appendingPathComponent("missing.dll")))
    }

    @Test func aBottleWithNativeFilesCountsAsInstalled() {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Bottle"))
        func put(_ folder: String, _ name: String, _ marker: String? = nil) {
            tmp.file("Bottle/drive_c/windows/\(folder)/\(name)", contents: dll(marker))
        }
        tmp.dir("Bottle/drive_c/windows/syswow64")
        for name in ["msvcp140.dll", "vcruntime140.dll"] { put("system32", name); put("syswow64", name) }
        put("system32", "vcruntime140_1.dll", "Wine builtin DLL")
        put("system32", "d3dcompiler_47.dll", "Wine builtin DLL")
        put("syswow64", "d3dcompiler_47.dll")
        #expect(installer.installed(in: s).isEmpty)                     // one builtin file is enough to say "no"

        put("system32", "vcruntime140_1.dll")
        put("system32", "d3dcompiler_47.dll")
        #expect(installer.installed(in: s) == ["vcrun2022", "d3dcompiler_47"])
    }

    @Test func a32BitBottleNeedsNoVcruntime1401() {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Old"))
        for name in ["msvcp140.dll", "vcruntime140.dll"] { tmp.file("Old/drive_c/windows/system32/\(name)", contents: dll()) }
        #expect(installer.installed(in: s) == ["vcrun2022"])
    }

    @Test func filesAreWrittenToTheRightFolder() throws {
        let tmp = TempFolder()
        let s64 = space(at: tmp.prefix("W64")); tmp.dir("W64/drive_c/windows/syswow64")
        let s32 = space(at: tmp.prefix("W32"))
        #expect(RuntimeInstaller.systemFolder(.x86, of: s64).lastPathComponent == "syswow64")
        #expect(RuntimeInstaller.systemFolder(.x64, of: s64).lastPathComponent == "system32")
        #expect(RuntimeInstaller.systemFolder(.x86, of: s32).lastPathComponent == "system32")

        // A DLL replaces Wine's own, or a link to it.
        let source = tmp.file("new.dll", contents: dll())
        let folder = RuntimeInstaller.systemFolder(.x64, of: s64)
        tmp.file("W64/drive_c/windows/system32/a.dll", contents: dll("Wine builtin DLL"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("b.dll"), withDestinationURL: tmp.file("elsewhere.dll"))
        try RuntimeInstaller.put(source, as: "a.dll", in: folder)
        try RuntimeInstaller.put(source, as: "b.dll", in: folder)
        #expect(RuntimeInstaller.isNativeDLL(at: folder.appendingPathComponent("a.dll")))
        #expect(RuntimeInstaller.isNativeDLL(at: folder.appendingPathComponent("b.dll")))
    }
}

// MARK: Registry text, order, errors before anything runs

@Suite struct RuntimeInstallerTests {
    @Test func theOverridesFileIsExactlyWhatWineExpects() {
        let text = RuntimeInstaller.overridesRegFile(RuntimeCatalog.d3dcompiler47.overrides)
        #expect(text == "REGEDIT4\n\n[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n\"*d3dcompiler_47\"=\"native\"\n")

        let vc = RuntimeInstaller.overridesRegFile(RuntimeCatalog.vcrun2022.overrides)
        #expect(vc == """
            REGEDIT4

            [HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]
            "*concrt140"="native,builtin"
            "*msvcp140"="native,builtin"
            "*msvcp140_1"="native,builtin"
            "*msvcp140_2"="native,builtin"
            "*msvcp140_atomic_wait"="native,builtin"
            "*msvcp140_codecvt_ids"="native,builtin"
            "*vcamp140"="native,builtin"
            "*vccorlib140"="native,builtin"
            "*vcomp140"="native,builtin"
            "*vcruntime140"="native,builtin"
            "*vcruntime140_1"="native,builtin"

            """)
    }

    @Test func baseComponentsGoFirstAndEachIdOnce() {
        #expect(RuntimeInstaller.installOrder(["xact", "d3dcompiler_47", "d3dx9", "vcrun2022", "xact"])
                == ["vcrun2022", "d3dcompiler_47", "d3dx9", "xact"])
        #expect(RuntimeInstaller.installOrder(["somethingnew", "dotnet48", "other", "physx"])
                == ["dotnet48", "physx", "somethingnew", "other"])
    }

    @Test func installedComponentsAreSkippedWithoutTouchingAnything() async throws {
        let tmp = TempFolder()
        let paths = LibraryPaths(root: tmp.url.appendingPathComponent("Library"))
        let installer = RuntimeInstaller(paths: paths)
        let s = space(at: tmp.prefix("Main"))
        try installer.record("vcrun2022", in: s)
        try installer.record("d3dx9", in: s)
        let calls = CallCounter()
        try await installer.install(["d3dx9", "vcrun2022"], in: s, engine: fakeEngine()) { _, _ in calls.count += 1 }
        #expect(calls.count == 0)
        #expect(!FileManager.default.fileExists(atPath: paths.downloads.path))
    }

    @Test func nonsenseIsRefusedBeforeAnythingIsInstalled() async {
        let tmp = TempFolder()
        let installer = RuntimeInstaller(paths: LibraryPaths(root: tmp.url.appendingPathComponent("Library")))
        let s = space(at: tmp.prefix("Main"))
        for bad in ["--self-update", "annihilate", "../evil", "a b"] {
            await #expect(throws: ShellError.self) {
                try await installer.install(["vcrun2022", bad], in: s, engine: fakeEngine()) { _, _ in }
            }
        }
        #expect(installer.installed(in: s).isEmpty)
    }

    @Test func aSpaceWithoutAWindowsFolderIsAClearError() async {
        let tmp = TempFolder()
        let installer = RuntimeInstaller(paths: LibraryPaths(root: tmp.url.appendingPathComponent("Library")))
        let s = space(at: tmp.dir("Empty"))
        do {
            try await installer.install(["d3dx9"], in: s, engine: fakeEngine()) { _, _ in }
            Issue.record("expected an error")
        } catch { #expect(error.localizedDescription.contains("isn't ready")) }
    }

    // MARK: Downloads (file:// links stand in for the network)

    private func pinned(_ source: URL, name: String = "tool.dll", sha: String) -> PinnedDownload {
        PinnedDownload(url: source, fileName: name, sha256: sha, approximateBytes: 1)
    }

    @Test func aMatchingDownloadIsKeptAndReusedWithoutDownloadingAgain() async throws {
        let tmp = TempFolder()
        let source = tmp.file("server/tool.dll", contents: Data("the real file".utf8))
        let sha = try Files.sha256(of: source)
        let cache = tmp.url.appendingPathComponent("cache")
        let first = try await RuntimeInstaller.fetch(pinned(source, sha: sha), into: cache)
        #expect(try Data(contentsOf: first) == Data("the real file".utf8))

        try FileManager.default.removeItem(at: source)                    // the "server" is gone
        let second = try await RuntimeInstaller.fetch(pinned(source, sha: sha), into: cache)
        #expect(second == first)
    }

    @Test func aChangedFileIsNeverUsed() async throws {
        let tmp = TempFolder()
        let source = tmp.file("server/tool.dll", contents: Data("Microsoft replaced this".utf8))
        let cache = tmp.url.appendingPathComponent("cache")
        let expected = String(repeating: "ab", count: 32)
        do {
            _ = try await RuntimeInstaller.fetch(pinned(source, sha: expected), into: cache)
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("tool.dll"))
            #expect(error.localizedDescription.contains("checksum"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }

    @Test func aTamperedCachedFileIsReplacedByAGoodDownload() async throws {
        let tmp = TempFolder()
        let source = tmp.file("server/tool.dll", contents: Data("good".utf8))
        let sha = try Files.sha256(of: source)
        let cache = tmp.url.appendingPathComponent("cache")
        tmp.file("cache/tool.dll", contents: Data("tampered".utf8))
        let file = try await RuntimeInstaller.fetch(pinned(source, sha: sha), into: cache)
        #expect(try Data(contentsOf: file) == Data("good".utf8))
    }

    @Test func aTamperedCachedFileWithNoGoodDownloadIsDeleted() async throws {
        let tmp = TempFolder()
        let source = tmp.file("server/tool.dll", contents: Data("still wrong".utf8))
        let cache = tmp.url.appendingPathComponent("cache")
        tmp.file("cache/tool.dll", contents: Data("tampered".utf8))
        await #expect(throws: ShellError.self) {
            _ = try await RuntimeInstaller.fetch(self.pinned(source, sha: String(repeating: "0", count: 64)), into: cache)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }
}

private final class CallCounter: @unchecked Sendable {
    var count = 0
}

// MARK: Winetricks

@Suite struct WinetricksTests {
    @Test func theEnvironmentIsWhatWinetricksNeedsOnAMac() {
        let s = Space(name: "Main", path: "/tmp/Main", engineID: "x", origin: .managed)
        let shims = URL(fileURLWithPath: "/app/Resources/shims")
        let cache = URL(fileURLWithPath: "/lib/Downloads/components/winetricks-cache")
        let base = ["HOME": "/Users/me", "WINEARCH": "win32", "WINEPREFIX": "/elsewhere", "WINE": "/opt/homebrew/bin/wine",
                    "PATH": "/opt/homebrew/bin:/usr/bin", "SECRET": "x"]
        let env = Winetricks.environment(engine: fakeEngine(), space: s, shims: shims, cache: cache, base: base)

        #expect(env["WINEPREFIX"] == "/tmp/Main")
        #expect(env["PATH"] == "/app/Resources/shims:/tmp/engine/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["WINE"] == "wine" && env["WINESERVER"] == "wineserver")
        #expect(env["GPLAYER_WINE"] == "/tmp/engine/wine/bin/wine")
        #expect(env["GPLAYER_WINESERVER"] == "/tmp/engine/wine/bin/wineserver")
        #expect(env["WINE_BIN"] == "/tmp/engine/wine/bin/wine" && env["WINESERVER_BIN"] == "/tmp/engine/wine/bin/wineserver")
        #expect(env["WINEARCH"] == nil)
        #expect(env["W_CACHE"] == cache.path && env["XDG_CACHE_HOME"] == cache.path)
        #expect(env["WINETRICKS_LATEST_VERSION_CHECK"] == "disabled")
        #expect(env["WINETRICKS_DOWNLOADER"] == "curl")
        #expect(env["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d")
        #expect(env["HOME"] == "/Users/me")
        #expect(env["SECRET"] == nil)                                    // nothing else leaks in
    }

    @Test func eachRunGetsItsOwnTemporaryFolder() {
        let s = Space(name: "Main", path: "/tmp/Main", engineID: "x", origin: .managed)
        let shims = URL(fileURLWithPath: "/app/Resources/shims"), cache = URL(fileURLWithPath: "/lib/cache")
        let scratch = URL(fileURLWithPath: "/lib/Downloads/components/tmp-1234")
        let withIt = Winetricks.environment(engine: fakeEngine(), space: s, shims: shims, cache: cache, temporary: scratch,
                                            base: ["TMPDIR": "/var/folders/shared/T/"])
        #expect(withIt["TMPDIR"] == scratch.path)
        let without = Winetricks.environment(engine: fakeEngine(), space: s, shims: shims, cache: cache,
                                             base: ["TMPDIR": "/var/folders/shared/T/"])
        #expect(without["TMPDIR"] == "/var/folders/shared/T/")
    }

    @Test func theCommandLineIsUnattendedAndStaysOffTheNetworkLookups() {
        let args = Winetricks.arguments(script: URL(fileURLWithPath: "/lib/Engines/tools/winetricks-gplayer"), verb: "d3dx9")
        #expect(args == ["/lib/Engines/tools/winetricks-gplayer", "--country=unknown", "--optout", "-q", "d3dx9"])
    }

    @Test func onlyVerbsAreAccepted() {
        for ok in ["d3dx9", "vcrun2022", "dotnet48", "d3dx11_43", "win10", "msxml3", "xact_x64", "ie6", "vcrun2008", "d3dcompiler_47"] {
            #expect(Winetricks.isVerb(ok), "\(ok)")
        }
        for bad in ["", "-q", "--self-update", "annihilate", "list", "list-installed", "shell", "winecfg", "regedit",
                    "prefix=foo", "arch=32", "mine.verb", "../x", "/bin/sh", "a b", "a;b", "$(x)", "dlls", "über"] {
            #expect(!Winetricks.isVerb(bad), "\(bad)")
        }
    }

    @Test func commandsAndCategoriesAreNotVerbs() {
        // Winetricks' own commands and menus: some delete the space, some open programs, one would list for ever.
        for command in ["apps", "benchmarks", "dlls", "fonts", "games", "settings", "prefix", "mkprefix", "main", "help",
                        "list", "list-all", "list-cached", "list-download", "list-manual-download", "list-installed", "listing",
                        "unattended", "attended", "annihilate", "reinstall", "folder", "winecfg", "regedit", "taskmgr",
                        "explorer", "uninstaller", "shell", "winecmd", "wine_misc_exe", "die", "arch"] {
            #expect(!Winetricks.isVerb(command), "\(command)")
            #expect(!Winetricks.isVerb(command.uppercased()), "\(command.uppercased())")
        }
    }

    @Test func settingsAndPatternsAreNotVerbs() {
        // `name=value` verbs are settings, not installs; the rest could be read as a path, a pattern or an option.
        for bad in ["vd=1280x720", "hidewineexports=enable", "sound=alsa", "win7=1", "d3dx9*", "*", "d3d?", "a/b", "/abs", "a..b",
                    "..", "-x", "--optout", "-", " d3dx9", "d3dx9 ", "d3dx9\n", "d3dx9\t", "d3dx9\u{0}", "a\"b", "a'b", "a\\b",
                    "x.VERB", String(repeating: "a", count: 65)] {
            #expect(!Winetricks.isVerb(bad), "\(bad.debugDescription)")
        }
        #expect(Winetricks.isVerb(String(repeating: "a", count: 64)))
    }

    // The two lines are copied from winetricks 20260125.
    private let askLine = #"            w_askpermission "SHA256 mismatch!\n\nURL: ${_W_url}\nDownloaded: ${_W_gotsha256sum}\n\nContinue anyway?""#
    private let noSumLine = #"        0) _W_shatype="none" ;;"#

    @Test func theTwoSafetyEditsApplyOnce() throws {
        let script = "head\n\(askLine)\nmiddle\n\(noSumLine)\n        64) _W_shatype=\"sha256\" ;;\ntail\n"
        let edited = try #require(Winetricks.hardened(script))
        #expect(edited.contains(#"w_die "SHA256 mismatch!"#))
        #expect(!edited.contains("w_askpermission"))
        #expect(edited.contains(#"0) w_die "No SHA-256 checksum for ${_W_url:-a download}."#))
        #expect(!edited.contains(#"_W_shatype="none""#))
        #expect(edited.contains(#"64) _W_shatype="sha256" ;;"#))          // the rest is untouched
    }

    @Test func aScriptThatIsNotThePinnedOneIsRefused() {
        #expect(Winetricks.hardened("echo hello\n") == nil)
        #expect(Winetricks.hardened("\(askLine)\n") == nil)                // second line missing
        #expect(Winetricks.hardened("\(askLine)\n\(askLine)\n\(noSumLine)\n") == nil)   // a line twice
    }

    @Test func outputBecomesShortStatus() {
        #expect(Winetricks.progressMessage(forLine: "Downloading https://example.com/a/b/directx_Jun2010_redist.exe to /x/y", verb: "d3dx9")
                == "Downloading directx_Jun2010_redist.exe")
        #expect(Winetricks.progressMessage(forLine: "Executing wine C:\\windows\\regedit.exe /S x.reg", verb: "d3dx9") == "Installing d3dx9")
        #expect(Winetricks.progressMessage(forLine: "Executing cabextract -q -d /x -L -F *d3dx9* /y", verb: "d3dx9") == "Unpacking d3dx9")
        #expect(Winetricks.progressMessage(forLine: "Using native override for following DLLs: d3dx9_24", verb: "d3dx9") == nil)
    }

    @Test func failuresSayWhatHappened() {
        let mismatch = Winetricks.failureReason(output: "warning: SHA256 mismatch!\n\nURL: x", status: 1, logName: "w.log")
        #expect(mismatch.contains("checksum") && mismatch.contains("w.log"))
        let noSum = Winetricks.failureReason(output: "warning: No SHA-256 checksum for https://x/y.exe. G-Player only", status: 1, logName: "w.log")
        #expect(noSum.contains("no checksum"))
        let other = Winetricks.failureReason(output: "Executing wine setup.exe\nwarning: Note: command wine setup.exe returned status 5. Aborting.", status: 1, logName: "w.log")
        #expect(other.contains("code 1") && other.contains("returned status 5") && other.contains("w.log"))
    }
}

// MARK: Shims

/// A cabinet with no compression (macOS has no CAB writer, and this format is simple enough to write by hand).
private func makeCab(_ files: [(name: String, data: Data)]) -> Data {
    func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    func le32(_ v: Int) -> Data { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }

    var entries = Data(), body = Data()
    for file in files {
        entries += le32(file.data.count) + le32(body.count) + le16(0) + le16(0x5821) + le16(0) + le16(0x20)
            + Data(file.name.utf8) + Data([0])
        body += file.data
    }
    var blocks = Data()
    var chunkStart = body.startIndex
    var chunkCount = 0
    while chunkStart < body.endIndex {
        let chunk = body[chunkStart..<min(chunkStart + 32768, body.endIndex)]
        blocks += le32(0) + le16(chunk.count) + le16(chunk.count) + chunk
        chunkStart += chunk.count; chunkCount += 1
    }
    let filesAt = 36 + 8, dataAt = filesAt + entries.count, total = dataAt + blocks.count
    var cab = Data("MSCF".utf8) + le32(0) + le32(total) + le32(0) + le32(filesAt) + le32(0)
    cab += Data([3, 1]) + le16(1) + le16(files.count) + le16(0) + le16(0x1234) + le16(0)
    cab += le32(dataAt) + le16(chunkCount) + le16(0)
    return cab + entries + blocks
}

@Suite struct ShimTests {
    static let shims = CoreResources.url("shims")

    private func shim(_ name: String) throws -> URL {
        try #require(Self.shims, "Resources/shims is missing").appendingPathComponent(name)
    }

    private func run(_ name: String, _ arguments: [String], in folder: URL? = nil,
                     environment: [String: String] = [:]) async throws -> ProcessResult {
        try await Shell.run(shim(name), arguments, environment: ["PATH": "/usr/bin:/bin"].merging(environment) { $1 },
                            currentDirectory: folder)
    }

    /// Files under `folder`, as paths relative to it.
    private func contents(_ folder: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !Files.isDirectory(folder.appendingPathComponent($0)) }.sorted()
    }

    @Test func everyShimIsThereAndRunnable() throws {
        for name in ["cabextract", "lipo", "wine", "wineserver"] {
            #expect(FileManager.default.isExecutableFile(atPath: try shim(name).path), "\(name)")
        }
    }

    // MARK: cabextract

    private let dll = Data(repeating: 0x4D, count: 70_000)           // more than one CFDATA block
    private var cab: Data { makeCab([("Msvcp140.DLL_x86", dll), ("readme.txt", Data("hi".utf8)), ("sub\\Other.dll", Data("o".utf8))]) }

    @Test func extractsAPlainCabinetIntoAFolderThatDoesNotExistYet() async throws {
        let tmp = TempFolder()
        let file = tmp.file("a.cab", contents: cab)
        let r = try await run("cabextract", ["-q", "-d", "out/deep", file.path], in: tmp.url)
        #expect(r.succeeded, "\(r.stderr)")
        #expect(contents(tmp.url.appendingPathComponent("out/deep")) == ["Msvcp140.DLL_x86", "readme.txt", "sub/Other.dll"])
        #expect(try Data(contentsOf: tmp.url.appendingPathComponent("out/deep/Msvcp140.DLL_x86")) == dll)
    }

    @Test func lowercaseAndTheFilterWorkTheWayWinetricksUsesThem() async throws {
        let tmp = TempFolder()
        let file = tmp.file("a.cab", contents: cab)
        // winetricks: cabextract -d DIR -L -F 'msvcp*' FILE, and --directory=DIR with -F after the file name.
        let a = try await run("cabextract", ["-d", "one", "-L", "-F", "MSVCP*", file.path], in: tmp.url)
        #expect(a.succeeded)
        #expect(contents(tmp.url.appendingPathComponent("one")) == ["msvcp140.dll_x86"])
        let b = try await run("cabextract", ["--directory=two", file.path, "-F", "*.TXT"], in: tmp.url)
        #expect(b.succeeded)
        #expect(contents(tmp.url.appendingPathComponent("two")) == ["readme.txt"])
        let c = try await run("cabextract", ["--filter=sub/*", "--directory", "three", "-L", file.path], in: tmp.url)
        #expect(c.succeeded)
        #expect(contents(tmp.url.appendingPathComponent("three")) == ["sub/other.dll"])
    }

    @Test func aPatternMatchesTheWholeNameAndNothingMatchingIsNotAnError() async throws {
        let tmp = TempFolder()
        let file = tmp.file("a.cab", contents: cab)
        let r = try await run("cabextract", ["-q", "-d", "out", "-F", "msvcp140.dll", file.path], in: tmp.url)   // the name ends in _x86
        #expect(r.succeeded)
        #expect(contents(tmp.url.appendingPathComponent("out")).isEmpty)
    }

    @Test func findsEveryCabinetInsideASetupProgram() async throws {
        let tmp = TempFolder()
        // A PE-looking stub, a bogus "MSCF" that isn't a header, a cabinet, padding, a second cabinet, a trailer.
        let exe = Data("MZ".utf8) + Data(repeating: 0x90, count: 5000) + Data("MSCF-not-a-cabinet".utf8) + Data(repeating: 0, count: 40)
            + makeCab([("0", Data("ux".utf8)), ("u1", Data("ux1".utf8))]) + Data(repeating: 0xEE, count: 777)
            + makeCab([("a10", Data("payload".utf8))]) + Data(repeating: 0xEE, count: 99)
        let file = tmp.file("setup.exe", contents: exe)
        let r = try await run("cabextract", ["-q", "-d", "out", file.path], in: tmp.url)
        #expect(r.succeeded, "\(r.stderr)")
        #expect(contents(tmp.url.appendingPathComponent("out")) == ["0", "a10", "u1"])
        #expect(try String(contentsOf: tmp.url.appendingPathComponent("out/a10"), encoding: .utf8) == "payload")

        let only = try await run("cabextract", ["-q", "-d", "just", file.path, "-F", "a10"], in: tmp.url)
        #expect(only.succeeded)
        #expect(contents(tmp.url.appendingPathComponent("just")) == ["a10"])
    }

    @Test func aCabinetWithTrailingBytesStillOpens() async throws {
        let tmp = TempFolder()
        let file = tmp.file("a.cab", contents: cab + Data(repeating: 0, count: 1234))
        let r = try await run("cabextract", ["-q", "-d", "out", "-F", "readme.txt", file.path], in: tmp.url)
        #expect(r.succeeded)
        #expect(contents(tmp.url.appendingPathComponent("out")) == ["readme.txt"])
    }

    @Test func problemsGiveAMessageAndFailure() async throws {
        let tmp = TempFolder()
        let junk = tmp.file("junk.bin", bytes: 3000)
        let notACab = try await run("cabextract", ["-d", "out", junk.path], in: tmp.url)
        #expect(!notACab.succeeded && notACab.stderr.contains("no valid cabinets"))
        let missing = try await run("cabextract", ["-d", "out", "nothing.cab"], in: tmp.url)
        #expect(!missing.succeeded && missing.stderr.contains("no such file"))
        #expect(try await run("cabextract", [], in: tmp.url).succeeded == false)
        #expect(try await run("cabextract", ["--frobnicate", junk.path], in: tmp.url).succeeded == false)
        #expect(try await run("cabextract", ["-q", "-v"], in: tmp.url).succeeded)    // winetricks asks for the version
    }

    // MARK: The others

    @Test func lipoAnswersLikeLipoWithoutTheCommandLineTools() async throws {
        let thin = try await run("lipo", ["-archs", "/bin/sh"])
        #expect(thin.succeeded && thin.stdout.contains("x86_64"), "\(thin.stdout) \(thin.stderr)")
        let tmp = TempFolder()
        let script = tmp.file("s.sh", contents: Data("#!/bin/sh\n".utf8))
        #expect(try await run("lipo", ["-archs", script.path]).succeeded == false)
        #expect(try await run("lipo", ["-info", "/bin/sh"]).succeeded == false)
    }

    @Test func wineShimsNeedTheEnginePathAndGoThroughRosetta() async throws {
        #expect(try await run("wine", ["--version"]).succeeded == false)
        #expect(try await run("wineserver", ["-w"]).succeeded == false)
        for name in ["wine", "wineserver"] {
            let text = try String(contentsOf: shim(name), encoding: .utf8)
            #expect(text.contains("exec /usr/bin/arch -x86_64"), "\(name)")
        }
        if await Shell.isRosettaInstalled() {
            let r = try await run("wine", ["from the shim"], environment: ["GPLAYER_WINE": "/bin/echo"])
            #expect(r.stdout == "from the shim\n", "\(r.stdout) \(r.stderr)")
        }
    }
}
