# Changelog

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
