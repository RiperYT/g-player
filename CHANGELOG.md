# Changelog

## [0.3.0] - 2026-10-22

Compatibility layers: G-Player now works out what a game needs and sets it up, so you don't have to touch Wine.

- **Profiles instead of Wine settings.** Each game has Recommended, Compatible and Custom (plus Fast on engines
  with D3DMetal), and a few plain switches: window mode, sharper Retina, frame rate, known fixes.
- **Game analysis.** G-Player reads the game's files and shows its engine (Unity, Unreal, Godot…), DirectX
  version, 32/64-bit and .NET, and warns before launch about anti-cheat that blocks Wine or a game known not
  to work on a Mac. Detection rules come from SteamDB's FileDetectionRuleSets (MIT).
- **Known fixes for 200+ games**, imported from umu-protonfixes (BSD-2): DLL settings, environment, arguments,
  Windows version and the components each game asks for.
- **Windows components.** New spaces get Visual C++ 2015–2022 and the DirectX shader compiler. Games add what
  they need (DirectX 9 helpers, XACT, .NET, XNA, PhysX, fonts…) from their makers' servers, each file checked
  by SHA-256, through a hardened copy of winetricks. Installs queue per space, can be stopped from the
  sidebar, time out if an installer hangs, and failed ones can be retried.
- **After a failed launch** G-Player reads the log and offers one next step, such as installing a missing
  component or trying the Compatible profile.
- **Steam games** get their settings per program, and if Steam is already open G-Player offers to restart it
  so the game's settings reach it.
- **Spaces from other apps** (a CrossOver bottle used in place) are only changed after you allow it once.
- **Apple's Game Porting Toolkit is now opt-in** (Settings › Engines), off by default. G-Player never ships or
  downloads Apple's files; it only uses a copy you installed. Spaces that used it before keep working.
- Docs: `docs/COMPATIBILITY.md` (how the layers work, where downloads come from) and `docs/LEGAL.md`.

## [0.2.0] - 2026-10-22

- Real icons: G-Player reads each program's icon from its .exe. Launchers (Steam, Epic…) get square tiles with
  their icon, games without cover art show their icon on the text cover.
- Hide any game, including ones Steam or Epic added on their own. Hidden games have their own place in the
  sidebar and come back with "Show in Library". Games you added yourself can still be removed.
- Files: the space you're browsing is a big switcher at the top left, with quick places below it (C: drive,
  Games, Program Files, Documents, AppData, the space folder). A folder that links to your Mac, such as
  Documents, says "(Mac)".
- The game inspector shows whether a program is 32- or 64-bit (or .NET) and says when a 32-bit program may
  not start on Wine for macOS.
- Steam and Epic games that are being updated no longer drop out of the library, and keep their hidden state.

## [0.1.0] - 2026-10-21

First public build.

- Library of games and launchers with cover art, search and Recently Played.
- Spaces: separate Wine prefixes with their own C: drive; create, browse, run programs, Windows tools,
  stop all, remove.
- Add a game by dropping a folder, a zip/rar/7z archive or an installer. G-Player copies it or runs the
  installer, then ranks the programs it found so you pick the one that starts the game.
- Steam in one click, with the Chromium helper wrapper that fixes the black window. Steam and Epic games
  appear in the library on their own.
- Experimental presets for Epic Games Launcher, GOG Galaxy and Ubisoft Connect.
- First-launch setup: library location, Rosetta 2 check, Wine Staging 11.18 + DXVK download
  (checked by SHA-256), and adopting CrossOver/Whisky bottles and existing prefixes in place.
- Engines: Wine Staging 11.18 with DXVK, and Apple's Game Porting Toolkit (D3DMetal) when installed.
