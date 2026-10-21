# G-Player

Play Windows games on an Apple Silicon Mac, for free. G-Player keeps your games in one library and runs
them with [Wine](https://www.winehq.org): Steam games, Epic games and games you add yourself, side by side.

<p align="center"><img src="docs/images/welcome.png" width="720" alt="G-Player first launch"></p>

- **One library.** Steam and Epic games show up on their own. Add any other game by dropping its folder,
  its zip/rar/7z archive or its installer onto the window.
- **Spaces.** Each space is a separate Windows (a Wine prefix) with its own C: drive. Browse its files,
  run any program in it, and see exactly where everything lives on your Mac.
- **Steam that draws.** Steam's 2026 client shows a black window under plain Wine on macOS. G-Player fixes
  it the way MaPC does (see [How Steam works here](docs/HOW-STEAM-WORKS.md)).
- **Brings over what you have.** CrossOver bottles, Whisky bottles and hand-made prefixes are found on first
  launch and used in place, with their games and saves.
- **No account, no telemetry.** G-Player talks to GitHub (engine downloads), the stores' own CDNs (installers,
  cover art) and nothing else.

## Download

Get the latest `G-Player-<version>.zip` from [Releases](https://github.com/RiperYT/g-player/releases)
(the same files are kept in [`releases/`](releases/)). Unzip it and move **G-Player.app** to Applications.

The app isn't notarized yet, so the first time macOS blocks it. Open it once with **right-click › Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/G-Player.app
```

**Needs:** a Mac with Apple Silicon (M1 or later), macOS 15 Sequoia or later, Rosetta 2 (G-Player offers to
install it), about 1 GB for the engine plus room for games.

## What runs

| Works | Doesn't work |
|---|---|
| Steam client and most DirectX 9–11 games through DXVK | Games with kernel anti-cheat (EasyAntiCheat, BattlEye, Vanguard) |
| Portable games, Unity, Unreal, Electron and RPG Maker games | Games that need a GPU driver Wine can't fake |
| DirectX 11/12 games through Apple's D3DMetal (optional, see below) | |

The first minutes of a game can stutter while shaders compile. That settles once the cache is built.

### Apple's Game Porting Toolkit (optional)

For DirectX 12 games, install Apple's toolkit with Homebrew. G-Player finds it and offers it as a second
engine with D3DMetal:

```bash
brew install --cask --no-quarantine gcenx/wine/game-porting-toolkit
```

G-Player never ships Apple's files. Their license doesn't allow it.

## Build from source

Needs Xcode 16 or later.

```bash
make test   # unit tests, no Wine needed
make run    # builds build/G-Player.app and opens it
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the code is organised and
[CONTRIBUTING.md](CONTRIBUTING.md) before sending a pull request.

## Credits

G-Player stands on other people's work:
[Wine](https://www.winehq.org) and [Wine Staging](https://wiki.winehq.org/Wine-Staging),
[Gcenx's macOS Wine builds and DXVK for macOS](https://github.com/Gcenx),
[DXVK](https://github.com/doitsujin/dxvk), [MoltenVK](https://github.com/KhronosGroup/MoltenVK), and
[MaPC's open-source MacadeKit](https://github.com/abduzeedo/mapc-engine) (Apache-2.0), where the Steam
helper wrapper comes from.

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for third-party parts.
