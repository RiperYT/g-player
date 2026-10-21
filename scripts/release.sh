#!/usr/bin/env bash
# Packs a release into releases/v<version>/ and (with --publish) attaches it to a GitHub release.
#   scripts/release.sh            build + zip + checksums
#   scripts/release.sh --publish  also: gh release create v<version>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
scripts/build-app.sh
OUT="releases/v$VERSION"
mkdir -p "$OUT"
ZIP="$OUT/G-Player-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/G-Player.app "$ZIP"
(cd "$OUT" && shasum -a 256 "G-Player-$VERSION.zip" > SHA256SUMS)
echo "release: $ZIP"
cat "$OUT/SHA256SUMS"
if [ "${1:-}" = "--publish" ]; then
  NOTES="$(awk "/^## \\[$VERSION\\]/{flag=1;next}/^## \\[/{flag=0}flag" CHANGELOG.md)"
  gh release create "v$VERSION" "$ZIP" "$OUT/SHA256SUMS" --title "G-Player $VERSION" --notes "$NOTES"
fi
