import Foundation
import Testing
@testable import GPlayerCore

// Epic Games through Legendary: the command lines, what its output says, how sign-in codes are read, and the runner with a
// stand-in program (a shell script) in place of the real one. The JSON below has the shapes of Legendary 0.21.1's own
// output (`status --offline --json`, `list-installed --json`, `launch --json`), with made-up games.

private let sampleLaunch = """
{"game_parameters": ["-nosplash"], "game_executable": "Bin/Sample.exe", "game_directory": "/Users/me/Games/G-Player/Spaces/Epic Games/drive_c/Games/Epic/SampleGame", \
"egl_parameters": ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=0123456789abcdef0123456789abcdef", "-AUTH_TYPE=exchangecode", "-epicapp=SampleApp", "-epicenv=Prod", "-EpicPortal", "-epicusername=Sample Player", "-epicuserid=00ff", "-epiclocale=en", "-epicsandboxid=ns1"], \
"launch_command": ["/engine/bin/wine"], "working_directory": "/Users/me/Games/G-Player/Spaces/Epic Games/drive_c/Games/Epic/SampleGame/Bin", \
"user_parameters": [], "environment": {"CX_BOTTLE": "Legendary", "SAMPLE_FLAG": "1"}, "pre_launch_command": "", "pre_launch_wait": false}
"""

private let sampleInstalled = """
[{"app_name": "SampleApp", "install_path": "/Users/me/Games/Epic/SampleGame", "title": "Sample Game", "version": "1.2.3", "base_urls": [], \
"can_run_offline": true, "egl_guid": "", "executable": "Bin\\\\Sample.exe", "install_size": 123456789, "install_tags": [], "is_dlc": false, \
"launch_parameters": "", "manifest_path": "", "needs_verification": false, "platform": "Windows", "prereq_info": null, "uninstaller": null, \
"requires_ot": false, "save_path": null, "is_preloaded": false},
{"app_name": "SampleAddon", "install_path": "/Users/me/Games/Epic/SampleGame", "title": "Sample Add-on", "version": "1", "executable": "", \
"install_size": 5, "is_dlc": true, "platform": "Windows"}]
"""

// MARK: Pinned download

@Suite struct LegendaryPinTests {
    @Test func theDownloadIsThePinnedRelease() {
        let pin = Legendary.download
        #expect(pin.url.absoluteString == "https://github.com/legendary-gl/legendary/releases/download/0.21.1/legendary_macOS_arm64")
        #expect(pin.sha256 == "d87978321dba9cb731fab40c72f0a30bed55baca8b5341ab21024c5733cd837e")
        #expect(pin.approximateBytes == 15_275_984)
        #expect(Legendary.version == "0.21.1")
    }

    @Test func itLivesInTheLibrariesToolsFolder() {
        let paths = LibraryPaths(root: URL(fileURLWithPath: "/Users/me/Games/G-Player"))
        let legendary = Legendary(paths: paths)
        #expect(legendary.executable.path == "/Users/me/Games/G-Player/Tools/legendary-0.21.1/legendary")
        #expect(legendary.configFolder.path == "/Users/me/Games/G-Player/Tools/legendary-config")
    }

    @Test func aDownloadThatNeverEndedIsALeftover() throws {
        let tmp = TempFolder()
        let paths = LibraryPaths(root: tmp.url)
        let folder = Legendary(paths: paths).toolFolder
        tmp.file("Tools/legendary-0.21.1/legendary")
        tmp.file("Tools/legendary-0.21.1/legendary.1A2B3C4D.part")
        tmp.file("Tools/legendary-0.21.1/legendary.1A2B3C4D")
        Leftovers.clean(paths, processes: [])
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["legendary"])
    }
}

// MARK: Command lines

@Suite struct LegendaryCommandTests {
    @Test func globalFlagsComeBeforeTheSubcommand() {
        let all = [LegendaryCommand.status, LegendaryCommand.signOut, LegendaryCommand.library, LegendaryCommand.installed,
                   LegendaryCommand.signIn(code: "x"), LegendaryCommand.uninstall(appName: "A"),
                   LegendaryCommand.install(appName: "A", basePath: URL(fileURLWithPath: "/b")),
                   LegendaryCommand.launch(appName: "A", wine: URL(fileURLWithPath: "/w"), offline: false)]
        for command in all {
            #expect(command.first == "-y", "\(command)")
            #expect(!command.dropFirst(2).contains("-y"), "\(command)")
        }
    }

    @Test func statusIsAskedOfThisMacOnly() {
        #expect(LegendaryCommand.status == ["-y", "status", "--offline", "--json"])
    }

    @Test func theLibraryIsAskedForWindows() {
        #expect(LegendaryCommand.library == ["-y", "list", "--platform", "Windows", "--json"])
        #expect(LegendaryCommand.installed == ["-y", "list-installed", "--json"])
    }

    @Test func aCodeIsTheArgumentOfSignInAndOfNothingElse() {
        #expect(LegendaryCommand.signIn(code: "abc") == ["-y", "auth", "--code", "abc"])
        #expect(LegendaryCommand.signOut == ["-y", "auth", "--delete"])
    }

    @Test func installTakesWindowsAndNeverAsks() {
        let command = LegendaryCommand.install(appName: "SampleApp", basePath: URL(fileURLWithPath: "/lib/Spaces/Epic Games/drive_c/Games/Epic"))
        #expect(command == ["-y", "install", "SampleApp", "--platform", "Windows", "--base-path",
                            "/lib/Spaces/Epic Games/drive_c/Games/Epic", "--skip-sdl", "--skip-dlcs"])
    }

    @Test func launchAlwaysNamesTheWineAndOnlyAsksOnlineWhenOnline() {
        let wine = URL(fileURLWithPath: "/engine/bin/wine")
        let online = LegendaryCommand.launch(appName: "SampleApp", wine: wine, offline: false)
        #expect(online == ["-y", "launch", "SampleApp", "--json", "--wine", "/engine/bin/wine", "--skip-version-check"])
        #expect(LegendaryCommand.launch(appName: "SampleApp", wine: wine, offline: true) == online + ["--offline"])
    }

    @Test func aNameThatCouldBeAnOptionIsNotAnAppName() {
        #expect(LegendaryCommand.isAppName("SampleApp"))
        #expect(LegendaryCommand.isAppName("0123456789abcdef0123456789abcdef"))
        #expect(LegendaryCommand.isAppName("Sample_App-2.0"))
        for bad in ["", "-y", "--json", "a b", "a/b", "a;b", "é", String(repeating: "a", count: 101)] {
            #expect(!LegendaryCommand.isAppName(bad), "\(bad)")
        }
    }
}

// MARK: Settings

@Suite struct LegendarySettingsTests {
    private let settings = ["default_platform = Windows", "disable_auto_crossover = true", "disable_update_check = true"]

    @Test func aNewFileHasTheSettings() {
        let text = Legendary.config(updating: nil)
        #expect(text == "[Legendary]\n" + settings.joined(separator: "\n") + "\n")
        #expect(Legendary.config(updating: "") == text)
    }

    @Test func settingsAreCorrectedAndEverythingElseStays() {
        let existing = """
        [Legendary]
        default_platform = Mac
        log_level = debug
        disable_update_check = false

        [SampleApp]
        install_tags = voice_en
        default_platform = Mac

        """
        let text = Legendary.config(updating: existing)
        #expect(text.contains("default_platform = Windows\n"))
        #expect(text.contains("log_level = debug\n"))
        #expect(text.contains("disable_update_check = true\n"))
        #expect(text.contains("disable_auto_crossover = true\n"))
        // The other section is untouched, even for a key with the same name.
        #expect(text.contains("[SampleApp]\ninstall_tags = voice_en\ndefault_platform = Mac\n"))
        #expect(!text.contains("disable_update_check = false") && !text.contains("default_platform = Mac\nlog_level"))
    }

    @Test func aFileWithoutTheSectionGetsIt() {
        let text = Legendary.config(updating: "[SampleApp]\ninstall_tags = x\n")
        #expect(text == "[SampleApp]\ninstall_tags = x\n\n[Legendary]\n" + settings.joined(separator: "\n") + "\n")
    }

    @Test func applyingTwiceChangesNothing() {
        let once = Legendary.config(updating: "[Legendary]\nlog_level = debug\n")
        #expect(Legendary.config(updating: once) == once)
    }

    @Test func theEnvironmentHoldsNothingThatSendsTheGameElsewhere() {
        let base = ["HOME": "/Users/me", "TMPDIR": "/tmp/x/", "LANG": "en_US.UTF-8", "CX_BOTTLE": "Other", "WINEPREFIX": "/elsewhere",
                    "WINEDLLOVERRIDES": "x=n", "https_proxy": "http://proxy:3128", "SECRET_TOKEN": "s"]
        let env = Legendary.environment(configFolder: URL(fileURLWithPath: "/lib/Tools/legendary-config"), base: base)
        #expect(env["LEGENDARY_CONFIG_PATH"] == "/lib/Tools/legendary-config")
        #expect(env["HOME"] == "/Users/me" && env["https_proxy"] == "http://proxy:3128")
        for name in ["CX_BOTTLE", "WINEPREFIX", "WINEDLLOVERRIDES", "SECRET_TOKEN"] { #expect(env[name] == nil, "\(name)") }
    }
}

// MARK: Reading Legendary's output

@Suite struct LegendaryOutputTests {
    @Test func statusSaysWhoIsSignedIn() {
        #expect(LegendaryOutput.status(#"{"account": "Sample Player", "games_available": 3, "games_installed": 1, "egl_sync_enabled": false, "config_directory": "/x"}"#)
                == LegendaryStatus(account: "Sample Player"))
        let out = LegendaryOutput.status(#"{"account": "<not logged in>", "games_available": 0}"#)
        #expect(out == LegendaryStatus(account: nil) && out?.isSignedIn == false)
        #expect(LegendaryOutput.status(#"{"account": ""}"#)?.isSignedIn == false)
        #expect(LegendaryOutput.status("Traceback (most recent call last):") == nil)
        #expect(LegendaryOutput.status("{}") == nil)
    }

    @Test func aLogLineBeforeTheJSONIsSkipped() {
        let out = LegendaryOutput.status("[cli] INFO: something\n{\"account\": \"Sample Player\"}\n")
        #expect(out?.account == "Sample Player")
    }

    private let library = """
    [{"app_name": "Zeta", "app_title": "Zeta Game", "asset_infos": {"Windows": {"build_version": "1"}}, "base_urls": [], \
    "metadata": {"id": "c1", "keyImages": [{"type": "Thumbnail", "url": "https://cdn.example/thumb.jpg"}, {"type": "DieselGameBoxTall", "url": "https://cdn.example/tall.jpg"}], \
    "customAttributes": {}}, "dlcs": [{"app_name": "ZetaPack", "app_title": "Zeta Pack"}]},
    {"app_name": "Alpha", "app_title": "alpha game", "metadata": {"keyImages": [{"type": "DieselGameBox", "url": "http://cdn.example/insecure.jpg"}]}},
    {"app_name": "Pack", "app_title": "Pack", "metadata": {"mainGameItem": {"id": "c1"}}},
    {"app_name": "Theirs", "app_title": "Their Game", "metadata": {"customAttributes": {"ThirdPartyManagedApp": {"value": "Origin"}}}},
    {"app_name": "-bad", "app_title": "Bad"},
    {"app_name": "Alpha", "app_title": "Duplicate"},
    {"app_name": "NoTitle"}]
    """

    @Test func theLibraryKeepsGamesByTitleWithTheirBoxArt() throws {
        let games = try #require(LegendaryOutput.library(library))
        #expect(games.map(\.appName) == ["Alpha", "NoTitle", "Zeta"])
        #expect(games.map(\.title) == ["alpha game", "NoTitle", "Zeta Game"])
        #expect(games.last?.coverURL?.absoluteString == "https://cdn.example/tall.jpg")      // the tall box, not the thumbnail
        #expect(games.first?.coverURL == nil)                                                // only https art is used
    }

    @Test func addOnsAndGamesAnotherStoreInstallsAreNotOffered() throws {
        let names = try #require(LegendaryOutput.library(library)).map(\.appName)
        #expect(!names.contains("Pack") && !names.contains("Theirs") && !names.contains("ZetaPack"))
    }

    @Test func anAnswerThatIsNotAListGivesNothing() {
        #expect(LegendaryOutput.library("") == nil)
        #expect(LegendaryOutput.library("Traceback ...") == nil)
        #expect(LegendaryOutput.library(#"{"a": 1}"#) == nil)
        #expect(LegendaryOutput.library("[]") == [])
    }

    @Test func installedGamesHaveAProgramOnTheMac() throws {
        let games = try #require(LegendaryOutput.installed(sampleInstalled))
        #expect(games.map(\.appName) == ["SampleApp"])                                       // the add-on is left out
        let game = games[0]
        #expect(game.title == "Sample Game" && game.version == "1.2.3" && game.installSize == 123_456_789)
        #expect(game.executableURL?.path == "/Users/me/Games/Epic/SampleGame/Bin/Sample.exe")   // `Bin\Sample.exe` as Epic writes it
    }

    @Test func aProgramThatLeavesTheGamesFolderHasNoURL() {
        for executable in ["../Other/x.exe", "Bin/../../x.exe", "", "..\\x.exe", "./x.exe"] {
            #expect(LegendaryOutput.executableURL(folder: "/g/Game", executable: executable) == nil, "\(executable)")
        }
        #expect(LegendaryOutput.executableURL(folder: "relative", executable: "x.exe") == nil)
        #expect(LegendaryOutput.executableURL(folder: "/g/Game", executable: "/x.exe")?.path == "/g/Game/x.exe")
    }

    @Test func gamesForAnotherPlatformAreNotListed() {
        let json = #"[{"app_name": "MacOnly", "install_path": "/g/M", "executable": "M.app/x", "platform": "Mac"}]"#
        #expect(LegendaryOutput.installed(json) == [])
    }

    @Test func launchParametersKeepWhatTheGameNeedsAndDropWhereWineWouldGo() throws {
        let launch = try #require(LegendaryOutput.launch(sampleLaunch))
        #expect(launch.environment == ["SAMPLE_FLAG": "1"])                                   // no CX_BOTTLE
        #expect(launch.gameParameters == ["-nosplash"] && launch.userParameters == [])
        #expect(launch.eglParameters.contains("-AUTH_PASSWORD=0123456789abcdef0123456789abcdef"))
        #expect(launch.executableURL?.path == "/Users/me/Games/G-Player/Spaces/Epic Games/drive_c/Games/Epic/SampleGame/Bin/Sample.exe")
        #expect(launch.workingDirectoryURL?.path == "/Users/me/Games/G-Player/Spaces/Epic Games/drive_c/Games/Epic/SampleGame/Bin")
    }

    @Test func aPrefixInTheEnvironmentIsDroppedToo() throws {
        let json = #"{"game_directory": "/g", "game_executable": "x.exe", "environment": {"WINEPREFIX": "/elsewhere", "CX_BOTTLE": "b", "A": "1"}}"#
        #expect(try #require(LegendaryOutput.launch(json)).environment == ["A": "1"])
    }

    @Test func theWorkingFolderDefaultsToTheProgramsOwn() throws {
        let json = #"{"game_directory": "/g/Game", "game_executable": "Bin/x.exe"}"#
        #expect(try #require(LegendaryOutput.launch(json)).workingDirectoryURL?.path == "/g/Game/Bin")
    }

    @Test func launchParametersWithoutAProgramAreNothing() {
        #expect(LegendaryOutput.launch("") == nil)
        #expect(LegendaryOutput.launch(#"{"game_directory": "relative", "game_executable": "x.exe"}"#) == nil)
        #expect(LegendaryOutput.launch(#"{"game_directory": "/g"}"#) == nil)
        #expect(LegendaryOutput.launch("[]") == nil)
    }

    @Test func printingLaunchParametersNeverShowsTheCode() throws {
        let launch = try #require(LegendaryOutput.launch(sampleLaunch))
        let text = "\(launch) \(String(describing: launch)) \(String(reflecting: launch))"
        #expect(!text.contains("0123456789abcdef0123456789abcdef"))
        #expect(!text.contains("Sample Player"))
        #expect(text.contains("-AUTH_PASSWORD=<hidden>"))
    }
}

// MARK: Progress

@Suite struct LegendaryInstallStatusTests {
    @Test func aProgressLineGivesTheFractionAndTheTimeLeft() {
        var status = LegendaryInstallStatus()
        #expect(status.message == "Preparing")
        let changed = status.take("[DLManager] INFO: = Progress: 12.34% (123/1000), Running for 00:00:12, ETA: 00:01:23")
        #expect(changed)
        #expect(abs((status.fraction ?? 0) - 0.1234) < 1e-9)
        #expect(status.remaining == 83)
        #expect(status.message == "12% · about 2 min left")
    }

    @Test func theDownloadedLineAddsHowMuchCame() {
        var status = LegendaryInstallStatus()
        status.take("[DLManager] INFO: = Progress: 50.00% (500/1000), Running for 00:10:00, ETA: 01:05:00")
        let changed = status.take("[DLManager] INFO:  - Downloaded: 1024.00 MiB, Written: 1000.00 MiB")
        #expect(changed)
        #expect(status.downloadedBytes == 1_073_741_824)
        #expect(status.message == "50% · \(Int64(1_073_741_824).formattedBytes) · about 1 h 5 min left")
    }

    @Test func otherLinesChangeNothing() {
        var status = LegendaryInstallStatus()
        for line in ["[cli] INFO: Preparing download for \"Sample Game\" (SampleApp)...", "[DLManager] INFO:  - Cache usage: 12.00 MiB, active tasks: 4",
                     "[DLManager] INFO:  + Download\t- 1.00 MiB/s (raw) / 2.00 MiB/s (decompressed)", "", "= Progress: abc% (1/2)"] {
            let changed = status.take(line)
            #expect(!changed, "\(line)")
        }
        #expect(status == LegendaryInstallStatus())
    }

    @Test func anInterruptedDownloadIsRecognisedFromItsLine() {
        #expect(LegendaryInstallStatus.isResuming("[DLManager] INFO: Found previously interrupted download. Download will be resumed if possible."))
        #expect(!LegendaryInstallStatus.isResuming("[cli] INFO: Install size: 1.00 MiB"))
    }

    @Test func theGamesSizeIsReadFromItsLine() {
        #expect(LegendaryInstallStatus.installSize(in: "[cli] INFO: Install size: 1024.00 MiB") == 1_073_741_824)
        #expect(LegendaryInstallStatus.installSize(in: "[cli] INFO: Install size: 20480.50 MiB") == Int64(20480.5 * 1_048_576))
        for line in ["[cli] INFO: Download size: 5.00 MiB (Compression savings: 10.0%)", "Install size: 0.00 MiB", "Install size: abc MiB",
                     "Install size: 5 GiB", ""] {
            #expect(LegendaryInstallStatus.installSize(in: line) == nil, "\(line)")
        }
    }

    @Test func aRepeatedLineIsNotAChange() {
        var status = LegendaryInstallStatus()
        let line = "[DLManager] INFO: = Progress: 1.00% (10/1000), Running for 00:00:01, ETA: 00:01:40"
        let first = status.take(line)
        let second = status.take(line)
        #expect(first && !second)
    }

    @Test func aCompleteDownloadReadsAsOneHundredPercent() {
        var status = LegendaryInstallStatus()
        status.take("= Progress: 100.00% (1000/1000), Running for 00:30:00, ETA: 00:00:00")
        #expect(status.fraction == 1)
        #expect(status.message == "100% · under a minute left")
    }

    @Test func timesAreSaidInMinutesAndHours() {
        #expect(LegendaryInstallStatus.duration(5) == "under a minute")
        #expect(LegendaryInstallStatus.duration(61) == "about 2 min")
        #expect(LegendaryInstallStatus.duration(59 * 60) == "about 59 min")
        #expect(LegendaryInstallStatus.duration(3600) == "about 1 h")
        #expect(LegendaryInstallStatus.duration(3600 + 20 * 60) == "about 1 h 20 min")
    }
}

// MARK: Why it failed

@Suite struct LegendaryFailureTests {
    private let signedOut = """
    [cli] INFO: Logging in...
    Traceback (most recent call last):
      File "cli.py", line 212, in list_games
    ValueError: No saved credentials
    [PYI-8176:ERROR] Failed to execute script 'cli' due to unhandled exception!
    """

    @Test func noLoginMeansSignIn() {
        #expect(LegendaryFailure.kind(stderr: signedOut) == .signedOut)
        #expect(LegendaryFailure.reason(stdout: "", stderr: signedOut, status: 1) == LegendaryFailure.signedOutMessage)
        let expired = "[Core] ERROR: Stored credentials are no longer valid! Please login again.\n[cli] ERROR: Login failed, cannot continue!"
        #expect(LegendaryFailure.kind(stderr: expired) == .signedOut)
    }

    @Test func anInstallElsewhereMeansWait() {
        let text = "[cli] CRITICAL: Failed to acquire installed data lock, only one instance of Legendary may install/import/move applications at a time."
        #expect(LegendaryFailure.kind(stderr: text) == .busy)
    }

    @Test func noNetworkIsSaidSo() {
        let text = "requests.exceptions.ConnectionError: HTTPSConnectionPool(host='api.legendary.gl', port=443): Max retries exceeded"
        #expect(LegendaryFailure.kind(stderr: text) == .network)
        #expect(LegendaryFailure.reason(stdout: "", stderr: "[Core] ERROR: HTTP request for login failed: x", status: 1).hasPrefix("Couldn't connect"))
    }

    @Test func legendarysOwnExplanationIsUsed() {
        let stderr = "[cli] INFO: Logging in...\n[cli] ERROR: Game Sample is not currently installed!\n"
        #expect(LegendaryFailure.reason(stdout: "", stderr: stderr, status: 1) == "Game Sample is not currently installed! (Legendary code 1)")
    }

    @Test func aFailedCheckOnTheDiskIsUsed() {
        let stdout = "\nInstallation requirements check returned the following results:\n ! Failure: Not enough available disk space! Available: 1.00 GiB, Required: 20.00 GiB\n"
        let stderr = "[cli] FATAL: Installation cannot proceed, exiting."
        // The check that failed says more than the line that ends the run.
        #expect(LegendaryFailure.reason(stdout: stdout, stderr: stderr, status: 1)
                == "Not enough available disk space! Available: 1.00 GiB, Required: 20.00 GiB (Legendary code 1)")
        #expect(LegendaryFailure.reason(stdout: "", stderr: stderr, status: 1).hasPrefix("Installation cannot proceed"))
    }

    @Test func aTracebackIsReducedToItsException() {
        let stderr = "Traceback (most recent call last):\n  File \"x.py\", line 1, in <module>\nTypeError: argument of type 'NoneType' is not a container or iterable\n[PYI-1:ERROR] Failed"
        #expect(LegendaryFailure.reason(stdout: "", stderr: stderr, status: 1).hasPrefix("TypeError: argument of type"))
    }

    @Test func nothingToSayIsSaidPlainly() {
        #expect(LegendaryFailure.reason(stdout: "", stderr: "", status: 7) == "Legendary stopped with code 7.")
    }

    @Test func aCodeInTheOutputIsHidden() {
        let stderr = "[cli] ERROR: could not run: Bin/x.exe -AUTH_LOGIN=unused -AUTH_PASSWORD=0123456789abcdef0123456789abcdef -epicapp=A"
        let reason = LegendaryFailure.reason(stdout: "", stderr: stderr, status: 1)
        #expect(!reason.contains("0123456789abcdef"))
        #expect(reason.contains("-AUTH_PASSWORD=<hidden>"))
    }
}

// MARK: The runner, with a stand-in program

@Suite struct LegendaryRunnerTests {
    let tmp = TempFolder()
    var paths: LibraryPaths { LibraryPaths(root: tmp.url.appendingPathComponent("Library")) }

    /// A shell script in place of Legendary. It writes the arguments, the environment and what reading stdin gives (1 is the end
    /// of the file, as on /dev/null; 142 would be a stdin nobody closed) to files in `trace`.
    private func stand(in body: String) throws -> Legendary {
        let trace = tmp.dir("trace")
        let script = """
        #!/bin/bash
        printf '%s\\n' "$@" >> '\(trace.path)/args.txt'
        printf -- '--call--\\n' >> '\(trace.path)/args.txt'
        env > '\(trace.path)/env.txt'
        read -r -t 1 _line; echo $? > '\(trace.path)/stdin.txt'
        \(body)
        """
        let file = tmp.file("stand/legendary", contents: Data(script.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return Legendary(paths: paths, executable: file)
    }

    private func trace(_ name: String) -> String { (try? String(contentsOf: tmp.url.appendingPathComponent("trace/\(name)"), encoding: .utf8)) ?? "" }
    private func calls() -> [[String]] {
        trace("args.txt").components(separatedBy: "--call--\n").filter { !$0.isEmpty }
            .map { $0.split(separator: "\n").map(String.init) }
    }

    @Test func itRunsWithItsOwnSettingsFolderAndNoStdin() async throws {
        let legendary = try stand(in: "echo '{\"account\": \"Sample Player\"}'")
        let status = try await legendary.status()
        #expect(status.account == "Sample Player")
        #expect(trace("stdin.txt").trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        let env = trace("env.txt")
        #expect(env.contains("LEGENDARY_CONFIG_PATH=\(legendary.configFolder.path)"))
        #expect(!env.contains("CX_BOTTLE") && !env.contains("WINEPREFIX"))
        #expect(calls() == [["-y", "status", "--offline", "--json"]])
    }

    @Test func theSettingsFolderIsPrivateAndHoldsTheSettings() async throws {
        let legendary = try stand(in: "echo '{\"account\": \"<not logged in>\"}'")
        _ = try await legendary.status()
        let attributes = try FileManager.default.attributesOfItem(atPath: legendary.configFolder.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        let config = try String(contentsOf: legendary.configFolder.appendingPathComponent("config.ini"), encoding: .utf8)
        #expect(config == "[Legendary]\ndefault_platform = Windows\ndisable_auto_crossover = true\ndisable_update_check = true\n")
    }

    @Test func aLooseSettingsFolderIsMadePrivate() async throws {
        let legendary = try stand(in: "echo '{\"account\": \"x\"}'")
        try FileManager.default.createDirectory(at: legendary.configFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        _ = try await legendary.status()
        #expect(((try FileManager.default.attributesOfItem(atPath: legendary.configFolder.path))[.posixPermissions] as? Int) == 0o700)
    }

    @Test func aCommandThatRunsTooLongIsStopped() async throws {
        let legendary = try stand(in: "exec sleep 30")
        let started = Date()
        await #expect(throws: Supervised.TimedOut.self) { _ = try await legendary.run(["-y", "list"], timeout: 0.5) }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func cancellingTheTaskStopsIt() async throws {
        let legendary = try stand(in: "exec sleep 30")
        let task = Task { try await legendary.run(["-y", "install", "A"], timeout: nil) }
        try await Task.sleep(for: .milliseconds(600))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func linesOfStderrComeAsTheyAreWrittenAndGoToTheLog() async throws {
        let legendary = try stand(in: """
        echo '[DLManager] INFO: = Progress: 10.00% (1/10), Running for 00:00:01, ETA: 00:00:09' >&2
        printf '[DLManager] INFO:  - Downloaded: 2.00 MiB, Written: 1.00 MiB\\r' >&2
        echo '[cli] INFO: done' >&2
        """)
        let heard = Lines()
        let log = tmp.url.appendingPathComponent("install.log")
        let result = try await legendary.run(["-y", "install", "A"], timeout: 30, log: log) { heard.add($0) }
        #expect(result.succeeded)
        #expect(heard.all == ["[DLManager] INFO: = Progress: 10.00% (1/10), Running for 00:00:01, ETA: 00:00:09",
                              "[DLManager] INFO:  - Downloaded: 2.00 MiB, Written: 1.00 MiB", "[cli] INFO: done"])
        #expect(try String(contentsOf: log, encoding: .utf8) == heard.all.joined(separator: "\n") + "\n")
        #expect(result.stderr.contains("[cli] INFO: done"))
    }

    @Test func aFailureAndItsExitStatusAreReturned() async throws {
        let legendary = try stand(in: "echo out; echo err >&2; exit 3")
        let result = try await legendary.run(["-y", "list"])
        #expect(result.status == 3 && result.stdout == "out\n" && result.stderr == "err\n")
    }

    @Test func signingInIsDoneWhenTheStatusShowsTheAccount() async throws {
        let legendary = try stand(in: """
        case "$2" in
          auth) echo "[cli] INFO: Successfully logged in" >&2 ;;
          status) echo '{"account": "Sample Player"}' ;;
        esac
        """)
        let status = try await legendary.signIn(code: "0123456789abcdef0123456789abcdef")
        #expect(status.account == "Sample Player")
        #expect(calls() == [["-y", "auth", "--code", "0123456789abcdef0123456789abcdef"], ["-y", "status", "--offline", "--json"]])
    }

    @Test func aRefusedCodeIsAnErrorEvenWhenLegendaryExitsWithZero() async throws {
        let legendary = try stand(in: """
        case "$2" in
          auth) echo "[cli] ERROR: Login attempt failed, please see log for details." >&2 ;;
          status) echo '{"account": "<not logged in>"}' ;;
        esac
        """)
        await #expect(throws: ShellError.self) { _ = try await legendary.signIn(code: "0123456789abcdef0123456789abcdef") }
    }

    @Test func noNetworkWhileSigningInIsSaidSo() async throws {
        let legendary = try stand(in: """
        case "$2" in
          auth) echo "requests.exceptions.ConnectionError: HTTPSConnectionPool(host='api.legendary.gl', port=443): Max retries exceeded" >&2; exit 1 ;;
          status) echo '{"account": "<not logged in>"}' ;;
        esac
        """)
        do {
            _ = try await legendary.signIn(code: "0123456789abcdef0123456789abcdef")
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Couldn't connect"), "\(error)")
        }
    }

    @Test func aCodeThatCouldNotBeOneIsNotSentToLegendary() async throws {
        let legendary = try stand(in: "echo '{\"account\": \"x\"}'")
        await #expect(throws: ShellError.self) { _ = try await legendary.signIn(code: "--delete") }
        #expect(calls().isEmpty)
    }

    @Test func signingOutIsDoneWhenNobodyIsSignedIn() async throws {
        let legendary = try stand(in: """
        case "$2" in
          auth) rm -f '\(tmp.url.path)/signed-in' ;;
          status) if [ -e '\(tmp.url.path)/signed-in' ]; then echo '{"account": "x"}'; else echo '{"account": "<not logged in>"}'; fi ;;
        esac
        """)
        tmp.file("signed-in")
        try await legendary.signOut()
        #expect(calls().first == ["-y", "auth", "--delete"])
    }

    // MARK: Install and uninstall

    @Test func anInstallIsDoneWhenTheGameIsListedAsInstalled() async throws {
        let legendary = try stand(in: """
        case "$2" in
          install) echo '[DLManager] INFO: = Progress: 50.00% (5/10), Running for 00:00:05, ETA: 00:00:05' >&2 ;;
          list-installed) echo '\(sampleInstalled.replacingOccurrences(of: "\n", with: ""))' ;;
        esac
        """)
        let heard = Statuses()
        try await legendary.install("SampleApp", basePath: tmp.url.appendingPathComponent("base")) { heard.add($0) }
        #expect(heard.all.map(\.message) == ["50% · under a minute left"])
        #expect(calls()[0] == ["-y", "install", "SampleApp", "--platform", "Windows", "--base-path",
                               tmp.url.appendingPathComponent("base").path, "--skip-sdl", "--skip-dlcs"])
        #expect(FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("base").path))
    }

    @Test func anInstallThatLegendaryEndedWithZeroButDidNotFinishIsAnError() async throws {
        let legendary = try stand(in: """
        case "$2" in
          install) echo '[cli] WARNING: The following exception occurred while waiting for the downloader to finish: Boom' >&2; echo '[cli] ERROR: Not enough room' >&2 ;;
          list-installed) echo '[]' ;;
        esac
        """)
        do {
            try await legendary.install("SampleApp", basePath: tmp.url.appendingPathComponent("base")) { _ in }
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("Not enough room"), "\(error)")
        }
    }

    @Test func anInstallThatIsStoppedThrowsCancellation() async throws {
        let legendary = try stand(in: "case \"$2\" in install) exec sleep 30 ;; esac")
        let base = tmp.url.appendingPathComponent("base")
        let task = Task { try await legendary.install("SampleApp", basePath: base) { _ in } }
        try await Task.sleep(for: .milliseconds(600))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func anInstallThatWouldNotFitIsStoppedBeforeItDownloads() async throws {
        let legendary = try stand(in: """
        case "$2" in
          install)
            echo '[cli] INFO: Preparing download for "Sample Game" (SampleApp)...' >&2
            echo '[cli] INFO: Install size: 20480.00 MiB' >&2
            exec sleep 30 ;;
        esac
        """)
        let asked = Sizes()
        let started = Date()
        do {
            try await legendary.install("SampleApp", basePath: tmp.url.appendingPathComponent("base"),
                                        hasRoom: { size in asked.add(size); return "It needs \(size.formattedBytes), and the disk is full." }) { _ in }
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "It needs \(Int64(20_480 * 1_048_576).formattedBytes), and the disk is full.", "\(error)")
        }
        #expect(asked.all == [20_480 * 1_048_576])
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(calls().count == 1)                                                       // nothing was listed or checked afterwards
    }

    @Test func anInstallThatGoesOnFromAnEarlierTryIsNotRefusedForItsWholeSize() async throws {
        // 45 of 50 GB came before it was stopped: only the rest has to fit, which Legendary's own check works out.
        let legendary = try stand(in: """
        case "$2" in
          install)
            echo '[DLManager] INFO: Found previously interrupted download. Download will be resumed if possible.' >&2
            echo '[cli] INFO: Install size: 51200.00 MiB' >&2 ;;
          list-installed) echo '\(sampleInstalled.replacingOccurrences(of: "\n", with: ""))' ;;
        esac
        """)
        let asked = Sizes()
        try await legendary.install("SampleApp", basePath: tmp.url.appendingPathComponent("base"),
                                    hasRoom: { asked.add($0); return "No room." }) { _ in }
        #expect(asked.all.isEmpty)
    }

    @Test func anInstallThatFitsGoesOn() async throws {
        let legendary = try stand(in: """
        case "$2" in
          install) echo '[cli] INFO: Install size: 10.00 MiB' >&2 ;;
          list-installed) echo '\(sampleInstalled.replacingOccurrences(of: "\n", with: ""))' ;;
        esac
        """)
        let asked = Sizes()
        try await legendary.install("SampleApp", basePath: tmp.url.appendingPathComponent("base"), hasRoom: { asked.add($0); return nil }) { _ in }
        #expect(asked.all == [10 * 1_048_576])
    }

    @Test func anInstallForSomethingThatIsNotAnAppNameNeverRuns() async throws {
        let legendary = try stand(in: "true")
        await #expect(throws: ShellError.self) { try await legendary.install("--force", basePath: tmp.url) { _ in } }
        #expect(calls().isEmpty)
    }

    @Test func anUninstallIsDoneWhenTheGameIsNoLongerListed() async throws {
        let legendary = try stand(in: """
        case "$2" in
          uninstall) rm -f '\(tmp.url.path)/listed' ;;
          list-installed) if [ -e '\(tmp.url.path)/listed' ]; then echo '\(sampleInstalled.replacingOccurrences(of: "\n", with: ""))'; else echo '[]'; fi ;;
        esac
        """)
        tmp.file("listed")
        try await legendary.uninstall("SampleApp")
        #expect(calls().first == ["-y", "uninstall", "SampleApp"])
    }

    @Test func anUninstallThatLeftTheGameListedIsAnError() async throws {
        let legendary = try stand(in: """
        case "$2" in
          uninstall) echo '[core] ERROR: Deleting failed' >&2 ;;
          list-installed) echo '\(sampleInstalled.replacingOccurrences(of: "\n", with: ""))' ;;
        esac
        """)
        await #expect(throws: ShellError.self) { try await legendary.uninstall("SampleApp") }
    }

    // MARK: Launch

    @Test func launchParametersComeOnlineWhenEpicAnswers() async throws {
        let legendary = try stand(in: "echo '\(sampleLaunch.replacingOccurrences(of: "\n", with: ""))'")
        let launch = try await legendary.launchParameters(for: "SampleApp", wine: URL(fileURLWithPath: "/engine/bin/wine"))
        #expect(launch.environment == ["SAMPLE_FLAG": "1"])
        #expect(calls() == [["-y", "launch", "SampleApp", "--json", "--wine", "/engine/bin/wine", "--skip-version-check"]])
    }

    @Test func withoutTheNetworkTheGameIsAskedForOffline() async throws {
        let legendary = try stand(in: """
        if printf '%s\\n' "$@" | grep -qx -- --offline; then
          echo '\(sampleLaunch.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "0123456789abcdef0123456789abcdef", with: ""))'
        else
          echo '[Core] ERROR: HTTP request for login failed: ConnectionError()' >&2
          echo '[cli] ERROR: Login failed, cannot continue!' >&2
          exit 1
        fi
        """)
        let launch = try await legendary.launchParameters(for: "SampleApp", wine: URL(fileURLWithPath: "/engine/bin/wine"))
        #expect(launch.eglParameters.contains("-AUTH_PASSWORD="))
        let all = calls()
        #expect(all.count == 2 && !all[0].contains("--offline") && all[1].contains("--offline"))
    }

    @Test func aSignedOutAccountIsNotRetriedOffline() async throws {
        let legendary = try stand(in: """
        echo 'ValueError: No saved credentials' >&2
        exit 1
        """)
        do {
            _ = try await legendary.launchParameters(for: "SampleApp", wine: URL(fileURLWithPath: "/engine/bin/wine"))
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == LegendaryFailure.signedOutMessage)
        }
        #expect(calls().count == 1)
    }

    @Test func theCodeIsNeverInAnErrorOrALog() async throws {
        let legendary = try stand(in: """
        echo '\(sampleLaunch.replacingOccurrences(of: "\n", with: ""))'
        echo '[cli] ERROR: dry run: x.exe -AUTH_PASSWORD=0123456789abcdef0123456789abcdef' >&2
        exit 2
        """)
        do {
            _ = try await legendary.launchParameters(for: "SampleApp", wine: URL(fileURLWithPath: "/engine/bin/wine"))
            Issue.record("expected an error")
        } catch {
            #expect(!error.localizedDescription.contains("0123456789abcdef"), "\(error)")
        }
    }

    @Test func ensureInstalledOfAStandInOnlyPreparesTheSettings() async throws {
        let legendary = try stand(in: "true")
        try await legendary.ensureInstalled()
        #expect(FileManager.default.fileExists(atPath: legendary.configFolder.appendingPathComponent("config.ini").path))
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

private final class Sizes: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int64] = []
    func add(_ size: Int64) { lock.lock(); sizes.append(size); lock.unlock() }
    var all: [Int64] { lock.lock(); defer { lock.unlock() }; return sizes }
}

private final class Statuses: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [LegendaryInstallStatus] = []
    func add(_ status: LegendaryInstallStatus) { lock.lock(); statuses.append(status); lock.unlock() }
    var all: [LegendaryInstallStatus] { lock.lock(); defer { lock.unlock() }; return statuses }
}
