# Changelog

## [0.4.2] - 2026-10-23

- Safer edges found in review: Start Empty keeps the previous copy as `library.json.before-empty-<date>`; Locate… moves
  only the spaces G-Player made; Add Game checks the disk first, makes one space and reuses it on retry, removes a space
  it made and left empty, and Cancel works while an engine downloads; adding a game waits for setup however it is started
  (⌘N, a space's page, the Dock, Open With); shut down, restart and log out are never held up by the quit question;
  stopping the first run's download keeps Main and Steam waiting and says so; G-Player cleans up its own temporary
  downloads and unpacked installers at start; a download that is already complete is verified, not repeated; Rosetta's
  install can be cancelled; "Waiting for…" names what is running.
- **A library that can't be read is never replaced.** If `library.json` is damaged, or the library folder isn't there
  (a disk that isn't connected, a moved folder), G-Player copies the file to `library.json.broken-<date>`, writes
  nothing, and asks: Try Again, Locate…, Use Previous Copy or Start Empty. Saving keeps the file it replaces as
  `library.json.previous`. Choosing a moved library with Locate… points its spaces at the new folder.
- Only one G-Player runs at a time; opening it again brings the first one forward. Quitting while engines download, a
  space is made or something installs asks first; a Steam install that was cut short continues at the next start.
- **Engine downloads can be stopped, show "N of M MB", and go on where they stopped** after a dropped connection, a Stop
  or a quit. G-Player checks for about 2.7 GB of free space first and cleans up half-finished installs at start.
- Installing a store app twice at once no longer makes "Steam" and "Steam 2". Add Game and Run Program wait for
  Windows components being installed in the space; copying and unpacking a game show progress, can be cancelled and
  check free space, and Cancel no longer pulls the files from under a running installer. Removing an engine asks first
  and is refused while programs run on it.
- **A clearer first run.** The empty library says what setup is doing, how much it downloads (about 485 MB for both
  engines, about 2.7 GB on disk) and how far it is; adding a game waits until Main and the engines are ready. The
  engine step says nothing needs choosing, Rosetta shows an Installing state and never opens a second password window,
  and Apple's toolkit is marked optional.
- **Spaces and existing bottles.** One plain sentence says why spaces exist. New Space has Add Existing Space…, and
  bottles from CrossOver or Whisky come with a warning that G-Player Wine updates them on its first start.
- **D3DMetal, step by step.** The D3DMetal button opens Settings › Engines at the toolkit, which has a numbered how-to
  before the switch is on. Switching a space's engine names the engine, its download and whether it is newer or older
  Wine, waits while programs run in the space, and asks first in another app's space.
- One-time notes: spaces made before this version get a note that G-Player Wine is new; a finished Steam setup selects
  its tile and says what to do next. Wording of Automatic graphics, profiles, DirectX 12 and MoltenVK advice, the
  "didn't start" buttons (with Show Log), and "Allow changes" as a sheet with Details. An empty space no longer looks
  like a drop target.
- **A runaway Wine can no longer flood the Mac with processes.** G-Player won't create or add a space whose folder
  path is over 150 characters (the library folder is limited to 114), and long space names are shortened. If a space
  ever runs more than 12 Windows Explorer copies or 200 programs, G-Player stops everything in it and says why.
- **G-Player Wine is the recommended engine.** The first launch installs Wine Staging and then G-Player Wine, which
  reuses Staging's libraries, so nothing downloads twice. The first spaces (Main, Steam) are made once an engine is in,
  also after a quit before the downloads ended. A new space gets G-Player Wine, or Wine Staging while that is the only
  engine installed (no download when you're offline), and the pickers show each engine's size. If G-Player Wine can't be
  downloaded for a new space, Staging is used and G-Player says so. CrossOver and Whisky bottles found on the Mac get
  G-Player Wine; other prefixes keep their engine. Settings › Engines lists G-Player Wine first as Recommended. Spaces you
  already have keep their engine. Engine downloads no longer share files, and a download asked for twice at once is
  shared.
- **Releases are a disk image.** Open `G-Player-<version>.dmg` and drag G-Player onto Applications. The app is signed
  and notarized, so macOS opens it without asking; a newer version goes over the old one and the library stays.
- **Game volume on G-Player Wine.** Wine applied a game's own volume by writing the Mac's output volume, which failed
  on AirPods and the MacBook speakers (a game's volume setting did nothing) and changed the Mac's volume on outputs
  where it worked. G-Player Wine's CoreAudio driver now scales the game's sound itself, as Wine does on Linux, and never
  touches the Mac's volume; a program's recording volume and mute apply to what it records
  (`tools/wine-patches/cx-coreaudio-stream-volume.patch`, put into the installed engine like the other engine fixes, and
  over the first version of this fix).

## [0.4.1] - 2026-10-22

- **Automatic graphics.** With the Recommended or Fast profile, a game that fails because its graphics don't start (or crash)
  is played again with the next backend that makes sense for it (D3DMetal, DXMT, DXVK on G-Player Wine), and the game
  remembers which one worked, per game and per engine. G-Player acts by itself only on evidence in a log. A game that
  closes in seconds or never opens gets a "Try Other Graphics" button instead, and a game that runs but shows nothing has
  "Picture Missing? Try Other Graphics", which asks first. How it runs says which graphics are used and why, with "Start
  Over". Choosing graphics by hand, or another profile, forgets what was learned.
- Steam restarts: G-Player knows which settings it started Steam with, so a game's profile no longer asks for a restart
  each time, and closing Steam waits until the rest of its space has quit (a Steam started into the leftovers never got
  going). A Steam that G-Player closes for another try with other graphics isn't asked about when nothing else is open
  in it.
- Unity games: "Failed to initialize graphics" and "d3d11: failed to create device" in a game's own Player.log count as
  graphics that didn't start, and only the game's own log is read.
- **32-bit games no longer show a black window on G-Player Wine.** Wine turned no-execute off for a whole 32-bit
  program as soon as it loaded one old Microsoft DLL without the NX flag (xinput1_3, d3dx9, XACT, OpenAL — the common
  Windows components install them), and Metal on macOS 26 then failed every frame with "Insufficient Memory", on DXVK
  and DXMT alike. G-Player Wine's ntdll now decides from the program alone, as Windows does, and keeps no-execute on
  under Rosetta (Alexander Theißen's Wine patch, `tools/wine-patches/cx-nx-compat.patch`). The three rebuilt files go
  into the installed engine like the other engine fixes, only over the exact files its release ships. Checked with a
  32-bit Unity 2022 game on DXMT and DXVK.

## [0.4.0] - 2026-10-22

- **G-Player Wine: DirectX 12 with Steam open.** A new engine, Wine 11 that G-Player builds from CodeWeavers' CrossOver
  26.3 source (`scripts/build-engine-cx.sh`), with DXMT and MoltenVK 1.4.2. Steam runs on it, and with Apple's D3DMetal
  64-bit DirectX 10–12 games run through D3DMetal in the same space as Steam, with Steam signed in. Checked with a
  DirectX 12-only Unreal Engine 5.7 game started from Steam (it reached its menu and its online services), and with
  test programs on every backend.
- **Apple's D3DMetal from your own toolkit.** With Apple's toolkit turned on in Settings › Engines, G-Player copies
  D3DMetal, checking that D3DMetal.framework and libd3dshared.dylib are signed by Apple, from the toolkit you installed or from Apple's disk image you downloaded.
  It never ships or downloads Apple's files.
- **A blocked DirectX 12 game offers the way out:** "Move Space to G-Player Wine…" says what happens, downloads the
  engine, closes Steam, moves the space and starts the game (an outside space asks for changes first); without D3DMetal
  it opens Settings.
- Steam restarts for a game only when the game needs other settings than the ones G-Player started Steam with.
- New graphics backend **DXMT** (DirectX 10/11 straight to Metal, 32- and 64-bit) on G-Player Wine.
- A space keeps its saves and Steam login when it moves between Wine Staging and G-Player Wine: G-Player Wine uses the
  Mac user's name and profile folder, as Wine Staging does, where CrossOver's Wine says "crossover". (A bottle CrossOver
  itself made keeps its old `C:\users\crossover` folder, which neither engine uses.)
- G-Player now sees the programs of spaces kept under `/var` or `/tmp` (the kernel reports them through `/private`).
- The engine's release carries the exact Wine source it was built from. G-Player Wine isn't CrossOver and isn't made or
  endorsed by CodeWeavers.

## [0.3.5] - 2026-10-22

- **32-bit DirectX 10/11 games can start.** 32-bit Unity games such as Overcooked and other 32-bit DirectX 10/11
  games used to fail at start: MoltenVK 1.4.0, which Wine Staging 11.18 ships, refused the memory Wine sets up for
  32-bit programs. G-Player now puts the unchanged MoltenVK 1.4.2 from the Khronos release into the engine
  (1.4.1 fixed it), keeping the original as `libMoltenVK.dylib.gcenx`. The "32-bit Unity games don't run on a Mac
  yet" stop is gone; the Compatible profile warns instead, since WineD3D can't give DirectX 10/11 on Apple's OpenGL.
  Checked so far: test programs (32- and 64-bit, shaders and presenting) and two 32-bit Unity games, which showed
  their first screens.
- **Unity games that saved a 0×0 screen start again.** A failed start can leave a Unity game's settings at 0×0, and
  it then crashed on every start. G-Player passes the display's size when it finds that (80% of it for a window).
- **Unreal games built for DirectX 12 alone aren't broken by `-dx11` any more.** G-Player added `-dx11` to every
  Unreal game with DirectX 12, and one cooked without DirectX 11 shaders stops at start with "Unable to launch with
  RHI 'D3D11'". G-Player now reads the shader file names in the game's paks (`PCD3D_SM6` only) and, on an engine
  without D3DMetal, says the game needs DirectX 12 and how to run it on Apple's D3DMetal instead.
- Launch options G-Player adds no longer lose their values when you set some of your own (`-screen-fullscreen 0`
  stayed whole only if you had no `0` among your options).
- The 32-bit note in the inspector no longer says these games don't start.
- Files G-Player puts into the engine no longer carry the downloaded app's quarantine mark.

## [0.3.4] - 2026-10-22

- **A launch that fails says so in the middle of the window**, with what happened and the one thing to try, and
  G-Player comes to the front. The inspector keeps the same note.
- **Windows parts can install for Steam games.** Installers need the space to themselves, so with Steam open they
  used to wait forever and the same offer came back after every try. Now G-Player asks to close Steam for a minute,
  installs, and starts the game again.
- **Honest answers for 32-bit DirectX 11 games.** 32-bit Unity games (DirectX 11 in 32 bits) are flagged before
  launch, and a 32-bit DirectX 11 failure says that no component will help: DXVK can't get 32-bit Vulkan memory
  from MoltenVK and WineD3D can't give DirectX 11 on Apple's OpenGL 4.1.
- Unity games started by Steam are diagnosed from their own `Player.log`.

## [0.3.3] - 2026-10-22

- **Steam's window no longer turns black after Steam updates itself.** A Steam client update on start replaces the
  helper G-Player wraps, and Steam then opens its window without the fix. While Steam (or another launcher with
  Chromium helpers) runs, G-Player now puts the wrapper back as soon as it is gone, and restarts helpers that
  started without it if they don't stop by themselves; Steam starts them again with the fix. The first three
  minutes after opening Steam are watched closely.

## [0.3.2] - 2026-10-22

- **Components a game needs go in on their own.** G-Player reads which Windows DLLs a game's files import
  (DirectX 9–11 helpers, XAudio/XACT, XInput, Visual C++ 2008–2013, OpenAL, PhysX, XNA) and installs the matching
  components before the game first starts, skipping DLLs the game brings along. .NET is left to Wine Mono.
- **"Didn't start" is easy to act on.** A game that crashes or closes without saying why gets one big button,
  "Install Common Windows Parts (105 MB) and Play", and only then the Compatible profile. Its tile says
  "Didn't start · see what to try".
- Steam games that close within seconds, or never open, are noticed too (G-Player watches them come and go, since
  their output goes to Steam).
- README: how to open the app on macOS 15 and later (Privacy & Security › Open Anyway).

## [0.3.1] - 2026-10-22

- **32-bit Windows programs no longer crash under Rosetta 2.** Wine 11's switch between 32- and 64-bit code
  sometimes fails on Apple Silicon (WineHQ bug 60494), which killed 32-bit games at start. G-Player now puts a
  fixed `wow64cpu.dll` into Wine Staging 11.18, built from Wine's source with the approach CrossOver uses; the patch
  and its build script are in `tools/wine-patches` and `scripts/build-wow64cpu.sh`. The original file is kept as
  `wow64cpu.dll.gcenx`.
- **Running programs are seen even when G-Player didn't start them.** Steam opened by a game launch, a game Steam
  started, or anything still open after G-Player restarts now shows as Running with a Stop button. Games are told
  apart by their folder, so two games with the same .exe name don't mix, and a store game shows Starting until it
  opens. Stopping a Steam game leaves Steam open. The check that keeps installers out of busy spaces uses the same
  list, so it now also sees games started by Steam.
- Cossacks 3 is marked as not running on a Mac (it needs OpenGL 4.4 with the compatibility profile; macOS has 4.1
  core at most). The Overcooked note is updated.

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
