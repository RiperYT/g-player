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
the game even when an already running Steam starts it. Environment variables, and the Compatible and Custom
profiles, reach the game only if Steam is started for that launch, because a running Steam starts games with the
environment it got; such a launch is marked so the app can ask to restart Steam first. Registry values that a
launch set for a program and that a later launch no longer wants are removed again (`RegistryFile.removals`).

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
