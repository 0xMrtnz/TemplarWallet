#!/usr/bin/env python3
"""Rewrite a BMP as a bottom-up DIB, in place.

`sips -s format bmp` writes a *top-down* DIB: biHeight is negative and the
first row in the file is the top row of the image. That is legal BMP, and
Windows' own GDI honours it — Inno Setup's wizard image loader does not, so
the installer drew both wizard bitmaps upside down.

Flipping the rows and storing a positive height produces the form every BMP
reader agrees on. Uncompressed BI_RGB only, which is all `sips` emits.

Usage: bmp_bottom_up.py FILE [FILE...]   (no-op on files already bottom-up)
"""

import struct
import sys


def fix(path: str) -> bool:
    with open(path, "rb") as fh:
        data = bytearray(fh.read())

    if data[:2] != b"BM":
        raise SystemExit(f"{path}: not a BMP")

    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    header_size = struct.unpack_from("<I", data, 14)[0]
    if header_size < 40:
        raise SystemExit(f"{path}: unsupported DIB header ({header_size} bytes)")

    width, height = struct.unpack_from("<ii", data, 18)
    bit_count = struct.unpack_from("<H", data, 28)[0]
    compression = struct.unpack_from("<I", data, 30)[0]

    if height > 0:
        return False  # already bottom-up
    if compression != 0:
        raise SystemExit(f"{path}: only uncompressed BI_RGB is handled")

    rows = -height
    stride = ((width * bit_count + 31) // 32) * 4
    end = pixel_offset + stride * rows
    if end > len(data):
        raise SystemExit(f"{path}: pixel data is shorter than the header claims")

    pixels = data[pixel_offset:end]
    flipped = bytearray()
    for r in range(rows - 1, -1, -1):
        flipped += pixels[r * stride:(r + 1) * stride]

    data[pixel_offset:end] = flipped
    struct.pack_into("<i", data, 22, rows)  # biHeight, now positive

    with open(path, "wb") as fh:
        fh.write(data)
    return True


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for arg in sys.argv[1:]:
        print(f"{'flipped' if fix(arg) else 'already bottom-up'}: {arg}")
