#!/usr/bin/env python3
"""Packs G-Player's own app icon into icon.ico, the way Windows tools do:
16, 32 and 48 px as BMP (DIB) images, 256 px as PNG.

Usage: make-icon.py build/AppIcon.icns icon.ico   (needs Pillow; the .icns comes from scripts/make-icon.swift)
"""
import io
import struct
import sys

from PIL import Image


def dib(img):
    """A 32-bit BGRA DIB for an ICO entry: bottom-up pixels, then a 1-bit AND mask (all opaque)."""
    w, h = img.size
    px = img.convert("RGBA").load()
    xor = bytearray()
    for y in range(h - 1, -1, -1):
        for x in range(w):
            r, g, b, a = px[x, y]
            xor += bytes((b, g, r, a))
    mask = bytes(((w + 31) // 32) * 4 * h)
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, len(xor) + len(mask), 0, 0, 0, 0)
    return header + bytes(xor) + mask


def png(img):
    out = io.BytesIO()
    img.save(out, format="PNG", optimize=True)
    return out.getvalue()


def main(source, target):
    base = Image.open(source)
    base.load()
    base = base.convert("RGBA")
    images = []
    for size in (16, 32, 48, 256):
        img = base.resize((size, size), Image.LANCZOS)
        images.append((size, png(img) if size == 256 else dib(img), 32))

    out = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    for size, blob, bits in images:
        out += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, bits, len(blob), offset)
        offset += len(blob)
    for _, blob, _ in images:
        out += blob
    with open(target, "wb") as f:
        f.write(out)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
