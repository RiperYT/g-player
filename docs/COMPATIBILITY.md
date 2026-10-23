# How G-Player gets games running

Nobody tests every Windows game on a Mac, and G-Player doesn't pretend to. It stacks five layers, each one
small, so most games start without anyone touching Wine settings.

## 1. Windows components in every space

Most games need the Visual C++ runtime and the DirectX shader compiler. Every new space gets them:

| Component | What it is | Where it comes from |
|---|---|---|
| `vcrun2022` | Visual C++ 2015–2022 runtime, 32- and 64-bit (about 40 MB) | Microsoft's download servers |
| `d3dcompiler_47` | DirectX shader compiler, 32- and 64-bit (about 8 MB) | The DLLs in Mozilla's `mozilla/fxc2` repository on GitHub, which is where winetricks gets them |

G-Player installs these two itself, the way winetricks 20260125 does. More components install on demand, when
a known fix asks for them or a failed launch shows they're missing: DirectX 9–11 extras (`d3dx9`, `d3dx10`,
`d3dx11_43`, `d3dcompiler_43`), audio and input (`xact`, `xinput`), older Visual C++ runtimes, .NET 4.8, PhysX,
XNA, OpenAL and fonts. Those go through [winetricks](https://github.com/Winetricks/winetricks), run as a
separate program, and come from the sources it pins for each one:

- Microsoft's download servers (the Visual C++ runtimes, .NET), NVIDIA's (PhysX), openal.org (OpenAL);
- a mirror of Microsoft's DirectX redistributable (June 2010, and February 2010 for the DirectMusic and
  DirectPlay verbs), and archive.org copies of Microsoft files that are no longer online (XNA, DirectMusic);
- GitHub and SourceForge for most fonts (the core fonts, Source Han Sans, Tahoma).

The DirectX components (`d3dx9`, `d3dx10`, `d3dx11_43`, `d3dcompiler_43`, `xact`, `xinput`) unpack files from one
shared download of about 100 MB, so the second one is quick.

Every file is checked against a SHA-256 before it is used. The pins of the two base components, and of winetricks
itself, are in G-Player's source (the first two are winetricks' own pins); for everything else, the pins are the ones
in winetricks 20260125. G-Player runs a copy of the script with two edits, so that a mismatch, or a download that
has no checksum at all, stops the run instead of asking whether to continue. Nothing from Microsoft is bundled with
G-Player: the installers come from their servers to your Mac. Winetricks runs with its usage statistics turned off
and works in a temporary folder of its own that is deleted afterwards.

What can be installed is a short list (`RuntimeCatalog.isInstallable`): the components above, and winetricks
verbs that were checked to work in a 64-bit space. Known fixes ask for some components that can't be
installed: DirectX wrappers such as dgVoodoo 2 and `xliveless` (not winetricks verbs), Ubisoft Connect (its
download has no checksum), the old .NET versions (their installers don't work in a 64-bit space), and others. They
stay in the fix data, as the source has them, and G-Player never installs them. The game's page says so in one
line ("Needs DirectX wrapper dgVoodoo 2 and xliveless, which G-Player can't install yet.").

`vcrun2015`, `vcrun2017` and `vcrun2019` mean `vcrun2022`: the 2015–2022 runtime installs the same DLLs and is the
one Microsoft keeps current. (Winetricks' own pin for `vcrun2019` points to a file Microsoft has since replaced.)

Installing is forgiving. One component that fails doesn't stop the others: G-Player records the failure and the
date in the space, tries the rest, and reports every failure together. It doesn't try a failed component again for
three days, unless you ask. An installer that runs longer than 15 minutes is stopped, and cancelling an install
stops the installer it started, never the other programs in the space.

Fonts: Wine on macOS uses the Mac's own fonts (Arial, Courier New, Georgia, Hiragino…), so Microsoft's core
fonts are rarely needed.

## 2. What the game is

When a game is added, G-Player looks at its files:

- **Engine**: Unity, Unreal, Godot, GameMaker, RPG Maker, Ren'Py, Electron, Source… using
  [SteamDB's file detection rules](https://github.com/SteamDatabase/FileDetectionRuleSets) (MIT).
- **Anti-cheat and launchers** from the same rules. Each anti-cheat rule is classified by name
  (`AntiCheatPolicy`). Kernel-level ones (EasyAntiCheat, BattlEye, Ricochet, nProtect GameGuard, XIGNCODE3,
  EA AntiCheat, BlackCipher, TenProtect, ACE and NetEase's) stop a launch until you say go on, because online play
  won't work. Others (PunkBuster, EQU8, HackShield…), and any rule that isn't classified yet, only warn. A Ubisoft
  or EA launcher means that launcher has to be in the same space, unless the game comes from a store, which
  starts its own launchers.
- **DirectX version** from the program's imports (DirectX 9, 10, 11, 12, OpenGL, Vulkan).
- **32- or 64-bit**, and whether it is a .NET program.

The result is kept with the game, together with the program it was made for and a version number, so it is
worked out again when the program changes or this list grows.

## 3. Engine defaults

| Engine | What G-Player does |
|---|---|
| Unity | DirectX 12 build on an engine without D3DMetal → `-force-d3d11`. Window mode → `-screen-fullscreen 0/1` |
| Unreal | DirectX 12 without D3DMetal → `-dx11`. Window mode → `-windowed` / `-fullscreen` |
| Source | Window mode → `-windowed -noborder` / `-fullscreen` |
| Godot | Window mode → `--windowed` / `--fullscreen` |
| Electron, NW.js, RPG Maker MV/MZ | `--no-sandbox --in-process-gpu --disable-gpu-sandbox`, so the window isn't black |

## 4. Known fixes for single games

`Sources/GPlayerCore/Resources/GameFixes.json` holds fixes keyed by Steam app ID or program name:
components to install, DLL settings, environment variables, launch options and registry values. Most come
from [umu-protonfixes](https://github.com/Open-Wine-Components/umu-protonfixes) (BSD-2-Clause), converted
by `tools/compat-db/import_umu.py`; only declarative fixes are imported and Linux-only settings are dropped.
They were made for Linux, so the app says so until someone confirms a fix on a Mac. G-Player's own entries
live in `tools/compat-db/gplayer-fixes.json` and win over imported ones, including "known not to work".

The data stays as the source wrote it. What G-Player can do with it is decided when a launch is planned:

- **Settings are not components.** umu lists them next to the components, and winetricks treats them as
  verbs, but they install nothing. A Windows version (`win7`, `winxp`, `win10`…) becomes a registry value
  for the game's own program, `HKCU\Software\Wine\AppDefaults\<program>\Version`, with the value winetricks passes
  to `winecfg`; it needs to know the program's name, and a fix that can't be applied for lack of one says so.
  `hidewineexports=enable` (a Wine Staging setting that hides Wine from programs that refuse to run under it)
  is one value for the whole space, `HKCU\Software\Wine\HideWineExports`. G-Player writes it on every launch,
  like the Retina switch, and takes it away again when the next game doesn't ask for it. Settings never appear
  in a plan's components and are never recorded as installed.
- **Components that can't be installed** are dropped and listed in one note (see above).
- **Stand-in components** are replaced by what they stand for (`vcrun2019` → `vcrun2022`).
- **Fixes that change the command line** (`replace_command`) are applied only to programs you add yourself.
  For Steam and Epic games the store starts the program, so G-Player can't change how it starts; the game's page
  says so, and a fix that had nothing else to do isn't counted as applied.

For Steam games, DLL settings and Windows versions are also written per program (`AppDefaults`), so they reach
the game even when an already running Steam starts it. The graphics backend and environment variables reach the game
only through the Steam it was started with, because a running Steam starts games with what it got. G-Player remembers
what it started each Steam with (`LauncherSettings`: the backend and the profile's, a fix's and the game's own
variables) and marks a launch that needs other settings, so the app asks to restart Steam first. A profile makes no
difference by itself: Compatible and Custom ask only when they bring another backend or other variables. Steam started
some other way is not known, and is taken for a plain one. Registry values that a launch set for a program and that a
later launch no longer wants are removed again (`RegistryFile.removals`).

## 5. Profiles, switches and a second opinion

Instead of Wine settings, each game has a profile:

| Profile | Use it when |
|---|---|
| **Recommended** | Always first. Engine defaults, known fixes, the best graphics this space has. |
| **Compatible** | The game won't open. Wine's own renderer, a window, no extra tricks. |
| **Fast** | You want frames: D3DMetal. Offered only where the space's engine has it; on Wine Staging it would do what Recommended does, so a stored Fast counts as Recommended there. |
| **Custom** | You chose graphics by hand under Advanced. |

Plus three switches in plain words: fullscreen or a window, sharper on Retina displays, show frame rate.

When a game quits quickly or fails, G-Player reads the launch log and says what happened: a missing
Windows component (with a button that installs it and plays again), graphics that didn't start (with a
button that tries Compatible), anti-cheat, or a crash. G-Player's own header at the top of the log (the paths and
title you chose) is left out of the reading, so a game folder called "BattlEye" doesn't look like a failure.

## Engines and graphics backends

| Engine | Wine | Backends (default first) | Steam |
|---|---|---|---|
| Wine Staging 11.18 (Gcenx) | upstream Wine Staging; advanced, not installed by default | DXVK, WineD3D | yes |
| G-Player Wine | Wine 11 from CodeWeavers' CrossOver 26.3 source (`scripts/build-engine-cx.sh`) | DXVK, D3DMetal once it is copied in (taken for 64-bit DirectX 10–12), DXMT, WineD3D | yes |
| Apple's Game Porting Toolkit | Apple's wine 7.7; runs the spaces that already use it, never offered | D3DMetal, WineD3D | no |

- **D3DMetal** (Apple) turns DirectX 11 and 12 straight into Metal, for 64-bit programs only. G-Player Wine runs it next to
  Steam, so DirectX 12 games run with Steam signed in. G-Player copies it from the user's own Game Porting Toolkit, checking
  that D3DMetal.framework and libd3dshared.dylib are signed by Apple, into `~/Games/G-Player/D3DMetal` and from there into G-Player Wine, replacing Wine's
  builtin `d3d10`, `d3d11`, `d3d12` and `dxgi` (Wine's are kept in `lib/wine-d3d`, and put back when the toolkit is
  turned off). Launches get `CX_APPLEGPTK_LIBD3DSHARED_PATH` and `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal`.
- **DXVK** (Gcenx's 1.10.3) goes through Vulkan and MoltenVK 1.4.2. On G-Player Wine with D3DMetal in, Wine's own
  `dxgi` goes into the space's system32 for DXVK launches (`dxgi=n,b`): DXVK can't present with Apple's.
- **DXMT** (3Shain, main branch at `ce001dfbe`, LGPL-2.1+) turns DirectX 10 and 11 straight into Metal, 32- and 64-bit. Its DLLs go into the
  space as native ones for DXMT launches (`dxgi,d3d11,d3d10core=n,b`).
- **WineD3D** is Wine's own, on Apple's OpenGL 4.1: DirectX 9, not 10 or 11.

On G-Player Wine the Recommended profile takes D3DMetal for 64-bit DirectX 10–12 once it is in, DXVK otherwise and for
32-bit programs. G-Player Wine also differs from CrossOver's own Wine in two ways: the user name and profile folder are
the Mac user's (`tools/wine-patches/cx-real-user-name.patch`, so a space keeps its saves and Steam login on either engine),
and Microsoft's Visual C++ runtime in a space wins over Wine's builtin (some games check its version before they start).
Its archive holds no third-party runtime libraries: G-Player copies FreeType, GnuTLS and SDL2 from Gcenx's Wine Staging
download on the user's Mac (an installed Wine Staging's, or the archive downloaded for them and deleted after). Game
videos that go through Media Foundation play through GStreamer 1.28.8 and Wine's
`winegstreamer`: G-Player downloads the GStreamer project's official macOS package once, copies the plugins and libraries
the engine lists into G-Player Wine, and points Wine at them (`GST_PLUGIN_SYSTEM_PATH_1_0`, a registry file of its own,
no plugin scanner), never at a GStreamer.framework the user installed. H.264 and HEVC go to Apple's VideoToolbox. There is
no FFmpeg, so WMV and other codecs outside that set may not play. Wine Staging doesn't have this: it uses a
GStreamer.framework only if the user installed one.

## Automatic graphics

Nobody has to know what DXVK or DXMT is. With the Recommended or Fast profile and no backend chosen under Advanced,
graphics are automatic, and `CompatResolver.graphicsCandidates` lists the backends worth trying for the game, best first:
the first is what Automatic has always picked, so a game that works changes nothing.

| Game | Candidates, in order (only those the engine can run now) |
|---|---|
| 64-bit DirectX 10/11 | D3DMetal (not 32-bit), DXMT, DXVK |
| DirectX 12 | D3DMetal; for Unity and Unreal, which start in DirectX 11 when asked, also DXMT and DXVK (not for an Unreal game built for DirectX 12 alone) |
| 32-bit DirectX 10/11 | DXVK, DXMT |
| DirectX 9 and older, OpenGL, Vulkan, unknown | today's choice only: G-Player swaps `d3d11`, `d3d10core` and `dxgi`, so no other backend would change anything |

WineD3D is never one of the others: it can't give DirectX 10 or 11 on Apple's OpenGL 4.1.

The game remembers what it learned (`Game.autoGraphics`: the backend that worked, the ones that failed, and the engine they
were learned on; it is ignored on any other engine). `CompatResolver.graphicsChoice` takes the backend that worked while it
is still a candidate, else the first candidate that hasn't failed, else today's choice. A game with one candidate learns
nothing. Choosing graphics by hand, or another profile, clears it. G-Player learns only from launches it started itself
on automatic graphics, in a space it may change, with graphics that are really what the game runs with (not a Steam that
was already open with settings G-Player doesn't know).

The rules for what G-Player does by itself are in `GraphicsRetry` (core, tested); the app carries them out:

- **On a log's evidence, by itself.** A launch whose log (Wine's, the game's, or Unity's own Player.log, which counts only if
  its first lines name the game's folder) shows the graphics failing or a crash, that ended within about 30 seconds,
  with another backend to try, is played again with the next one, saying so in the sidebar. The note has Stop, and so does the game's button; either ends the
  tries. The failed backend is written down once the new launch has started, not before. A launch that would have to ask
  something (a blocker, an outside space, a Steam with other games open) isn't made, and the failure is shown instead.
  A Steam game gets Steam closed first, without a question, only when nothing else in its space is open, starting or
  being installed; other launches through that Steam are refused while it restarts.
- **Never on a guess.** A game that closes within seconds, or never opens, may be a player quitting, a slow first start of
  Steam or a program handing over to the real one; trouble in a log after a longer run may be a crash at exit or a
  DirectX 12 failure line followed by a working DirectX 11 fallback. These are shown as the usual failure, with "Try
  Other Graphics" when there is another backend: the click is the user's word, and then the same retry runs.
- **When nothing is left**, the usual failure message shows, with the graphics that were tried.
- **A game that runs for a minute** saves its backend as the one that worked.
- **"Picture Missing? Try Other Graphics"** on a running game that G-Player started on automatic graphics, since a black or
  frozen window can't be told from one that works. It asks first (the game closes, and Steam too for a Steam game), then
  writes the backend down as not working, stops that game's programs, and plays it again with the next one.

How it runs says which graphics are used and why, with "Start Over" to forget what was learned.

## Fixes in the engine itself

Some problems sit in Wine, not in the game. G-Player keeps a small set of fixed files and puts them into the Wine
it downloaded, only over the exact file they were made for, keeping the original as `<file>.gcenx`:

- `wow64cpu.dll` (Wine Staging 11.18), built from Wine's source (`tools/wine-patches`): under Rosetta 2, Wine's far
  jumps between 32- and 64-bit code sometimes don't switch the CPU mode, and 32-bit programs die in a cascade of
  access violations (WineHQ 60494). The fixed file uses a far call and `lretq` instead, as CrossOver does.
- `libMoltenVK.dylib` (Wine Staging 11.18): MoltenVK 1.4.2 from the Khronos release, unchanged
  (`scripts/fetch-moltenvk.sh`), in place of 1.4.0. A 32-bit program's Vulkan memory has to sit below 4 GB, so
  Wine allocates it itself and hands it to Vulkan as host memory (`VK_EXT_external_memory_host`). MoltenVK 1.4.0
  refused buffers and images made for such memory, so DXVK couldn't create a device and every 32-bit
  DirectX 10/11 game failed at start. 1.4.1 and later accept them.

Unreal games with DirectX 12 start with `-dx11` on an engine without D3DMetal, since most can fall back. A game cooked
for DirectX 12 alone can't (it stops with "Unable to launch with RHI 'D3D11' since the project is not configured to
support it"). G-Player tells them apart by the shader files the game ships: names like
`ShaderArchive-<Project>-PCD3D_SM6-PCD3D_SM6.ushaderbytecode` in the `.utoc` table of contents or
`GlobalShaderCache-PCD3D_SM6.bin` in the `.pak` index, with no `PCD3D_SM5` ones. Such a game gets no `-dx11` and a
"Needs DirectX 12" note: it runs on Apple's D3DMetal, in a space on Apple's toolkit. An encrypted pak index names
nothing, and then the game keeps the fallback.

G-Player Wine's ntdll (CrossOver 26.3.0's, with Alexander Theißen's change, `tools/wine-patches/cx-nx-compat.patch`): Wine
turned no-execute off for a whole 32-bit process as soon as one DLL in it lacked the `NX_COMPAT` flag, which old Microsoft
DLLs (xinput1_3, d3dx9, XACT, OpenAL32: what the common Windows components add) do, and Metal on macOS 26 then failed
every frame, so a 32-bit Unity game showed a black window. The fixed ntdll decides from the main program alone, as Windows
does; details are in `tools/wine-patches/README.md`. G-Player Wine 26.3.0-2 is built with it; `EngineFixes` puts the fixed
files into 26.3.0-1 (the retired revision) only over the exact files that release ships. If a game needs the old behaviour, `WINE_DISABLE_NX_COMPAT=0` in the game's own environment
variables (the `environment` of its library entry; the app has no field for it yet) gives it back for that game.

32-bit DirectX 10/11 needs DXVK: WineD3D can't give DirectX 10 or 11 on Apple's OpenGL 4.1, so the Compatible
profile warns about it.

A Unity game whose earlier start failed can save a screen size of 0×0 and crash on every start after
("Failed to create RenderTexture (0 x 0 …)"). When the game's settings in the space hold 0×0, G-Player passes the
main display's size (`-screen-width`, `-screen-height`; 80% of it when the game runs in a window, and pixels rather
than points in Retina mode), which Unity then saves. The space isn't changed. Wine writes the registry to disk every
30 seconds, so a start right after the failed one can still see the old file.

## Epic Games Launcher

Epic's own launcher (the 2026 build, CEF 90) opens on G-Player Wine and reaches its sign-in page. It doesn't on Wine Staging
11.18, where its network service and GPU process crash in a loop; G-Player Wine carries CodeWeavers' hacks for this launcher
in `kernelbase` and `advapi32`. The recipe, in `AppPreset.epic` (`engineRecipes`, `needsGPlayerWine`), decided per engine kind
(`helpersToWrap`, `helpersToUnwrap`, `launcherBackend(on:ready:)`):

- **G-Player Wine.** New launcher spaces are made on it, and a space on another engine is offered "Move to G-Player Wine…".
- **No helper wrapper.** On G-Player Wine the wrapper makes the network service crash again and again ("Network service
  crashed, restarting service"); with Epic's own `EpicWebHelper.exe` there is no crash and the sign-in page loads. A space
  that was wrapped gets it back before the next start: `EpicWebHelper_real.exe` is copied over `EpicWebHelper.exe`, only
  where that file is exactly the wrapper G-Player ships, and only in a space G-Player may change. Nothing is deleted.
- **D3DMetal if you added it, DXMT otherwise, for the launcher itself**, whatever its library entry says: D3DMetal when it
  is ready on the engine (it also lets DirectX 12 games the launcher starts run), else DXMT (its `d3d11`, `d3d10core` and
  `dxgi` go into the space as native copies, `dxgi,d3d11,d3d10core=n,b`). With either the launcher gets feature level 11_1,
  creates its swap chain and doesn't restart, and its sign-in page loads with no network-service or GPU crash. Nothing
  else works for the 2026 launcher: on **DXVK** its renderer fails `IDXGIFactory1::CreateSwapChain` (0x80004005) and the
  launcher restarts itself about every 5 seconds with `-AllowSoftwareRendering`; on **WineD3D** (builtin, OpenGL 4.1) it
  falls back to `-AllowSoftwareRendering` and crashes with an access violation reading address 0; `-opengl` crashes it too.
- **Wine Staging** is set up as before (wrapper, the engine's usual graphics); it isn't known to help there.

Games the launcher starts inherit its environment, so they run on its graphics (D3DMetal or DXMT) too; G-Player can't give
a game started from inside the launcher graphics of its own. Epic Games without the launcher (Legendary) starts each game through
G-Player's own launch, with its own.

Lines in the launcher's log that mean nothing: `WSALookupServiceBegin failed`, "Memory pressure detected … commit limit",
and a failure to create the process for `curl.exe`.

## Spaces from other apps

A CrossOver or Whisky bottle, or a prefix you made by hand, is used in place. G-Player changes nothing in it until you
allow it, once per space: the first launch that would change it asks. Allowing it lets G-Player install components,
write registry values (per-program DLL and Windows-version settings, Retina mode, and removing values it set before),
copy DXVK's DLLs over Wine's own (keeping Wine's copies as `*.gplayer-wine`) and put Steam's helper wrapper in place.
Refusing starts games and launchers with the space as it is; their inspector says so, with a button to allow changes
later.
Spaces G-Player made itself are always set up as needed.

## Order of the layers

The first one is the base; later ones win where they set the same thing.

1. The space's preset recipe (Steam's flags and environment, say), underneath everything.
2. Base components (`vcrun2022`, `d3dcompiler_47`).
3. The profile: the graphics backend, and Compatible's environment.
4. Engine defaults, which see the backend the profile chose (a DirectX 12 game on D3DMetal needs no fallback).
5. Known fixes: components, DLL settings, environment, launch options, registry values, Windows versions. Compatible
   keeps only the components of a fix.
6. The plain-word switches: Retina, frame rate.
7. Your own arguments and environment, which win over everything above.
