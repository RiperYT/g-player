#!/usr/bin/env bash
# Rebuilds Tests/GPlayerCoreTests/Fixtures/IconFixture.exe: a program that does nothing and carries
# G-Player's own icon. Needs: brew install mingw-w64. icon.ico comes from make-icon.py.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(cd "$here/../../.." && pwd)/Tests/GPlayerCoreTests/Fixtures/IconFixture.exe"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

(cd "$here" && x86_64-w64-mingw32-windres icon.rc -O coff -o "$work/icon.o")
x86_64-w64-mingw32-gcc -mwindows -Os -s -o "$out" "$here/main.c" "$work/icon.o"
echo "fixture: $out"
