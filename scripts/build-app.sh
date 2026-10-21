#!/usr/bin/env bash
# Builds build/G-Player.app from the Swift package.
#   scripts/build-app.sh                 ad-hoc signed (runs on this Mac; others must allow it once)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
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
cp Sources/GPlayerCore/Resources/chromium-helper-wrapper.exe "$APP/Contents/Resources/"
[ -f build/AppIcon.icns ] || swift scripts/make-icon.swift build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE NOTICE "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" scripts/Info.plist > "$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "app: $APP ($VERSION, build $BUILD)"
