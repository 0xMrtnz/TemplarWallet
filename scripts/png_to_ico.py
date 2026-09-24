#!/usr/bin/env python3
"""Packs square PNGs into a multi-resolution Windows .ico.

Called by scripts/generate_icons.sh. Uses PNG-compressed ICO entries (the
Vista+ format), so no bitmap re-encoding and no Pillow dependency.

Usage: png_to_ico.py OUT.ico IN1.png [IN2.png ...]
       png_to_ico.py --assert-transparent-corner IN.png
"""
import struct
import sys
import zlib


def png_size(data: bytes) -> tuple[int, int]:
    """Reads width/height out of a PNG's IHDR chunk."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    # 8-byte signature, 4-byte length, 4-byte "IHDR", then width and height.
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def _decode_rgba(data: bytes) -> tuple[int, int, int, list[bytes]]:
    """Minimal PNG decode — enough to read pixels back for verification."""
    pos, idat = 8, b""
    width = height = depth = color = 0
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    if depth != 8:
        raise ValueError(f"only 8-bit PNGs supported, got {depth}")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]

    raw = zlib.decompress(idat)
    stride = width * channels
    rows: list[bytes] = []
    prev = bytearray(stride)
    i = 0
    for _ in range(height):
        filt = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        for x in range(stride):
            a = line[x - channels] if x >= channels else 0
            b = prev[x]
            c = prev[x - channels] if x >= channels else 0
            if filt == 1:
                line[x] = (line[x] + a) & 255
            elif filt == 2:
                line[x] = (line[x] + b) & 255
            elif filt == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 255
        rows.append(bytes(line))
        prev = line
    return width, height, channels, rows


def assert_transparent_corner(path: str) -> int:
    """Fails if the icon's top-left pixel is not fully transparent.

    This is the regression guard for the white-corner bug: rasterizing the
    badge SVG with a renderer that flattens alpha onto white produced an icon
    with four opaque white triangles around the squircle, which macOS drew
    verbatim in the Dock.
    """
    with open(path, "rb") as fh:
        width, _, channels, rows = _decode_rgba(fh.read())
    if channels != 4:
        print(f"{path}: no alpha channel ({channels} channels)", file=sys.stderr)
        return 1
    corners = {
        "top-left": tuple(rows[0][0:4]),
        "top-right": tuple(rows[0][(width - 1) * 4:(width - 1) * 4 + 4]),
    }
    bad = {k: v for k, v in corners.items() if v[3] != 0}
    if bad:
        print(f"{path}: corners are not transparent: {bad}", file=sys.stderr)
        print("The renderer flattened alpha onto a background.", file=sys.stderr)
        return 1
    print(f"corners transparent: {path}")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--assert-transparent-corner":
        return assert_transparent_corner(argv[2])

    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    out_path, png_paths = argv[1], argv[2:]
    images = []
    for path in png_paths:
        with open(path, "rb") as fh:
            data = fh.read()
        width, height = png_size(data)
        if width != height:
            raise ValueError(f"{path}: icon images must be square, got {width}x{height}")
        if width > 256:
            raise ValueError(f"{path}: ICO caps out at 256x256, got {width}")
        images.append((width, data))

    images.sort(key=lambda i: i[0])

    # ICONDIR: reserved, type (1 = icon), image count.
    header = struct.pack("<HHH", 0, 1, len(images))
    # Each ICONDIRENTRY is 16 bytes; pixel data follows the whole directory.
    offset = len(header) + 16 * len(images)

    directory = b""
    for size, data in images:
        # 256 is stored as 0 — the field is a single byte.
        dim = 0 if size == 256 else size
        directory += struct.pack(
            "<BBBBHHII",
            dim,      # width
            dim,      # height
            0,        # palette entries (0 = truecolor)
            0,        # reserved
            1,        # color planes
            32,       # bits per pixel
            len(data),
            offset,
        )
        offset += len(data)

    with open(out_path, "wb") as fh:
        fh.write(header)
        fh.write(directory)
        for _, data in images:
            fh.write(data)

    sizes = ", ".join(str(s) for s, _ in images)
    print(f"wrote {out_path} ({sizes})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
