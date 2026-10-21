# Architecture

```
Sources/
  GPlayerCore/          everything that decides how a Windows program runs (no SwiftUI)
    Model/              Space, Game, GraphicsBackend, LibraryState
    Storage/            LibraryPaths (the folders), LibraryStore (library.json)
    Engines/            EngineCatalog (pinned downloads), EngineManager, FileDownloader
    Wine/               WineEnvironment (env + DLL overrides), WineLauncher, SpaceManager,
                        ChromiumHelperWrapper
    Import/             ArchiveExtractor (bsdtar), ExecutableScanner (which .exe is the game),
                        ProgramSnapshot (what an installer added), GameImporter
    Discovery/          VDF + SteamLibrary, EpicLibrary, ShellLink + ShortcutScanner (.lnk),
                        EnvironmentFinder (CrossOver/Whisky/~/Games prefixes, old launcher scripts)
    Presets/            AppPreset (Steam, Epic, GOG, Ubisoft), PresetInstaller, LaunchPlanner
    Resources/          chromium-helper-wrapper.exe (built from tools/)
  GPlayer/              the SwiftUI app
    App/                GPlayerApp, AppModel (state, actions, persistence)
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
- **Every download is pinned by SHA-256** (`EngineCatalog`). Store installers come from the stores' own URLs.
- **Never ship Apple's Game Porting Toolkit.** Use the user's own copy.

## The library folder

Chosen on first launch, `~/Games/G-Player` by default:

```
G-Player/
  library.json      spaces, games, hidden store games
  Spaces/<name>/    Wine prefixes G-Player created
  Engines/<id>/     Wine Staging, DXVK
  Covers/           cover art
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
