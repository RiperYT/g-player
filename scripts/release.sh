#!/usr/bin/env bash
# Packs a release into releases/v<version>/: a disk image that opens to G-Player and a shortcut to Applications to
# drag it onto, and its SHA-256. With --publish it is also attached to a GitHub release.
#   scripts/release.sh            build + disk image + checksums
#   scripts/release.sh --publish  also: gh release create v<version>
# SIGN_IDENTITY is passed on to scripts/build-app.sh; NO_BUILD=1 packs the build/G-Player.app that is already there.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
[ "${NO_BUILD:-0}" = 1 ] || scripts/build-app.sh
OUT="releases/v$VERSION"
mkdir -p "$OUT"
DMG="$OUT/G-Player-$VERSION.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R build/G-Player.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "G-Player $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
(cd "$OUT" && shasum -a 256 "G-Player-$VERSION.dmg" > SHA256SUMS)
echo "release: $DMG"
cat "$OUT/SHA256SUMS"
if [ "${1:-}" = "--publish" ]; then
  NOTES="$(awk "/^## \\[$VERSION\\]/{flag=1;next}/^## \\[/{flag=0}flag" CHANGELOG.md)"
  gh release create "v$VERSION" "$DMG" "$OUT/SHA256SUMS" --title "G-Player $VERSION" --notes "$NOTES"
fi
