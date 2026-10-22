#!/usr/bin/env bash
# Builds Tests/GPlayerCoreTests/Fixtures/D3D11Fixture.exe (64-bit, imports d3d11.dll) and D3D9Fixture.exe
# (32-bit, imports d3d9.dll). Needs mingw-w64 (brew install mingw-w64).
set -euo pipefail
cd "$(dirname "$0")/../../.."
src=tools/test-fixtures/graphics-fixtures
out=Tests/GPlayerCoreTests/Fixtures
x86_64-w64-mingw32-gcc -mwindows -Os -s -o "$out/D3D11Fixture.exe" "$src/d3d11.c" -ld3d11
i686-w64-mingw32-gcc   -mwindows -Os -s -o "$out/D3D9Fixture.exe"  "$src/d3d9.c"  -ld3d9
