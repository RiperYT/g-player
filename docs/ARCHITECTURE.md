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
    Resources/          chromium-helper-wrapper.exe (built from tools/)
  GPlayer/              the SwiftUI app
    App/                GPlayerApp, AppModel (state, actions, persistence), SnapshotRenderer (UI to PNGs)
    Views/              Library, AddGame, Spaces, Files, Apps, Settings, Onboarding, Components
Tests/GPlayerCoreTests  unit tests for everything in the core that doesn't need Wine
tools/                  chromium-helper-wrapper (C, cross-compiled with mingw-w64)
scripts/                build-app.sh, release.sh, make-icon.swift, build-wrapper.sh
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
  Engines/<id>/     G-Player Wine, Wine Staging, DXVK
  Covers/           cover art and program icons
  Logs/             one log per launch (the command, the DLL overrides, Wine's output)
  Downloads/        installers while they run
```

Spaces found elsewhere (a CrossOver bottle) stay where they are. `library.json` stores their absolute path,
and game paths inside a space are stored relative to it, so a moved library keeps working.

## A launch

`LaunchPlanner.plan` turns a game and its space into arguments, working folder, graphics backend and tweaks.
Then `AppModel.play` wraps Chromium helpers if the space's preset has any, puts DXVK's DLLs into the space
when the backend is DXVK, and `WineLauncher.start` runs `arch -x86_64 <wine> …` with the environment from
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

## Reviewing the UI

`GPlayer --render-onboarding <folder>` (or `GPLAYER_RENDER_ONBOARDING=<folder>`) draws every onboarding step and the
main screens a newcomer meets (the empty library, the library while the first run sets up and with its one-time notes, a
new space, the New Space, Add Existing Space, Add Game, "Allow changes" and "didn't start" sheets, a launcher's page,
Settings › Engines also as the D3DMetal button opens it) into PNGs, light and dark at 2x, prints their paths and exits,
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
