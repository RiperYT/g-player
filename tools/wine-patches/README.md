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
- `EngineFixes` puts it into Wine Staging 11.18 only when the file there is the exact one Gcenx's build ships, and
  keeps that original next to it as `wow64cpu.dll.gcenx`.

Rebuilding gives a file that differs from the bundled one only in the PE time stamp, header checksum and build id;
`scripts/build-wow64cpu.sh` compares the code and data sections and says whether they match.
