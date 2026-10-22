#!/usr/bin/env bash
# Fetches Sources/GPlayerCore/Resources/engine-fixes/libMoltenVK.dylib: the unchanged libMoltenVK.dylib from the
# official MoltenVK 1.4.2 release (Khronos Group, Apache-2.0). 1.4.1 and later accept the host-memory buffers Wine
# makes for 32-bit programs, so 32-bit DirectX 10/11 games run through DXVK. Also fetches the licenses of what the
# dylib has inside that the release's own LICENSE doesn't cover: cereal (BSD-3-Clause) and SPIRV-Headers (MIT-style),
# at the revisions MoltenVK 1.4.2 pins in ExternalRevisions. Works in a temporary folder.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
VERSION=1.4.2
TAR_SHA256=f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e
DYLIB_SHA256=aef00b13bcc808adf15b85bef9ae67393d92be7ed5dfe41cad16fa809e4a4c5f
CEREAL_REV=a56bad8bbb770ee266e930c95d37fff2a5be7fea
CEREAL_LICENSE_SHA256=58604a126af6a671ea390ee3d5b3e42228aa59b2858fb7af1d5b20b31739ccbb
SPIRV_HEADERS_REV=29981f65241605e08b0ede4cfeb999fe3b723c6a
SPIRV_HEADERS_LICENSE_SHA256=ea43b1de38a6f90c488800d66dec1ed671e68cda530266bc96951fb5b6307613
LICENSES="$REPO/Sources/GPlayerCore/Resources/licenses"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
curl -fsSL -o MoltenVK-macos.tar "https://github.com/KhronosGroup/MoltenVK/releases/download/v$VERSION/MoltenVK-macos.tar"
echo "$TAR_SHA256  MoltenVK-macos.tar" | shasum -a 256 -c -
tar -xf MoltenVK-macos.tar MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib MoltenVK/LICENSE
echo "$DYLIB_SHA256  MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" | shasum -a 256 -c -
curl -fsSL -o cereal-LICENSE "https://raw.githubusercontent.com/USCiLab/cereal/$CEREAL_REV/LICENSE"
echo "$CEREAL_LICENSE_SHA256  cereal-LICENSE" | shasum -a 256 -c -
curl -fsSL -o SPIRV-Headers-LICENSE "https://raw.githubusercontent.com/KhronosGroup/SPIRV-Headers/$SPIRV_HEADERS_REV/LICENSE"
echo "$SPIRV_HEADERS_LICENSE_SHA256  SPIRV-Headers-LICENSE" | shasum -a 256 -c -
# Everything is checked; only now does anything go into the repository.
cp MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib "$REPO/Sources/GPlayerCore/Resources/engine-fixes/libMoltenVK.dylib"
cp MoltenVK/LICENSE "$LICENSES/MoltenVK-LICENSE.txt"
cp cereal-LICENSE "$LICENSES/cereal-LICENSE.txt"
cp SPIRV-Headers-LICENSE "$LICENSES/SPIRV-Headers-LICENSE.txt"
echo "engine-fixes/libMoltenVK.dylib: MoltenVK $VERSION"
