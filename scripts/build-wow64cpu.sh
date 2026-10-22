#!/usr/bin/env bash
# Rebuilds Sources/GPlayerCore/Resources/engine-fixes/wow64cpu.dll: Wine 11.18's wow64cpu with the Rosetta 2
# far-jump workaround (tools/wine-patches/wow64cpu-rosetta.patch). Needs: brew install mingw-w64 bison.
# Takes a few minutes; works in a temporary folder.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
VERSION=11.18
SHA256=c6282f6d4daecf11f3ab9f9a2b6c598f67be7e28c363ba2cae8a3c44b611e7a4
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
curl -fsSL -o wine.tar.xz "https://dl.winehq.org/wine/source/11.x/wine-$VERSION.tar.xz"
echo "$SHA256  wine.tar.xz" | shasum -a 256 -c -
tar xf wine.tar.xz
(cd "wine-$VERSION" && patch -p1 < "$REPO/tools/wine-patches/wow64cpu-rosetta.patch")
mkdir build && cd build
# Only the PE side is needed; the Mac side is configured just enough to build Wine's own tools.
arch -x86_64 "../wine-$VERSION/configure" --enable-archs=x86_64 --disable-tests --without-x --without-freetype \
  --without-gstreamer --without-cups --without-sane --without-gphoto --without-krb5 --without-netapi --without-pcap \
  --without-usb --without-v4l2 --without-sdl --without-capi --without-gnutls --without-vulkan --without-opencl \
  --without-coreaudio --without-pulse --without-alsa --without-oss --without-dbus --without-udev --without-unwind \
  --without-inotify --without-ffmpeg CC="clang -arch x86_64" BISON="$(brew --prefix bison)/bin/bison" > configure.log
arch -x86_64 make -j"$(sysctl -n hw.ncpu)" dlls/wow64cpu/x86_64-windows/wow64cpu.dll > make.log
BUNDLED="$REPO/Sources/GPlayerCore/Resources/engine-fixes/wow64cpu.dll"
x86_64-w64-mingw32-strip -o wow64cpu.dll dlls/wow64cpu/x86_64-windows/wow64cpu.dll
# Two builds differ only in the PE time stamp, header checksum and build id, so compare the code and data.
same=yes
for part in -d "-s -j .rdata" "-s -j .data" "-s -j .edata" "-s -j .pdata" "-s -j .xdata" "-s -j .reloc"; do
  cmp -s <(x86_64-w64-mingw32-objdump $part wow64cpu.dll | tail -n +4) \
         <(x86_64-w64-mingw32-objdump $part "$BUNDLED" | tail -n +4) || same=no
done
if [ "$same" = yes ]; then
  echo "Same code and data as the bundled $BUNDLED (only build stamps differ). Nothing to change."
else
  cp wow64cpu.dll "$BUNDLED"
  shasum -a 256 "$BUNDLED"
  echo "The code changed: update EngineFixes.wow64cpu.fixedSHA256 to the checksum above."
fi
