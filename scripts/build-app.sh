#!/usr/bin/env bash
# Builds build/G-Player.app from the Swift package.
#   scripts/build-app.sh                 ad-hoc signed (runs on this Mac; others must allow it once)
#   SIGN_IDENTITY="<a signing identity>" scripts/build-app.sh
# The update key (scripts/sparkle-public-key.txt) goes into Info.plist when the file has one; a build without it never
# looks for updates.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

swift build -c release --arch arm64 --product GPlayer
BIN="$(swift build -c release --arch arm64 --show-bin-path)/GPlayer"
# Sparkle.framework as SwiftPM unpacked it (its checksum is verified by SwiftPM, pinned in Package.swift/Package.resolved).
SPARKLE=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
[ -d "$SPARKLE" ] || { echo "$SPARKLE is missing: run swift package resolve" >&2; exit 1; }
SPARKLE_KEY="$(tr -d '[:space:]' < scripts/sparkle-public-key.txt)"
[[ -z "$SPARKLE_KEY" || "$SPARKLE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "scripts/sparkle-public-key.txt isn't an EdDSA public key (44 characters of base64)" >&2; exit 1; }

APP=build/G-Player.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/GPlayer"
# SwiftPM's rpath points next to the executable in .build; in the app Sparkle is in Contents/Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/GPlayer"
rpaths="$(otool -l "$APP/Contents/MacOS/GPlayer")"                      # read whole: grep -q would cut the pipe under pipefail
[[ "$rpaths" == *"path @executable_path/../Frameworks "* ]] || { echo "the executable doesn't look in Contents/Frameworks" >&2; exit 1; }
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"          # ditto keeps the framework's symlinks
# Sparkle's XPC services are for sandboxed apps only (its documentation says to remove them otherwise): G-Player isn't.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
# Everything in GPlayerCore/Resources (wrapper, fix database, detection rules, licenses) goes into the bundle.
cp -R Sources/GPlayerCore/Resources/. "$APP/Contents/Resources/"
[ -f build/AppIcon.icns ] || swift scripts/make-icon.swift build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE NOTICE "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" scripts/Info.plist > "$APP/Contents/Info.plist"
[ -z "$SPARKLE_KEY" ] || plutil -insert SUPublicEDKey -string "$SPARKLE_KEY" "$APP/Contents/Info.plist"

# Sparkle's own code, inside out, as Sparkle's documentation says for an app Xcode doesn't build. Takes the codesign
# command to sign with.
sign_sparkle() {
  local framework="$APP/Contents/Frameworks/Sparkle.framework" b="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  "$@" "$b/Autoupdate"
  "$@" "$b/Updater.app"
  "$@" "$framework"
}

if [ -n "${SIGN_IDENTITY:-}" ]; then
  SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  sign_sparkle "${SIGN[@]}"
  # Every Mach-O in the app must carry the same team's signature. The bundled engine fixes are signed where they are
  # kept, since EngineFixes pins their checksums, so this only checks them (and Sparkle's, signed just above).
  TEAM="$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$SIGN_IDENTITY")"
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q Mach-O || continue
    info="$(codesign -dv "$f" 2>&1 || true)"     # read whole: grep -q would cut the pipe under pipefail
    [[ "$info" == *"TeamIdentifier=$TEAM"* ]] || { echo "${f#$APP/} isn't signed by $TEAM" >&2; exit 1; }
  done < <(find "$APP/Contents/Resources" "$APP/Contents/Frameworks" -type f -print0)
  "${SIGN[@]}" "$APP"
else
  sign_sparkle codesign --force --options runtime --timestamp=none --sign -
  # Without the hardened runtime: its library validation refuses a framework that isn't signed by the app's own team, and an
  # ad-hoc signature has no team, so the app couldn't load Sparkle.
  codesign --force --timestamp=none --sign - "$APP"
fi
codesign --verify --strict --deep "$APP"
echo "app: $APP ($VERSION, build $BUILD)"
