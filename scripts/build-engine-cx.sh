#!/usr/bin/env bash
# Builds G-Player Wine: Wine 11 from CodeWeavers' CrossOver source, ready for Apple's D3DMetal, with
# DXMT (Direct3D 10/11 on Metal) beside it. Steam runs on it, and DirectX 12 games run through D3DMetal in the same
# space, so they can sign in online.
#   scripts/build-engine-cx.sh [revision]      -> $OUT_DIR/g-player-engine-cx<version>-<revision>.tar.xz
#                                                 and ...-wine-source.tar.xz, the exact Wine source it was built from
#
# Adapted from MaPC's engine/build-engine-d3dmetal.sh (MacadeKit, Copyright 2026 Steale LLC, Apache-2.0).
# Why CrossOver's Wine: D3DMetal needs hooks only CodeWeavers' tree has (winemac's `macdrv_functions`, ntdll's
# `__wine_unix_call` export and its libd3dshared loader), and CrossOver's Wine has the Rosetta 2 far-jump fix.
#
# Every download is pinned by SHA-256. Wine is compiled here from CodeWeavers' published source with G-Player's
# patches in tools/wine-patches/cx-*.patch (one so far: the Mac user's name instead of "crossover").
# No Apple software is part of this build or of the engine: G-Player copies D3DMetal from the user's own Game
# Porting Toolkit at run time (D3DMetalStore). Wine links against the x86_64 runtime libraries of Gcenx's Wine
# Staging 11.18 (FreeType, GnuTLS, SDL2); they are not in the archive: G-Player copies them from Gcenx's own download
# when it installs the engine. Vulkan goes straight to MoltenVK (G-Player's 1.4.2), as in CrossOver: CrossOver's Wine
# doesn't ask the Vulkan loader for portability drivers, so through the loader it would find no Vulkan at all.
#
# Env: WORK_DIR (default build/engine-cx), OUT_DIR (default build/engine-dist), RESUME=1 keeps the build tree.
# Needs: Xcode, Rosetta, `brew install bison freetype gnutls sdl2 mingw-w64`.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
REVISION="${1:-1}"
WORK="${WORK_DIR:-$REPO/build/engine-cx}"; OUT="${OUT_DIR:-$REPO/build/engine-dist}"
CACHE="$WORK/dl"
mkdir -p "$CACHE" "$OUT"

CX_VERSION="26.3.0"
CX_NAME="crossover-sources-$CX_VERSION.tar.gz"
CX_URL="https://media.codeweavers.com/pub/crossover/source/$CX_NAME"
CX_SHA="ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872"
RUNTIME_NAME="wine-staging-11.18-osx64.tar.xz"        # the same pin as EngineCatalog.wineStaging
RUNTIME_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/$RUNTIME_NAME"
RUNTIME_SHA="b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127"
# DXMT v0.80 is the last MIT release (later ones are LGPL). It needs winemac's `macdrv_functions` table.
DXMT_NAME="dxmt-v0.80-builtin.tar.gz"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/v0.80/$DXMT_NAME"
DXMT_SHA="8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"
DXMT_LICENSE_URL="https://raw.githubusercontent.com/3Shain/dxmt/v0.80/LICENSE"
DXMT_LICENSE_SHA="6b928413c6308c106f3e0080bd94b6427b56d587d400fd40e6cbfbab7d9c4ae1"
NAME="g-player-engine-cx$CX_VERSION-$REVISION"

command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "need mingw-w64 (brew install mingw-w64)" >&2; exit 1; }
BREW="$(brew --prefix)"
[ -x "$BREW/opt/bison/bin/bison" ] || { echo "need bison >= 3 (brew install bison)" >&2; exit 1; }

fetch() { # name url sha
  local f="$CACHE/$1"
  if [ ! -f "$f" ]; then curl -fL --retry 3 -sS -o "$f.part" "$2"; mv "$f.part" "$f"; fi
  [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$3" ] || { echo "checksum mismatch: $1 (moved aside)" >&2; mv "$f" "$f.bad"; exit 1; }
}
fetch "$CX_NAME" "$CX_URL" "$CX_SHA"
fetch "$RUNTIME_NAME" "$RUNTIME_URL" "$RUNTIME_SHA"
fetch "$DXMT_NAME" "$DXMT_URL" "$DXMT_SHA"
fetch "dxmt-v0.80-LICENSE" "$DXMT_LICENSE_URL" "$DXMT_LICENSE_SHA"

# --- 1. Runtime libraries (x86_64) from the pinned Gcenx build -------------------------------------------
rm -rf "$WORK/runtime" && mkdir -p "$WORK/runtime"
tar -xJf "$CACHE/$RUNTIME_NAME" -C "$WORK/runtime"
RLIB="$(ls -d "$WORK"/runtime/*.app/Contents/Resources/wine/lib)"
cp "$REPO/Sources/GPlayerCore/Resources/engine-fixes/libMoltenVK.dylib" "$RLIB/libMoltenVK.dylib"
# Link-time copies carry `@rpath/libX.N.dylib` ids so configure records versioned sonames.
DEPS="$WORK/deps"; rm -rf "$DEPS" && mkdir -p "$DEPS/lib" "$DEPS/include"
for pair in libgnutls:libgnutls.30 libfreetype:libfreetype.6 libSDL2:libSDL2-2.0.0 libMoltenVK:libMoltenVK; do
  cp "$RLIB/${pair#*:}.dylib" "$DEPS/lib/${pair%%:*}.dylib"; chmod u+w "$DEPS/lib/${pair%%:*}.dylib"
  install_name_tool -id "@rpath/${pair#*:}.dylib" "$DEPS/lib/${pair%%:*}.dylib" 2>/dev/null
done
ln -s "$BREW/opt/freetype/include/freetype2" "$DEPS/include/freetype2"
ln -s "$BREW/opt/gnutls/include/gnutls" "$DEPS/include/gnutls"
ln -s "$BREW/opt/sdl2/include/SDL2" "$DEPS/include/SDL2"

# --- 2. Wine from CrossOver's source ---------------------------------------------------------------------
# No GStreamer for now: game videos that go through Media Foundation need the GStreamer framework, which this
# build doesn't link (Gcenx's engine links it, but only finds it when the user installed GStreamer.framework).
CLEAN_ENV=(/usr/bin/env -i HOME="$HOME" PATH="$BREW/opt/bison/bin:$BREW/bin:/usr/bin:/bin:/usr/sbin:/sbin" MACOSX_DEPLOYMENT_TARGET=14.0)
if [ "${RESUME:-0}" != 1 ] || [ ! -f "$WORK/build/Makefile" ]; then
  rm -rf "$WORK/sources/wine" "$WORK/build"
  tar -xzf "$CACHE/$CX_NAME" -C "$WORK" sources/wine
  for patch in "$REPO"/tools/wine-patches/cx-*.patch; do
    ( cd "$WORK/sources/wine" && patch -p1 --forward < "$patch" > /dev/null ) || { echo "patch failed: $patch" >&2; exit 1; }
  done
  mkdir -p "$WORK/build"
  ( cd "$WORK/build" && "${CLEAN_ENV[@]}" \
      CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64" \
      FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
      GNUTLS_CFLAGS="-I$DEPS/include" GNUTLS_LIBS="-L$DEPS/lib -lgnutls" \
      SDL2_CFLAGS="-I$DEPS/include/SDL2 -D_THREAD_SAFE" SDL2_LIBS="-L$DEPS/lib -lSDL2" \
      LDFLAGS="-L$DEPS/lib -Wl,-rpath,@loader_path/../../" \
      ac_cv_func_pipe2=no \
      ../sources/wine/configure --build=x86_64-apple-darwin --host=x86_64-apple-darwin --prefix="$WORK/stage" \
        --enable-archs=i386,x86_64 --disable-tests --disable-win16 \
        --with-mingw --with-freetype --with-gnutls --with-sdl --with-vulkan --with-coreaudio --with-opencl --with-unwind \
        --without-x --without-wayland --without-alsa --without-oss --without-udev --without-v4l2 --without-capi \
        --without-inotify --without-pulse --without-dbus --without-netapi --without-krb5 --without-gssapi \
        --without-fontconfig --without-sane --without-gphoto --without-gstreamer --without-ffmpeg --without-usb \
        > configure.out 2>&1 ) || { echo "configure failed; see $WORK/build/configure.out" >&2; exit 1; }
fi
grep -q '^#define SONAME_LIBMOLTENVK "libMoltenVK.dylib"' "$WORK/build/include/config.h" \
  || { echo "configure didn't take MoltenVK for Vulkan; see $WORK/build/configure.out" >&2; exit 1; }
# Build-time tools (sfnt2fon links FreeType) get the same `@loader_path/../../` rpath as Wine's modules;
# from build/tools/<tool>/ that is the build root, so the runtime libraries go there too.
cp -a "$RLIB"/*.dylib "$WORK/build/"
rm -rf "$WORK/stage"
( cd "$WORK/build" && "${CLEAN_ENV[@]}" make -j"$(sysctl -n hw.ncpu)" > make.out 2>&1 \
  && "${CLEAN_ENV[@]}" make install > install.out 2>&1 ) \
  || { echo "Wine build failed; see $WORK/build/make.out and install.out" >&2; exit 1; }

# The SDK can be newer than the oldest macOS the engine supports. Functions only a newer macOS has are weak
# imports, NULL on older systems (MaPC's engine 2.0.1 crashed at start on macOS 26 through pipe2), hence
# ac_cv_func_pipe2=no above and this check: weak imports must be ones Wine's source guards.
# dispatch_once_f has been in libdispatch since macOS 10.6, so its weak import is never NULL.
GUARDED_WEAK='^(dispatch_once_f|ulock_wait2|availability_version_check|os_sync_wait_on_address|os_sync_wait_on_address_with_timeout|os_sync_wake_by_address_any|clCreateImage2D|clCreateImage3D|clEnqueueBarrier|clEnqueueMarker|clEnqueueWaitForEvents|clUnloadCompiler)$'
for bin in "$WORK"/stage/bin/wine "$WORK"/stage/bin/wineserver "$WORK"/stage/lib/wine/x86_64-unix/*.so; do
  [ -L "$bin" ] && continue
  unguarded="$(dyld_info -imports "$bin" 2>/dev/null | grep weak-import | grep -oE '_[A-Za-z0-9_]+' | sed 's/^_*//' \
    | grep -vE "$GUARDED_WEAK" || true)"
  [ -z "$unguarded" ] || { echo "$(basename "$bin") weak-imports $unguarded: check it is guarded, or pin it off in configure" >&2; exit 1; }
done

# --- 3. Assemble the engine ------------------------------------------------------------------------------
ENG="$WORK/engine"; rm -rf "$ENG" && mkdir -p "$ENG"
cp -R "$WORK/stage" "$ENG/wine"
W="$ENG/wine"
rm -rf "$W/include" "$W/share/man" "$W/share/applications"
find "$W/lib/wine" -name "*.a" -delete
# Only MoltenVK goes in; the other runtime libraries come from Gcenx's download at install time.
cp "$RLIB/libMoltenVK.dylib" "$W/lib/"
# Wine dlopens these by leaf name through the calling module's rpaths (`@loader_path/../../` = wine/lib).
for so in ntdll win32u bcrypt winebus; do
  otool -l "$W/lib/wine/x86_64-unix/$so.so" | grep -q "path @loader_path/../../ " || { echo "no rpath in $so.so" >&2; exit 1; }
done
for lib in libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib; do
  [ -f "$RLIB/$lib" ] || { echo "Gcenx's build no longer has $lib, which this engine expects at install" >&2; exit 1; }
done
for bin in "$W"/bin/wine "$W"/bin/wineserver "$W"/lib/wine/x86_64-unix/*; do
  [ -L "$bin" ] || [ -d "$bin" ] && continue
  refs="$(otool -L "$bin" | tail -n +2; otool -l "$bin" | grep -A2 LC_RPATH || true)"
  if grep -qF "$WORK" <<<"$refs"; then echo "build path leaked into $bin" >&2; exit 1; fi
done

# DXMT: d3d11/d3d10core/dxgi wait in lib/dxmt and go into a space as native DLLs when a game uses DXMT, so they
# never replace Wine's or D3DMetal's. winemetal, its bridge to Metal, is a builtin.
tar -xzf "$CACHE/$DXMT_NAME" -C "$WORK"
DXMT="$WORK/v0.80"
for arch in x86_64 i386; do
  mkdir -p "$W/lib/dxmt/$arch-windows"
  cp "$DXMT/$arch-windows/"{d3d11,d3d10core,dxgi}.dll "$W/lib/dxmt/$arch-windows/"
  cp "$DXMT/$arch-windows/winemetal.dll" "$W/lib/wine/$arch-windows/"
done
cp "$DXMT/x86_64-unix/winemetal.so" "$W/lib/wine/x86_64-unix/"
nm -gU "$W/lib/wine/x86_64-unix/winemac.so" | grep -q " _macdrv_functions$" \
  || { echo "winemac.so doesn't export macdrv_functions; DXMT can't create its Metal view" >&2; exit 1; }

# Licenses and how this build was made (the LGPL's "scripts used to control compilation").
mkdir -p "$ENG/licenses/build" "$ENG/licenses/wine-libs"
cp "$WORK/sources/wine/COPYING.LIB" "$ENG/licenses/Wine-COPYING.LIB.txt"
cp "$REPO/Sources/GPlayerCore/Resources/licenses/"{MoltenVK-LICENSE.txt,SPIRV-Headers-LICENSE.txt,cereal-LICENSE.txt} "$ENG/licenses/"
cp "$CACHE/dxmt-v0.80-LICENSE" "$ENG/licenses/DXMT-LICENSE.txt"
for f in "$WORK"/sources/wine/libs/*/{COPYING,LICENSE,COPYRIGHT}*; do
  [ -f "$f" ] && cp "$f" "$ENG/licenses/wine-libs/$(basename "$(dirname "$f")")-$(basename "$f").txt"
done
cp "$REPO/scripts/build-engine-cx.sh" "$REPO"/tools/wine-patches/cx-*.patch "$ENG/licenses/build/"
cat > "$ENG/licenses/NOTICE.txt" <<TXT
G-Player Wine $CX_VERSION-$REVISION, built from CodeWeavers' CrossOver source (not CrossOver, and not made or endorsed
  by CodeWeavers; "CrossOver" is CodeWeavers' trademark).
Wine (LGPL-2.1+), built from CodeWeavers' CrossOver $CX_VERSION source ($CX_URL, sha256 $CX_SHA) with
  the patches in build/ (cx-*.patch). The exact source it was built from, patches applied, is attached to this
  engine's release on github.com/RiperYT/g-player as $NAME-wine-source.tar.xz; the build script with every pin it
  uses is in build/ (build-engine-cx.sh). Wine's license: Wine-COPYING.LIB.txt; libraries it builds in: wine-libs/.
DXMT v0.80 (MIT, Copyright (c) 2023 Feifan He), unmodified from $DXMT_URL (sha256 $DXMT_SHA): DXMT-LICENSE.txt.
MoltenVK 1.4.2 (Apache-2.0) from the Khronos release; licenses of what it contains are in this folder.
Not in this archive: the runtime libraries Wine loads (FreeType, GnuTLS, SDL2 and what they use).
  G-Player copies them on the user's Mac from Gcenx's Wine Staging 11.18 download ($RUNTIME_URL,
  sha256 $RUNTIME_SHA), under their own licenses.
No Apple software is included. DirectX 12 uses Apple's D3DMetal, which G-Player copies from the user's own
  download of Apple's Game Porting Toolkit; the user's use of it is governed by Apple's license.
TXT
cat > "$ENG/ENGINE.json" <<JSON
{ "name": "$NAME", "wine": "11, from CrossOver $CX_VERSION source", "backends": ["d3dmetal", "dxmt", "dxvk", "wined3d"], "minMacOS": "14.0", "runtimeLibraries": "$RUNTIME_NAME" }
JSON

# --- 4. Package ------------------------------------------------------------------------------------------
ARCHIVE="$OUT/$NAME.tar.xz"
rm -f "$ARCHIVE"
XZ_OPT="-T0 -6" tar -cJf "$ARCHIVE" -C "$ENG" .
# The corresponding source (LGPL): the Wine tree this engine was built from, patches applied.
SOURCE="$OUT/$NAME-wine-source.tar.xz"
rm -f "$SOURCE"
XZ_OPT="-T0 -6" tar -cJf "$SOURCE" -C "$WORK/sources" wine
echo "engine: $ARCHIVE ($(( $(stat -f%z "$ARCHIVE") / 1048576 )) MB)"
echo "source: $SOURCE ($(( $(stat -f%z "$SOURCE") / 1048576 )) MB)"
shasum -a 256 "$ARCHIVE" "$SOURCE"
