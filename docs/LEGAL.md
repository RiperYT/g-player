# Licenses and what G-Player ships

G-Player is licensed under the [Apache License 2.0](../LICENSE). This page lists everything else it touches,
so it can be published, forked or sold without surprises. It is a summary, not legal advice.

## Inside the app

| Part | License | Notes |
|---|---|---|
| G-Player's own code, icon, shims | Apache-2.0 | |
| `chromium-helper-wrapper.exe` (`tools/chromium-helper-wrapper/wrapper.c`) | Apache-2.0 | From MaPC's MacadeKit, Steale LLC. Credited in `NOTICE`. |
| `GameFixes.json` | Data derived from umu-protonfixes, BSD-2-Clause; G-Player's own entries Apache-2.0 | License text in `Resources/licenses/`. |
| `steamdb-rules.ini` | MIT, SteamDB FileDetectionRuleSets | Unchanged copy. License text in `Resources/licenses/`. |

All of these allow commercial use, as long as the notices stay in place.

## Downloaded at run time, never bundled

The user's Mac fetches these from their original sources and checks each against a pinned SHA-256:

| Component | License | From |
|---|---|---|
| Wine Staging 11.18 | LGPL-2.1+ | Gcenx's macOS builds on GitHub |
| DXVK for macOS 1.10.3 | zlib | Gcenx on GitHub |
| winetricks 20260125 | LGPL-2.1+ | GitHub; run as a separate program |
| Visual C++ 2015–2022 Redistributable | Microsoft | Microsoft's download servers |
| `d3dcompiler_47.dll` | Microsoft | `mozilla/fxc2`, as winetricks does |
| Other components (DirectX, .NET, PhysX, XNA, OpenAL, fonts) | Each maker's | The sources winetricks pins |
| Store installers | Each store's | Valve, Epic, GOG, Ubisoft |
| Steam cover art | Valve | Valve's CDN, cached locally, never redistributed |

Microsoft's runtimes and fonts can't be bundled with an app like this, which is why they are only ever
downloaded onto the user's Mac when a game needs them.

## Apple's Game Porting Toolkit

G-Player never includes, downloads or installs Apple's Game Porting Toolkit or D3DMetal. In short, Apple's
license lets you use the toolkit to develop, test and evaluate games, and allows passing it on only for
non-commercial purposes. This is a summary; the license is the authority, and it is linked from
[Apple's Game Porting Toolkit page](https://developer.apple.com/games/game-porting-toolkit/). So:

- G-Player's support for it is **off by default**. People who installed the toolkit themselves can turn it on
  in Settings › Engines; the app says what Apple's license allows.
- G-Player doesn't point to third-party repackagings of Apple's files.
- Nothing in this repository or in a release contains Apple's files. Keep it that way: pull requests that add
  them are refused.

## Data sources we don't use

- **ProtonDB** data is ODbL (share-alike) and **PCGamingWiki** is CC BY-NC-SA; neither fits an Apache-2.0
  app that may be sold, so G-Player doesn't bundle them.
- **Lutris** installers, **CrossOver** CrossTie, **Bottles**, **Heroic** known-fixes and **Whisky**'s
  GameDB are GPL, proprietary or unlicensed; G-Player uses none of their data or code.

## Trademarks

Windows, DirectX, Steam, Epic Games, GOG, Ubisoft, Unity, Unreal and Apple names are used only to say what
G-Player works with. G-Player isn't affiliated with or endorsed by any of them.
