# Architecture

```
Sources/
  GPlayerCore/          everything that decides how a Windows program runs (no SwiftUI)
    Model/              Space, SpacePlaces, Game, GraphicsBackend, LibraryState
    Storage/            LibraryPaths (the folders), LibraryStore (library.json)
    Engines/            EngineCatalog (pinned downloads), EngineManager, FileDownloader
    Wine/               WineEnvironment (env + DLL overrides), WineLauncher, SpaceManager,
                        ChromiumHelperWrapper, PrefixPath (how long a prefix path may be),
                        WineProcesses (which programs run where, and the runaway limits)
    Import/             ArchiveExtractor (bsdtar), ExecutableScanner (which .exe is the game),
                        ProgramSnapshot (what an installer added), GameImporter
    Discovery/          VDF + SteamLibrary, EpicLibrary, StoreMerge (keeps the library in line with the
                        stores, hidden state included), ShellLink + ShortcutScanner (.lnk),
                        PEInfo (CPU, .NET, 32-bit warning) + PEIcon (.exe icon → .ico) read from PE headers,
                        EnvironmentFinder (CrossOver/Whisky/~/Games prefixes, old launcher scripts)
    Presets/            AppPreset (Steam, Epic, GOG, Ubisoft), PresetInstaller, LaunchPlanner
    Epic/               Legendary (the runner and its pinned download), LegendaryCommand (command lines),
                        LegendaryOutput / LegendaryInstallStatus / LegendaryFailure (what it prints),
                        EpicSignIn (the code from Epic's sign-in page), EpicGames (space, library merge)
    Resources/          chromium-helper-wrapper.exe (built from tools/)
  GPlayer/              the SwiftUI app
    App/                GPlayerApp, AppModel (state, actions, persistence), SnapshotRenderer (UI to PNGs)
    Views/              Library, AddGame, Spaces, Files, Apps, Settings, Onboarding, Components
Tests/GPlayerCoreTests  unit tests for everything in the core that doesn't need Wine
tools/                  chromium-helper-wrapper (C, cross-compiled with mingw-w64)
scripts/                build-app.sh, release.sh, make-icon.swift, build-wrapper.sh, sparkle-public-key.txt
releases/               zipped builds, one folder per version
```

## Rules

- **The core is testable without Wine.** Decisions (environment, DLL overrides, launch arguments, which .exe
  to pick, what a .lnk points to) are pure functions with tests. Only `WineLauncher`, `SpaceManager` and
  `EngineManager` touch real processes.
- **The UI holds no rules.** Views call `AppModel`, `AppModel` calls the core.
- **Every engine and component download is pinned by SHA-256** (`EngineCatalog`, `RuntimeCatalog`). Store installers come
  straight from the store's own HTTPS address.
- **Never ship Apple's Game Porting Toolkit.** Use the user's own copy.

## The library folder

Chosen on first launch, `~/Games/G-Player` by default:

```
G-Player/
  library.json      spaces, games (a game can be hidden)
  Spaces/<name>/    Wine prefixes G-Player created
  Engines/<id>/     G-Player Wine, DXVK (and Wine Staging, if the user installed it)
  Covers/           cover art and program icons
  Logs/             one log per launch (the command, the DLL overrides, Wine's output)
  Downloads/        installers while they run
  Tools/            Legendary (legendary-0.21.1/), its settings (legendary-config/, 0700) and the list of Epic games
```

Spaces found elsewhere (a CrossOver bottle) stay where they are. `library.json` stores their absolute path,
and game paths inside a space are stored relative to it, so a moved library keeps working.

`library.json` is saved atomically, and the file it replaces stays as `library.json.previous`. When the library can't
be read (a disk that isn't connected yet, a folder that was moved or renamed, a file this version can't decode) G-Player
writes nothing: `LibraryStore.open` returns a `LibraryProblem`, a damaged file is first copied to
`library.json.broken-<date>`, `AppModel.paths` is nil, and the window asks (Try Again, Locate…, Use Previous Copy, Start
Empty). Start Empty first keeps the previous copy as `library.json.before-empty-<date>`, since the new library's first
saves would rotate it away; neither dated copy is ever deleted. Locate… is also how a library is moved: quit, move the
folder, start G-Player, choose it. The spaces G-Player made in it (not those found elsewhere on the Mac) are pointed at
the new place (`LibraryState.movingLibrary`).

## Epic Games without Epic's launcher

Epic's own launcher runs on G-Player Wine (`AppPreset.epic`, see `docs/COMPATIBILITY.md`), and G-Player can also install and
start Epic games without it, through [Legendary](https://github.com/legendary-gl/legendary) (GPL-3.0-or-later), as Heroic does. Legendary is never bundled or linked:
the Mac downloads the pinned release (`Legendary.download`, `Tools/legendary-0.21.1/`) the first time the user signs in, and
G-Player runs it as a separate program (`Legendary.run`).

The page (`EpicView`) has no item in the sidebar: Get Apps has one Epic Games card with both ways to Epic (`EpicWay`), and the
second one opens the page over its list, as a destination of Get Apps' `NavigationStack` (`AppModel.appsPath`,
`AppsDestination.epicLibrary`; it closes when another sidebar item is chosen). `AppModel.openEpicLibrary` opens it from anywhere,
as the Epic Games space's "Your Epic Library" does, and messages that point people there say `EpicGames.libraryPlace`.

- **Isolated and checked.** `LEGENDARY_CONFIG_PATH` is `Tools/legendary-config` (0700), whose `config.ini` sets
  `default_platform = Windows` (Legendary's default on a Mac is `Mac`), `disable_auto_crossover` (G-Player passes `--wine` itself)
  and `disable_update_check`. The environment it gets is a short list (`Legendary.environment`), never a `CX_BOTTLE` or
  `WINEPREFIX` of the app's own, and stdin is closed, so nothing can wait for an answer. **Every run** is preceded by a SHA-256 check
  of the file against the pin (`Legendary.verified`), since it sits in the user's folder and is given a login and one-time codes.
  `LegendaryCommand` builds the command lines (global flags such as `-y` before the subcommand, `--platform Windows`,
  `--skip-sdl --skip-dlcs` on install so nothing is asked); `LegendaryOutput` reads what it prints with `--json`, leniently.
  Legendary exits with 0 after some failures (a refused code, an uninstall that could not delete, a move that didn't happen), so each
  operation is judged by what its own list says afterwards (`status`, `list-installed`, and the program being on the disk). Each kind
  of command has a limit (`Legendary.Limits`), and a stop or a limit is reported only once the process is gone, because it holds
  a lock on what it installs. Its process ids are kept in `running.pids`; at start G-Player ends the ones still running this very
  Legendary file (`Legendary.endLeftovers`: a crash must not leave an install running), never one of its own run.
- **Signing in.** The sheet shows Epic's login page in a web view with no stored data. Epic's own pages (`epicgames.com`) are told
  the browser is the Epic Games Launcher (`EpicSignIn.userAgent`), Google's and Apple's pages are not. The user signs in there; the
  sheet only looks at a navigation of the page itself to `localhost` (http or https) with `?code=` and, on Epic's redirect page
  (`EpicSignIn.isRedirectPage`), at that page's text, a JSON with `authorizationCode`: never a frame inside a page, never another
  address. No form is read and nothing is injected. The code goes to `legendary auth --code`. The other way is the helper page
  legendary.gl in the user's browser (explained first, opened by a button) and a pasted code (`EpicSignIn.code(fromPasted:)`: 30 or
  more letters and digits). Legendary keeps the token in `Tools/legendary-config`, which only a disk that keeps permissions protects;
  the sheet says so.
- **In the library.** Games install into a space of their own, "Epic Games" (`EpicGames.presetID`), made on G-Player Wine
  (`EpicGames.engineForSpace`: downloaded first if it isn't installed, never Wine Staging), under `drive_c/Games/Epic`, after a
  question that says where the game goes, what is fetched first and, once Legendary has said (`info --json`), how much room it
  takes. One install at a time (Legendary locks what it installs; progress is read from its log, `LegendaryInstallStatus`; Stop ends
  Legendary, and so does quitting G-Player; the next install goes on from its resume file); an install isn't first-run "setup" in
  the quit question. Nothing runs at start but, for a library that has an Epic game, one look at what Legendary has (each command
  takes seconds); otherwise it is looked at when the Epic Games page or such a game's panel opens, on Refresh, or when something
  changes it. A look that fails is a line (`EpicGames.lookFailureLine`) and changes nothing else: who was signed in and the games are
  kept in `Tools/epic-library.json` (0600, `EpicGames.Cache`), and only Legendary saying "not logged in" shows the sign-in card
  (`EpicGames.page`). What Legendary lists as installed becomes library entries with the source `.legendary(appName:)`
  (`EpicGames.merge`), which **never removes** an entry: Legendary records absolute paths, so a moved library or another volume makes
  every game's files "not found" (`EpicGames.health`), and the game keeps its playtime and settings. A game whose files are in the
  current Epic Games space at the same place offers Repair (`legendary move --skip-move`, `Legendary.relink`); any other offers
  Remove…, which makes Legendary forget it (`uninstall --keep-files`; no file is touched). Uninstall and Remove take the entry out
  themselves.
- **A launch.** A `.legendary` game is a program G-Player starts itself, so it goes through `LaunchPlanner` like one the user
  added (layers, components, graphics retry, running-program detection). Everything is settled with a plan made without Epic's
  parameters; then, right before Wine starts, `legendary launch --json` gives the program, folder, arguments and environment (and
  a one-time exchange code, `-AUTH_PASSWORD=…`, that logs the game in for a few minutes), and the launch is planned again with them
  (`LaunchPlanner.plan(legendary:)`): Legendary's game arguments, G-Player's, the user's, and Epic's sign-in arguments last. Of
  Legendary's environment only names on a whitelist pass (`LegendaryOutput.gameVariables`, empty: Legendary sets nothing a game
  needs), never one of G-Player's (`WINE*`, `GST_*`, `DXVK_*`, `PATH`…), and below the layers' and the user's own. It goes online;
  only when Epic can't be reached (no network, no answer in time) it asks again with `--offline`, and the game's panel says
  "Started offline: …". Any other failure is shown. While it asks, the game's tile says "Asking Epic for the launch parameters…".
- **Library files.** The first Epic game goes into `library.json` only after `library.json.before-epic-<date>` was kept
  (`LibraryStore.keepBeforeEpic`), since a G-Player from before Epic Games takes such a file for damaged. In the other direction, a
  game this version can't read (a source or field of a newer one) is not a reason to refuse the library: `LibraryState` keeps it as
  raw JSON (`JSONValue`, `unreadableGames`), writes it back unchanged on every save and shows and uses nothing of it.
- **Secrets.** `LaunchSecrets` hides the code (and the account's name and id) in the launch log's header and in the text of an
  error; `LegendaryLaunch` prints masked; the output of `launch` and `auth` is never logged; no address that holds a code is
  logged. The code is still in the process list while the game runs, as with any launcher.
- **Not yet** (TODO where the code has a natural place): updating, verify and repair, cloud saves, Epic's overlay, prerequisite
  installers, and the stand-in `EpicGamesLauncher.exe` some games look for.

## Engine revisions

G-Player Wine is published in revisions (`wine-cx-26.3.0-1`, `-2`). A revision that a newer one replaces stays in
`EngineCatalog` as a retired engine (`EngineInfo.replacedBy`, `EngineCatalog.retired`): `EngineCatalog.all` is what is
offered (G-Player Wine and Wine Staging: the engine menus while they are on, Settings), `EngineCatalog.known` is
everything G-Player can run (also Apple's toolkit, for the spaces that already use it), and
everything that runs or looks after an installed engine (launching, `EngineFixes`, D3DMetal, Stop All, leftovers) goes
by `known`. `EngineMigration` plans the move from a retired engine to its replacement: a space G-Player may change moves
once the replacement is installed and nothing runs, starts or is queued in it and no Add Game works in it
(`EngineMigration.isInUse`), or at once when the retired engine isn't installed. A space of another app
(`Space.mayChange` is false) never moves without the user's yes, since Wine updates the prefix's files on the first start
there: its page offers the move, and the retired engine stays installed while a space is on it. The replacement downloads
in the background once per run when a space on the retired engine or the installed retired engine needs it, and the
retired engine's folder goes only once the replacement is installed and no space is on it, after a fresh look at the
programs and at the files the running processes come from (`WineProcesses.executables`, `EngineMigration.mayRemove`), in
turn with the other work in engine folders (`AppModel.engineFilesWork`). Before the first move `library.json` is kept as
`library.json.before-engine-update-<date>`: an older G-Player reads the new engine's id as unknown. `AppModel` looks at
start, after an engine install, and at every look at the running programs. What G-Player learned about a game's graphics
(`AutoGraphics`, which names its engine) moves with the space.
An installed retired revision counts as G-Player Wine for new spaces and found bottles
(`EngineCatalog.installedGPlayerWine`), so they start offline on it and move with the rest.

An engine archive that lists GStreamer files (`gstreamer-files.txt`, `GStreamerRuntime`) gets them copied, at install,
out of GStreamer's official macOS package (`EngineCatalog.gstreamer`), which `pkgutil` expands in the staging folder. The
files an install downloads stay in `Downloads/<id>` until it has succeeded, so a failure in its last step doesn't download
them again; `EngineCatalog.diskBytes` counts every archive and the room the expansion takes.

Wine Mono, .NET for Wine, is not part of an engine's downloads: `EngineInfo.mono` names the release the engine's Wine expects
(`EngineCatalog.wineMono10_4_1`, pinned like any other download), and `EngineManager.installWineMono` fetches it into the
engine's `share/wine/mono/wine-mono-<version>` when a launcher that `needsDotNet` is set up or started: the same resumable,
checksummed download as an engine's (kept in `Downloads/<id>-mono` until it has been unpacked), unpacked beside the engine and
moved into place whole. `WineMono.register` installs its support package into a space once, and `LaunchPlanner` reads
what is still to do (`LaunchPlan.wineMono`: fetch, register) from the engine folder and the space's `system.reg`; only when
nothing is left is `mscoree` left on for the launch. `AppModel+WineMono` does the work from the space's queue, only where
`Space.mayChange`.

## One engine

People don't choose an engine. `EngineCatalog.firstRunInstalls` is G-Player Wine alone; its runtime libraries come out of
Gcenx's Wine Staging archive, which `EngineManager.install` downloads for them when Wine Staging isn't installed and
deletes with its unpacked copy. New spaces get `EngineCatalog.engineForNewSpace` (a pick in New Space counts only while
`AppModel.choosesEngines`, "Choose the Wine engine for each space" in Settings › Advanced, is on). A space's page shows
what `EngineSwitch.pageOffer` says: nothing, the engine menu (G-Player Wine and Wine Staging only), or plain words about
Wine Staging or Apple's toolkit with "Move to G-Player Wine…", which asks the `EngineSwitch.message` question. A bottle of
another app that is on a retired revision gets "Move Bottle" instead (`EngineMigration.offersMove`), which is its consent to
the move; the page shows one offer at a time, that one first. Wine Staging is installed or removed under Settings ›
Engines › Advanced and never by itself.

## A launch

`LaunchPlanner.plan` turns a game and its space into arguments, working folder, graphics backend and tweaks.
Then `AppModel.play` wraps the Chromium helpers the space's preset has on that engine (`AppPreset.helpersToWrap`) and
takes the wrapper out of those it runs without there (`helpersToUnwrap`, `ChromiumHelperWrapper.unwrap`), puts DXVK's DLLs
into the space when the backend is DXVK, and `WineLauncher.start` runs `arch -x86_64 <wine> …` with the environment from
`WineEnvironment.make`.

## Keeping the Mac usable

A Wine prefix whose path is very long (262 characters in the case that was found) makes `explorer.exe /desktop` fail,
and every Wine program then starts another one: thousands of processes within minutes, until macOS refuses to start
any. Two guards, both decided in the core:

- **Prevent.** `PrefixPath` refuses a prefix path over 150 characters (Windows' MAX_PATH is 260, and Wine runs
  `Z:\<prefix>\drive_c\windows\system32\…`). Onboarding won't continue with a library folder over 114 characters
  (room for a space folder name below `Spaces/`), `SpaceManager.folder(forNew:)` cuts long space names to fit and
  refuses before anything is written or Wine runs, and a bottle or prefix over the limit isn't adopted.
- **Watch.** Every look at the process table (`AppModel.refreshPrograms`) counts each space's programs with
  `WineProcesses.load`. A space with more than 12 `explorer.exe` or more than 200 Windows programs is stopped at once:
  SIGKILL for its programs first (a signal needs no new process, which a flooded Mac may refuse to start), then
  `wineserver -k`, then SIGKILL again for what is left, and the user is told. A space past half a limit is looked at
  every 1.5 seconds. Programs are the space's by working folder, `WINEPREFIX` or a `drive_c` path in the command (Wine's
  programs have lost their parent, so the parent says nothing), plus those of the space's games found by their own folder.

## Updating G-Player itself

G-Player updates itself with [Sparkle](https://sparkle-project.org) 2 (MIT), pinned to an exact version in `Package.swift`;
SwiftPM checks the checksum of its binary framework. Only the app target knows it. `AppUpdater` wraps
`SPUStandardUpdaterController` and starts it only when the bundle's Info.plist has `SUPublicEDKey`
(`SelfUpdate.isEnabled`), so a build from source never looks for updates. `scripts/build-app.sh` takes the key from
`scripts/sparkle-public-key.txt` (empty: no key), copies Sparkle.framework into `Contents/Frameworks` with an rpath for
it, and signs Sparkle's nested code before the app. `SUFeedURL` is the `appcast.xml` attached to the latest GitHub
release and system profiling is off, so the only requests are the appcast and the update's download. Sparkle asks by
itself, the second time the app opens, whether to check automatically; Settings › General changes the answer. An install
quits G-Player with Sparkle's own quit event, and `applicationShouldTerminate` doesn't ask about setup then
(`SetupQuit.mayAsk`), so the installer isn't left waiting for the app.

## Reviewing the UI

`GPlayer --render-onboarding <folder>` (or `GPLAYER_RENDER_ONBOARDING=<folder>`) draws every onboarding step and the
main screens a newcomer meets (the empty library, the library while the first run sets up and with its one-time notes, a
new space, the New Space, Add Existing Space, Add Game, "Allow changes" and "didn't start" sheets, a launcher's page,
Get Apps with its Epic Games card and the Epic page opened over it, Settings › Engines also as the D3DMetal button opens it) into PNGs, light and dark at 2x, prints their paths and exits,
in about ten seconds:

```bash
make app
build/G-Player.app/Contents/MacOS/GPlayer --render-onboarding build/snapshots/review
```

It touches nothing of yours: the library is a temporary folder, settings are kept in memory, nothing is downloaded, no
Wine runs and no window appears (`SnapshotRenderer`, `LaunchArguments`). Views are drawn by AppKit in a window that is
never on screen, because SwiftUI's `ImageRenderer` draws checkboxes, forms, lists and progress bars as placeholders.
Limits: checkboxes and progress bars have the grey look of an inactive window, and the main window is the sidebar next
to a page without the title bar, toolbar or glass sidebar.
