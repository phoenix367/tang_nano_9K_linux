#!/usr/bin/env python3
"""Build the SPI flash image the QERV boot ROM copies at reset (sw/bootrom/bootrom.S).

    python3 sw/mkflash.py <Image> <dtb> <out.bin>

Layout: 0x0000 header {magic "QRVL", image_len, dtb_len, 0} (little-endian u32),
0x1000 DTB (max 4 KB), 0x2000 kernel Image. Must fit the 4 MB flash.
"""
import struct
import sys

image = open(sys.argv[1], "rb").read()
dtb = open(sys.argv[2], "rb").read()
assert len(dtb) <= 0x1000, "DTB larger than 4 KB"
out = bytearray(b"\xff" * 0x2000)
out[0:16] = struct.pack("<4sIII", b"QRVL", len(image), len(dtb), 0)
out[0x1000:0x1000 + len(dtb)] = dtb
out += image
assert len(out) <= 4 * 1024 * 1024, f"flash image {len(out)} bytes > 4 MB"
open(sys.argv[3], "wb").write(out)
print(f"{sys.argv[3]}: {len(out)} bytes (Image {len(image)}, DTB {len(dtb)})")
