#!/usr/bin/env python3
"""Make the boot splash for the SPI flash (doc/video_plan.md): a 640x480 RGB565 picture,
run-length encoded for the boot ROM, which draws it into the framebuffer at power-up.

    python3 sw/tools/mksplash.py out.rle [IMAGE] [--png preview.png]

IMAGE (any Pillow format) is fitted to 640x480 on black; without one, a default splash is
drawn. Format: little-endian u32 words, (count << 16) | rgb565, count 1..65535, rows in order,
640 * 480 pixels in all. A vertical gradient costs one run per line; anti-aliased text adds
short runs, so a typical splash is some tens of KB.
"""
import struct
import sys

from PIL import Image, ImageDraw, ImageFont, ImageOps

W, H = 640, 480
FONTS = "/usr/share/fonts/truetype/dejavu/"


def default_splash():
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    top, bot = (8, 14, 32), (22, 40, 72)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W - 1, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bot)))
    # a chip: a body, pins on all four sides, and the core's name on it
    cx, cy, s = W // 2, 150, 54
    body, pin = (230, 120, 40), (150, 170, 200)
    for i in range(-3, 4):
        o = i * 14
        d.rectangle([cx + o - 3, cy - s - 16, cx + o + 3, cy - s], fill=pin)
        d.rectangle([cx + o - 3, cy + s, cx + o + 3, cy + s + 16], fill=pin)
        d.rectangle([cx - s - 16, cy + o - 3, cx - s, cy + o + 3], fill=pin)
        d.rectangle([cx + s, cy + o - 3, cx + s + 16, cy + o + 3], fill=pin)
    d.rounded_rectangle([cx - s, cy - s, cx + s, cy + s], radius=10, fill=(30, 34, 44),
                        outline=body, width=4)
    chip = ImageFont.truetype(FONTS + "DejaVuSansMono-Bold.ttf", 30)
    d.text((cx, cy), "QERV", font=chip, fill=body, anchor="mm")
    title = ImageFont.truetype(FONTS + "DejaVuSans-Bold.ttf", 56)
    sub = ImageFont.truetype(FONTS + "DejaVuSans.ttf", 22)
    small = ImageFont.truetype(FONTS + "DejaVuSans.ttf", 16)
    d.text((cx, 290), "QERV Linux", font=title, fill=(240, 244, 250), anchor="mm")
    d.text((cx, 340), "RISC-V SERV  ·  SV32 MMU  ·  Tang Nano 9K", font=sub,
           fill=(150, 175, 210), anchor="mm")
    d.text((cx, 430), "booting…", font=small, fill=(110, 130, 160), anchor="mm")
    return img


def rle(img):
    out = bytearray()
    run, cur = 0, None
    for r, g, b in img.getdata():
        p = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        if p == cur and run < 0xFFFF:
            run += 1
            continue
        if run:
            out += struct.pack("<I", run << 16 | cur)
        cur, run = p, 1
    out += struct.pack("<I", run << 16 | cur)
    return bytes(out)


def main():
    args = [a for a in sys.argv[1:]]
    png = None
    if "--png" in args:
        i = args.index("--png")
        png = args[i + 1]
        del args[i:i + 2]
    if not args:
        sys.exit(__doc__)
    img = ImageOps.pad(Image.open(args[1]).convert("RGB"), (W, H), color=(0, 0, 0)) \
        if len(args) > 1 else default_splash()
    data = rle(img)
    open(args[0], "wb").write(data)
    if png:
        img.save(png)
    print(f"{args[0]}: {len(data)} bytes ({len(data) // 4} runs)")


if __name__ == "__main__":
    main()
