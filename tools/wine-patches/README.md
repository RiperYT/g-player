# Wine patches

Small fixes G-Player applies to the Wine it downloads. Each one is built from Wine's source with the patch here,
so the result is as open as Wine itself (LGPL-2.1+, see `Sources/GPlayerCore/Resources/licenses/Wine-COPYING.LIB.txt`).

## wow64cpu-rosetta.patch

Wine 11.18's `wow64cpu.dll` switches between 32-bit and 64-bit code with far jumps (`ljmp`). Under Rosetta 2 on
Apple Silicon a far jump sometimes doesn't switch the CPU mode, so 64-bit code runs as 32-bit and the program dies
in a cascade of access violations (WineHQ bug 60494). 32-bit Windows programs are hit; in our tests Cossacks 3
crashed on every start and Overcooked never got far.

The patch takes the approach of CodeWeavers' CrossOver ("CW HACK 20760", LGPL like the rest of Wine): when the
processor brand says "VirtualApple" (Rosetta 2), it enters 64-bit code with a far call and returns to 32-bit code
with `lretq`. Elsewhere nothing changes.

- Built by `scripts/build-wow64cpu.sh` from the Wine 11.18 source tarball (SHA-256 pinned there).
- Shipped as `Sources/GPlayerCore/Resources/engine-fixes/wow64cpu.dll`.
- The fix is for Wine Staging 11.18 only; a new engine version needs a rebuilt file and a new `EngineFixes` entry.
- `EngineFixes` puts it into Wine Staging 11.18 only when the file there is the exact one Gcenx's build ships, and
  keeps that original next to it as `wow64cpu.dll.gcenx`.

Rebuilding gives a file that differs from the bundled one only in the PE time stamp, header checksum and build id;
`scripts/build-wow64cpu.sh` compares the code and data sections and says whether they match.

## cx-real-user-name.patch

For G-Player Wine, built from CodeWeavers' CrossOver 26.3.0 source by `scripts/build-engine-cx.sh`. CrossOver names
every user "crossover" (CrossOver Hack 12735): `GetUserName` says so and the profile folder is `C:\users\crossover`.
The patch takes that back to upstream Wine's behaviour, the Mac user's name, as Wine Staging has it. A space then keeps
the same profile folder, saves and Steam login (Wine's DPAPI is keyed on the user name) on either engine.

- Applied to the extracted source before `configure`; the exact patched tree is published with the engine's release
  (`g-player-engine-cx26.3.0-<revision>-wine-source.tar.xz`), with this patch and the script inside the engine too.

## cx-nx-compat.patch

For G-Player Wine. Alexander Theißen's change to Wine's ntdll (athei/wine commit
`539aa62220ad23a390ce9f2a1c99ee5d3831907b`, LGPL like the rest of Wine), unchanged. Wine turned no-execute off for a
whole 32-bit process as soon as any DLL in it lacked the `NX_COMPAT` flag, which makes every readable mapping
executable. Old Microsoft DLLs don't have the flag (xinput1_3, d3dx9_24–31, the XACT and X3DAudio DLLs, OpenAL32 —
the common Windows components put them into a space), and on macOS 26 Metal then fails every command buffer with
"Insufficient Memory": a 32-bit Unity game showed a black window on DXVK and on DXMT. Windows decides from the main
program only; the patch does the same, and under Rosetta keeps no-execute permanently on (a writable and executable
page costs Rosetta a round trip on first touch). `WINE_DISABLE_NX_COMPAT=0` gives back the Windows behaviour.

- Applied with the other `cx-*.patch` files by `scripts/build-engine-cx.sh`; G-Player Wine 26.3.0-1 was built
  before it, so `EngineFixes.ntdllNoExec` puts the three rebuilt files into that engine (`ntdll.so` and the
  x86_64 and i386 `ntdll.dll`), only over the exact files its release ships.
- The bundled files are `Sources/GPlayerCore/Resources/engine-fixes/cx-ntdll*`. Built in the engine's own build tree
  (the same tree and toolchain give byte-identical unpatched files), so the source is the engine's published source
  tarball plus this patch.
