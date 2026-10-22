#!/usr/bin/env bash
# Builds build/G-Player.app from the Swift package.
#   scripts/build-app.sh                 ad-hoc signed (runs on this Mac; others must allow it once)
#   SIGN_IDENTITY="<a signing identity>" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

swift build -c release --arch arm64 --product GPlayer
BIN="$(swift build -c release --arch arm64 --show-bin-path)/GPlayer"

APP=build/G-Player.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GPlayer"
# Everything in GPlayerCore/Resources (wrapper, fix database, detection rules, licenses) goes into the bundle.
cp -R Sources/GPlayerCore/Resources/. "$APP/Contents/Resources/"
[ -f build/AppIcon.icns ] || swift scripts/make-icon.swift build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE NOTICE "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" scripts/Info.plist > "$APP/Contents/Info.plist"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  # Every Mach-O in the app must carry the same team's signature. The bundled engine fixes are signed where they are
  # kept, since EngineFixes pins their checksums, so this only checks them.
  TEAM="$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$SIGN_IDENTITY")"
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q Mach-O || continue
    info="$(codesign -dv "$f" 2>&1 || true)"     # read whole: grep -q would cut the pipe under pipefail
    [[ "$info" == *"TeamIdentifier=$TEAM"* ]] || { echo "${f#$APP/} isn't signed by $TEAM" >&2; exit 1; }
  done < <(find "$APP/Contents/Resources" -type f -print0)
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --options runtime --timestamp=none --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "app: $APP ($VERSION, build $BUILD)"
