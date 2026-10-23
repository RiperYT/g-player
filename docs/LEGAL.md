# Licenses and what G-Player ships

G-Player is licensed under the [Apache License 2.0](../LICENSE). This page lists everything else it touches,
so it can be published, forked or sold without surprises. It is a summary, not legal advice.

## Inside the app

| Part | License | Notes |
|---|---|---|
| G-Player's own code, icon, shims | Apache-2.0 | |
| `chromium-helper-wrapper.exe` (`tools/chromium-helper-wrapper/wrapper.c`) | Apache-2.0 | From MaPC's MacadeKit, Steale LLC. Credited in `NOTICE`. |
| `engine-fixes/wow64cpu.dll` | LGPL-2.1+ (Wine) | Built from the Wine 11.18 source with `tools/wine-patches/wow64cpu-rosetta.patch` by `scripts/build-wow64cpu.sh`, which is its complete corresponding source. Wine's license text is in `Resources/licenses/`. Replaced in the user's engine only over the exact Gcenx file, which is kept. |
| `engine-fixes/cx-ntdll.so`, `cx-ntdll-x86_64.dll`, `cx-ntdll-i386.dll`, `cx-winecoreaudio.so` | LGPL-2.1+ (Wine) | G-Player Wine's ntdll and CoreAudio driver rebuilt from CodeWeavers' CrossOver 26.3.0 source (pinned in `scripts/build-engine-cx.sh`) with `tools/wine-patches/cx-*.patch`; `cx-nx-compat.patch` is Alexander Theißen's (athei/wine 539aa62). The tarball, the patches and the script are their complete corresponding source. Replaced in the user's engine only over the exact files of G-Player Wine 26.3.0-1, which are kept; revision 2 is built with these patches and needs none. |
| `engine-fixes/libMoltenVK.dylib` | Apache-2.0 (MoltenVK, SPIRV-Cross, SPIRV-Tools, Vulkan-Headers), MIT-style (SPIRV-Headers), BSD-3-Clause (cereal) | MoltenVK 1.4.2 from the Khronos release, code unchanged and signed with G-Player's Developer ID for notarization; `scripts/fetch-moltenvk.sh` fetches it and the license texts, each checked against a pinned SHA-256. License texts in `Resources/licenses/`. Replaced in the user's engine only over the exact Gcenx file, which is kept. |
| `GameFixes.json` | Data derived from umu-protonfixes, BSD-2-Clause; G-Player's own entries Apache-2.0 | License text in `Resources/licenses/`. |
| `steamdb-rules.ini` | MIT, SteamDB FileDetectionRuleSets | Unchanged copy. License text in `Resources/licenses/`. |
| `Frameworks/Sparkle.framework` (Sparkle 2.10.0) | MIT (Sparkle); BSD-style (bsdiff, SUSignatureVerifier), MIT (sais-lite), zlib (Ed25519) inside it | Bundled, code unchanged: it updates G-Player itself. SwiftPM fetches Sparkle's own release, pinned to the exact version and checked against the checksum in its `Package.swift`. License texts in `Resources/licenses/`. |

All of these allow commercial use, as long as the notices stay in place.

## Downloaded at run time, never bundled

The user's Mac fetches these from their original sources and checks each against a pinned SHA-256:

| Component | License | From |
|---|---|---|
| Wine Staging 11.18 | LGPL-2.1+ | Gcenx's macOS builds on GitHub |
| G-Player Wine (Wine 11 from CodeWeavers' CrossOver 26.3.0 source with `tools/wine-patches/cx-*.patch`, DXMT from its main branch, MoltenVK 1.4.2) | LGPL-2.1+ (Wine), LGPL-2.1+ with older parts MIT (DXMT), Apache-2.0 and others (MoltenVK) | G-Player's own GitHub release `engine-cx26.3.0-2`, built by `scripts/build-engine-cx.sh`. The exact Wine source it was built from is attached to the same release; with the patches and the script it is the complete corresponding source. DXMT is commit `ce001dfbe` as DXMT's CI built it, unchanged; that build and DXMT's complete source with its submodules are attached to the same release. Its runtime libraries come from Gcenx's Wine Staging download (row above) and its GStreamer files from the GStreamer package (row below) on the user's Mac, not from G-Player's archive. Revision `engine-cx26.3.0-1`, which earlier versions installed, is no longer downloaded; Macs that have it keep using it until their spaces have moved to revision 2, and it is then removed. "CrossOver" is CodeWeavers' trademark; G-Player Wine isn't CrossOver. |
| GStreamer 1.28.8 (the runtime package, for game videos in G-Player Wine) | LGPL-2.1+ (GStreamer), LGPL (glib), MIT (libffi, graphene), BSD (pcre2, orc), libpng and libjpeg-turbo under their own licenses | The GStreamer project's official macOS package (`gstreamer-1.0-1.28.8-universal.pkg` from gstreamer.freedesktop.org). G-Player expands it on the user's Mac and copies only the files G-Player Wine lists (`gstreamer-files.txt` in its archive) into the user's G-Player Wine, unchanged. |
| Wine Mono 10.4.1 (`wine-mono-10.4.1-x86.tar.xz`, 39 590 692 bytes; .NET for Wine, used by Epic's launcher) | A mix, as the `COPYING` of the wine-mono repository lists it (the tarball carries no license files of its own): Wine Mono's own code and its winforms, winforms-datavisualization, wpf, monoDX and System.Speech libraries MIT; Mono's runtime and class libraries available as LGPL or MIT X11 (ICSharpCode.SharpZipLib is GPL with an exception); mono-basic MIT X11 (its compiler LGPL v2); FNA (`WineMono.FNA`) MSPL and MIT, with FAudio, FNA3D, MojoShader, SDL3 and the SDL bindings zlib, FNAMF MIT and FNA.NetStub MSPL | The Wine project's download (`dl.winehq.org/wine/wine-mono/10.4.1/`), the file the `wine-mono-10.4.1` release of `madewokherd/wine-mono` lists with the same SHA-256. Fetched the first time Epic's launcher is started or set up, and unpacked unchanged into the user's G-Player Wine (`share/wine/mono/wine-mono-10.4.1`), where Wine looks for a shared copy; its "Wine Mono Windows Support" package is then installed once into the launcher's space. The version is the one G-Player Wine's Wine expects, so it is named next to the engine in `EngineCatalog`. Its source: `gitlab.winehq.org/mono/wine-mono`, tag `wine-mono-10.4.1`. |
| DXVK for macOS 1.10.3 | zlib | Gcenx on GitHub |
| winetricks 20260125 | LGPL-2.1+ | GitHub; run as a separate program |
| Legendary 0.21.1 (`legendary_macOS_arm64`, 15 275 984 bytes) | GPL-3.0-or-later | `legendary-gl/legendary`'s GitHub release; run as a separate program, on command-line arguments and its output, never linked or bundled and not part of G-Player. Downloaded only when the user first signs in to Epic Games; its source is in the same repository. |
| Visual C++ 2015–2022 Redistributable | Microsoft | Microsoft's download servers |
| `d3dcompiler_47.dll` | Microsoft | `mozilla/fxc2`, as winetricks does |
| Other components (DirectX, .NET, PhysX, XNA, OpenAL, fonts) | Each maker's | The sources winetricks pins |
| Store installers | Each store's | Valve, Epic, GOG, Ubisoft |
| Steam cover art | Valve | Valve's CDN, cached locally, never redistributed |
| Epic game box art | Epic | Epic's CDN, cached locally, never redistributed |

Microsoft's runtimes and fonts can't be bundled with an app like this, which is why they are only ever
downloaded onto the user's Mac when a game needs them.

## Epic Games through Legendary

Legendary is GPL-3.0-or-later software and G-Player is Apache-2.0, so G-Player never includes it: it is a separate program
that the user's Mac downloads and runs, talking to it only through arguments and what it prints (the same terms as winetricks
above). Its login and settings stay in the user's library folder (`Tools/legendary-config`, readable by the user only on a disk that keeps permissions: not on exFAT, most network volumes or iCloud). G-Player
turns off Legendary's check for newer versions; it still asks legendary.gl for its version information once, when you sign in,
and for the few games with selectable language packs, which packs there are, and sends nothing about the account.

Legendary isn't made or endorsed by Epic Games, and Epic hasn't published a position on third-party clients such as it and
Heroic Games Launcher. G-Player doesn't bypass anti-cheat or copy protection: games that need EasyAntiCheat or BattlEye don't
run on a Mac, and G-Player says so. The user signs in on Epic's own page; G-Player never sees the password.

## Apple's Game Porting Toolkit

G-Player never includes, downloads or installs Apple's Game Porting Toolkit or D3DMetal. In short, Apple's
license lets you use the toolkit to develop, test and evaluate games, and allows passing it on only for
non-commercial purposes. This is a summary; the license is the authority, and it is linked from
[Apple's Game Porting Toolkit page](https://developer.apple.com/games/game-porting-toolkit/). So:

- G-Player's support for it is **off by default**. People who installed the toolkit themselves, or downloaded it
  from Apple, can turn it on in Settings › Engines; the app says what Apple's license allows. With it on, G-Player
  copies D3DMetal, checking that D3DMetal.framework and libd3dshared.dylib are signed by Apple, from that toolkit into their own library and their G-Player
  Wine engine. It is never uploaded, shared or bundled.
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
