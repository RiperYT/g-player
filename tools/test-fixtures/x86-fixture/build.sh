#!/usr/bin/env bash
# Builds Tests/GPlayerCoreTests/Fixtures/X86Fixture.exe, a 32-bit Windows program with no resources.
set -euo pipefail
cd "$(dirname "$0")/../../.."
i686-w64-mingw32-gcc -mwindows -Os -s -o Tests/GPlayerCoreTests/Fixtures/X86Fixture.exe tools/test-fixtures/x86-fixture/main.c
