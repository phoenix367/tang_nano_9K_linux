#!/usr/bin/env python3
"""Drive the QERV boot ROM on the Tang Nano 9K over the UART (protocol in sw/bootrom/bootrom.S).

  sw/tools/qerv_boot.py --bitstream fpga/impl/pnr/tang9k_soc.fs --memtest
  sw/tools/qerv_boot.py --bitstream fpga/impl/pnr/tang9k_soc.fs --linux --input 'free\\nuname -a\\n'
  sw/tools/qerv_boot.py --load blob.bin@0x80100000
  sw/tools/qerv_boot.py --bitstream fpga/impl/pnr/tang9k_soc.fs --linux --console
  sw/tools/qerv_boot.py --console              # attach to whatever is running (Ctrl-] quits)
  sw/tools/qerv_boot.py --bitstream ... --linux --mmu   # stage 2: MMU kernel, booted in S-mode
  sw/tools/qerv_boot.py --bitstream ... --hash-flash flash.bin --flash-boot   # check, boot flash
  sw/tools/qerv_boot.py --bitstream ... --autoboot      # power-on path: no commands at all
  sw/tools/qerv_boot.py --reconfig --autoboot           # reload the design in the internal flash
  sw/tools/qerv_boot.py --bitstream ... --fb photo.png   # show an image on HDMI (VIDEO=1 build)
  sw/tools/qerv_boot.py --fb test                        # generated test pattern; --fb bars: bars

Steps, in order: load the bitstream into SRAM with openFPGALoader (--bitstream; otherwise the
ROM must already be at its "> " prompt), memory test, uploads (each checked twice: the hash of
what the ROM received, then the hash of what is in memory), framebuffer (--fb: the image fitted
to 640x480 RGB565, loaded through the uncached alias, then the ROM's v command), boot, then the
console: log until
the shell prompt and type --input one character per echo (the polled 8250 driver drains a
16-byte FIFO once per tick). Ends at the prompt after the last input line, or at --timeout,
unless --console hands the port to pyserial's miniterm (raw keys; Ctrl-] quits). Paste at
most ~16 characters at a time into the console: the polled driver drops the rest.
"""
import argparse
import os
import re
import struct
import subprocess
import sys
import time

import serial

WORK = os.environ.get("WORK", "/mnt/data/build/tang9k_linux")   # as sw/build.sh
IMAGES = f"{WORK}/images-tang9k"
IMAGES_MMU = f"{WORK}/images-tang9k-mmu"
RAM_BASE, DTB_ADDR = 0x80000000, 0x807FF000
FLASH_BASE = 0x20000000
FB_BASE, FB_UNC, FB_W, FB_H = 0x80700000, 0x90700000, 640, 480   # doc/video_plan.md


def fb_image(spec):
    """640x480 RGB565 little-endian bytes: an image file fitted (letterboxed) to the screen,
    or "test": per-channel ramps, a 1-pixel grid and checkerboards (pixel-exactness checks)."""
    from PIL import Image, ImageOps
    if spec == "test":
        img = Image.new("RGB", (FB_W, FB_H))
        px = img.load()
        for y in range(FB_H):
            for x in range(FB_W):
                band = y // 60
                v = x * 256 // FB_W
                c = [(v, 0, 0), (0, v, 0), (0, 0, v), (v, v, v)][band] if band < 4 else \
                    ((255, 255, 255) if (x + y) & 1 else (0, 0, 0)) if band == 4 else \
                    ((255, 255, 0) if ((x >> 3) + (y >> 3)) & 1 else (0, 0, 128)) if band == 5 else \
                    (x * 255 // FB_W, y * 255 // FB_H, 128)
                if x % 80 == 0 or y % 60 == 0 or x == FB_W - 1 or y == FB_H - 1:
                    c = (255, 255, 255)
                px[x, y] = c
    else:
        img = ImageOps.pad(Image.open(spec).convert("RGB"), (FB_W, FB_H), color=(0, 0, 0))
    out = bytearray()
    for r, g, b in img.getdata():
        out += struct.pack("<H", ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))
    return bytes(out)


def djb(data, h=5381):
    for b in data:
        h = (h * 33 + b) & 0xFFFFFFFF
    return h


class Rom:
    def __init__(self, port, baud, log):
        # The board's BL702 USB-UART bridge (FT2232 emulation) applies the line rate of the
        # previous open, not this one: open twice so the second one runs at `baud`.
        serial.Serial(port, baud).close()
        self.s = serial.Serial(port, baud, timeout=0.05)
        self.log = log
        self.buf = b""

    def read_until(self, pattern, timeout, echo=True):
        """Read until the regex (bytes) matches the buffer; return the text up to the match end."""
        end = time.time() + timeout
        rx = re.compile(pattern)
        while True:
            m = rx.search(self.buf)
            if m:
                out, self.buf = self.buf[:m.end()], self.buf[m.end():]
                return out
            if time.time() > end:
                raise TimeoutError(f"no {pattern!r} within {timeout} s; got {self.buf[-200:]!r}")
            d = self.s.read(4096)
            if d:
                self.buf += d
                if self.log:
                    self.log.write(d)
                    self.log.flush()
                if echo:
                    sys.stdout.write(d.decode(errors="replace"))
                    sys.stdout.flush()

    def prompt(self, timeout=5):
        return self.read_until(rb"> $", timeout)

    def send(self, data):
        self.s.write(data)
        self.s.flush()


def addr_file(spec):
    path, _, addr = spec.rpartition("@")
    return path, int(addr, 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="/dev/ttyUSB1")
    ap.add_argument("--baud", type=int, default=1000000)
    ap.add_argument("--bitstream", help="load this .fs into SRAM first (openFPGALoader -b tangnano9k)")
    ap.add_argument("--memtest", nargs="?", const=f"{RAM_BASE:#x}:0x800000", metavar="ADDR:LEN",
                    help="memory test (default: all 8 MB)")
    ap.add_argument("--load", action="append", default=[], metavar="FILE@ADDR")
    ap.add_argument("--linux", action="store_true",
                    help=f"--load Image@{RAM_BASE:#x} --load tang9k.dtb@{DTB_ADDR:#x} --boot ({IMAGES})")
    ap.add_argument("--boot", action="store_true")
    ap.add_argument("--mmu", action="store_true",
                    help=f"stage 2: --linux takes {IMAGES_MMU} and boots with 'B' (S-mode, SBI shim)")
    ap.add_argument("--reconfig", action="store_true",
                    help="instead of --bitstream: reconfigure from the FPGA's internal flash "
                         "(openFPGALoader -r), as at power-on")
    ap.add_argument("--hash-flash", metavar="FILE",
                    help="compare the SPI flash (boot ROM 'c' over 0x20000000) with FILE")
    ap.add_argument("--flash-boot", action="store_true", help="boot from the SPI flash ('f')")
    ap.add_argument("--autoboot", action="store_true",
                    help="after --bitstream send nothing: the boot ROM autoboots from flash after 2 s")
    ap.add_argument("--fb", metavar="IMAGE",
                    help="show IMAGE (any Pillow format, fitted to 640x480), 'test' (pattern) or "
                         "'bars' (the hardware colour bars) on HDMI; needs a VIDEO=1 build")
    ap.add_argument("--input", default="", help="shell input, '\\n'-separated, typed at each prompt")
    ap.add_argument("--timeout", type=float, default=600, help="console timeout after boot (s)")
    ap.add_argument("--log", help="raw UART log")
    ap.add_argument("--console", action="store_true",
                    help="interactive console (miniterm) at the end; alone, just attach to the board")
    a = ap.parse_args()
    if a.linux:
        img, dtb = (IMAGES_MMU, "tang9k-mmu.dtb") if a.mmu else (IMAGES, "tang9k.dtb")
        a.load += [f"{img}/Image@{RAM_BASE:#x}", f"{img}/{dtb}@{DTB_ADDR:#x}"]
        a.boot = True

    if a.console and not (a.bitstream or a.reconfig or a.memtest or a.load or a.boot):
        serial.Serial(a.port, a.baud).close()          # the bridge applies the previous open's rate
        console(a)

    log = open(a.log, "wb") if a.log else None
    rom = Rom(a.port, a.baud, log)
    rom.s.reset_input_buffer()
    if a.bitstream or a.reconfig:
        cmd = ["openFPGALoader", "-b", "tangnano9k"] + (["-r"] if a.reconfig else [a.bitstream])
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        rom.read_until(rb"QERV boot ROM", 5, echo=False)   # drop what the old design sent
        print("QERV boot ROM")
        rom.prompt()
        if a.autoboot:                                    # power-on path, timed from the prompt
            t0 = time.time()
            rom.read_until(rb"autoboot", 5)
            rom.read_until(rb"done\r\n", 120)
            print(f"\n[flash copy done after {time.time() - t0:.1f} s]")
            ok = shell(rom, a, t0)
            finish(rom, a, log, ok)
    else:
        rom.send(b"x")                                   # unknown command: "?" and a new prompt
        rom.read_until(rb"\?\r\n> $", 3)

    for _ in range(20):                   # PSRAM calibrates ~25 ms after a (re)configure
        rom.send(b"s")
        out = rom.read_until(rb"status ((?:[0-9a-f]{8} ){7,})\r\n> $", 3, echo=False)
        words = [int(w, 16) for w in re.search(rb"status ((?:[0-9a-f]{8} ){7,})", out).group(1).split()]
        if words[0] & 3 == 3:
            break
        time.sleep(0.05)
    names = ["calib", "cmd0", "cmd1", "rdv0", "rdv1", "miss", "wb", "-", "vctrl", "vbase", "vstat"]
    print("[status " + " ".join(f"{n}={w:#x}" for n, w in zip(names, words)) + "]")
    if words[0] & 3 != 3 and (a.memtest or a.load or a.boot):
        print("[PSRAM not calibrated: stopping]")
        sys.exit(1)

    ok = True
    if a.hash_flash:
        data = open(a.hash_flash, "rb").read()
        want = f"{djb(data):08x}".encode()
        t0 = time.time()
        rom.send(b"c" + struct.pack("<II", FLASH_BASE, len(data)))
        out = rom.read_until(rb"ok ([0-9a-f]{8})\r\n> $", 120, echo=False)
        got = re.search(rb"ok ([0-9a-f]{8})", out).group(1)
        good = got == want
        print(f"[flash {len(data)} B: hash {got.decode()} in {time.time() - t0:.1f} s, "
              f"{os.path.basename(a.hash_flash)} {want.decode()} {'ok' if good else 'MISMATCH'}]")
        if not good:
            sys.exit(1)

    if a.memtest:
        addr, length = (int(x, 0) for x in a.memtest.split(":"))
        t0 = time.time()
        rom.send(b"m" + struct.pack("<II", addr, length))
        out = rom.prompt(timeout=600)
        print(f"[memtest {length >> 10} KB: {time.time() - t0:.1f} s]")
        ok &= b"FAIL" not in out

    for spec in a.load:
        path, addr = addr_file(spec)
        data = open(path, "rb").read()
        want = f"{djb(data):08x}".encode()
        t0 = time.time()
        rom.send(b"l" + struct.pack("<II", addr, len(data)))
        for i in range(0, len(data), 4096):
            rom.send(data[i:i + 4096])
        out = rom.read_until(rb"ok ([0-9a-f]{8})\r\n> $", 60, echo=False)
        got = re.search(rb"ok ([0-9a-f]{8})", out).group(1)
        dt = time.time() - t0
        rom.send(b"c" + struct.pack("<II", addr, len(data)))
        out = rom.read_until(rb"ok ([0-9a-f]{8})\r\n> $", 120, echo=False)
        mem = re.search(rb"ok ([0-9a-f]{8})", out).group(1)
        good = got == want and mem == want
        print(f"[load {os.path.basename(path)} {len(data)} B @{addr:#x}: {dt:.1f} s "
              f"({len(data) / dt / 1024:.0f} KB/s), hash {want.decode()} rx {got.decode()} "
              f"mem {mem.decode()} {'ok' if good else 'MISMATCH'}]")
        if not good:
            sys.exit(1)

    if a.fb:
        if a.fb == "bars":
            rom.send(b"v" + struct.pack("<I", 0))
            rom.prompt()
            print("[video: colour bars]")
        else:
            data = fb_image(a.fb)
            want = f"{djb(data):08x}".encode()
            t0 = time.time()
            rom.send(b"l" + struct.pack("<II", FB_UNC, len(data)))
            for i in range(0, len(data), 4096):
                rom.send(data[i:i + 4096])
            out = rom.read_until(rb"ok ([0-9a-f]{8})\r\n> $", 120, echo=False)
            got = re.search(rb"ok ([0-9a-f]{8})", out).group(1)
            dt = time.time() - t0
            rom.send(b"c" + struct.pack("<II", FB_UNC, len(data)))
            out = rom.read_until(rb"ok ([0-9a-f]{8})\r\n> $", 120, echo=False)
            mem = re.search(rb"ok ([0-9a-f]{8})", out).group(1)
            rom.send(b"v" + struct.pack("<I", FB_BASE))
            rom.prompt()
            good = got == want and mem == want
            print(f"[framebuffer {a.fb}: {len(data)} B in {dt:.1f} s, hash {want.decode()} rx "
                  f"{got.decode()} mem {mem.decode()} {'ok' if good else 'MISMATCH'}; scanout on]")
            ok &= good

    if (a.boot or a.flash_boot) and ok:
        t0 = time.time()
        rom.send(b"f" if a.flash_boot else b"B" if a.mmu else b"b")
        ok = shell(rom, a, t0)
    finish(rom, a, log, ok)


def shell(rom, a, t0):
    """Follow the kernel boot to the shell prompt, then type --input. True on success."""
    lines = [l for l in a.input.replace("\\n", "\n").split("\n")]
    if lines and lines[-1] == "":
        lines.pop()
    try:
        rom.read_until(rb"Run /init", a.timeout)
        print(f"\n[Run /init after {time.time() - t0:.1f} s]")
        rom.read_until(rb"\n[^\n\[]*# $", a.timeout)
        print(f"\n[shell prompt after {time.time() - t0:.1f} s]")
        for line in lines:
            for ch in (line + "\n").encode():
                rom.send(bytes([ch]))
                try:
                    rom.read_until(re.escape(bytes([ch])) if ch != 10 else rb"\n", 1)
                except TimeoutError:
                    pass
            rom.read_until(rb"# $", a.timeout)
    except TimeoutError as e:
        print(f"\n[{e}]")
        return False
    return True


def finish(rom, a, log, ok):
    if log:
        log.close()
    if a.console:
        rom.s.close()
        console(a)
    sys.exit(0 if ok else 1)


def console(a):
    """Replace this process with miniterm on the port (the last open was at a.baud)."""
    print(f"[console {a.port} {a.baud} baud, Ctrl-] quits]", flush=True)
    os.execvp(sys.executable, [sys.executable, "-m", "serial.tools.miniterm", "--raw", "--quiet",
                               a.port, str(a.baud)])


if __name__ == "__main__":
    main()
