#!/usr/bin/env bash
# Rebuilds the Chromium helper wrapper (needs: brew install mingw-w64).
set -euo pipefail
cd "$(dirname "$0")/.."
x86_64-w64-mingw32-gcc -O2 -Wall -municode -mwindows -static \
  -o Sources/GPlayerCore/Resources/chromium-helper-wrapper.exe tools/chromium-helper-wrapper/wrapper.c
echo "wrapper: Sources/GPlayerCore/Resources/chromium-helper-wrapper.exe"
