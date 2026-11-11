#!/usr/bin/env python3
"""Run the qperf performance tests (perf/board/qperf.c) on the board under Linux.

  perf/board/run.py                       # boot as at power-up, then run every test
  perf/board/run.py cpu os.fork           # only tests whose names start with these
  perf/board/run.py --attach              # the board already sits at the shell prompt
  perf/board/run.py --boot '--bitstream X.fs --linux --mmu'   # boot another way (qerv_boot.py)

Steps: build qperf with Buildroot's toolchain (static, into $WORK/qperf/), boot the board with
sw/tools/qerv_boot.py (default --reconfig --autoboot: the internal flash's design and the SPI
flash's kernel, as at power-up), upload the binary to /tmp over the UART, check its md5, run
it, and save its output with the kernel version to perf/board/results/<date>.txt (the raw
UART and boot logs go to $WORK/qperf/).

The upload: the shell stops busybox script (console-shell's relay to the HDMI console, which
drops input its pty can't take at once) and `head -c N < /dev/ttyS0` writes the bytes to the
file; then script continues. The UART is already raw (script set it so). The bytes are paced
(--rate), and a failed md5 check retries at half the rate. A binary already in /tmp with the
right md5 is not sent again.
"""
import argparse
import datetime
import hashlib
import os
import re
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "sw/tools"))
from qerv_boot import Rom  # noqa: E402

WORK = os.environ.get("WORK", "/mnt/data/build/tang9k_linux")
CC = f"{WORK}/br-tang9k-mmu/host/bin/riscv32-buildroot-linux-uclibc-"
PROMPT = rb"\n[^\n\[]*# $"


def build(cpu_hz):
    out = f"{WORK}/qperf/qperf"
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run([CC + "gcc", "-O2", "-static", "-Wall", "-Wextra", f"-DCPU_HZ={cpu_hz}.0",
                    "-o", out, os.path.join(HERE, "qperf.c")], check=True)
    subprocess.run([CC + "strip", out], check=True)
    return open(out, "rb").read()


class Shell:
    def __init__(self, rom):
        self.rom = rom

    def sync(self):
        self.rom.send(b"\n")
        self.rom.read_until(PROMPT, 10, echo=False)

    def run(self, cmd, timeout=60, echo=False):
        """Type a command line and return its output (without the echoed command)."""
        self.rom.send(cmd.encode() + b"\n")
        out = self.rom.read_until(PROMPT, timeout, echo=echo)
        text = out.decode(errors="replace").replace("\r", "")
        text = text[text.find("\n") + 1:]                      # drop the echoed command
        return text[:text.rfind("\n") + 1]                     # and the next prompt

    def md5(self, path):
        m = re.search(r"^([0-9a-f]{32})\s", self.run(f"md5sum {path} 2>/dev/null"), re.M)
        return m.group(1) if m else None

    def upload(self, data, path, rate):
        want = hashlib.md5(data).hexdigest()
        if self.md5(path) == want:
            print(f"[{path}: already there]")
            return
        for attempt in range(3):
            t0 = time.time()
            # S = busybox script (the shell's grandparent, console-shell), stopped while head
            # reads the UART itself: script's pty master is non-blocking, and it drops what
            # the pty can't take. READY and DONE go straight to the UART as well.
            self.rom.send(f"read -r _ _ _ S _ < /proc/$PPID/stat; kill -STOP $S; "
                          f"echo RE''ADY > /dev/ttyS0; head -c {len(data)} < /dev/ttyS0 > {path}; "
                          f"echo DO''NE > /dev/ttyS0; kill -CONT $S\n".encode())
            self.rom.read_until(rb"READY\r?\n", 30, echo=False)
            chunk = 128
            for i in range(0, len(data), chunk):
                self.rom.send(data[i:i + chunk])
                time.sleep(chunk / rate)
            try:
                self.rom.read_until(rb"DONE", len(data) / rate + 30, echo=False)
            except TimeoutError:               # bytes were lost: fill up until head ends
                for _ in range(0, len(data), 16):
                    self.rom.send(bytes(16))
                    try:
                        self.rom.read_until(rb"DONE", 0.2, echo=False)
                        break
                    except TimeoutError:
                        pass
            self.rom.read_until(PROMPT, 30, echo=False)
            self.rom.send(b"\x03")             # clear any padding that reached the shell
            self.sync()
            got = self.md5(path)
            dt = time.time() - t0
            if got == want:
                self.run(f"chmod +x {path}")
                print(f"[{path}: {len(data)} B in {dt:.1f} s at {rate / 1024:.0f} KB/s, md5 ok]")
                return
            print(f"[{path}: md5 mismatch at {rate / 1024:.0f} KB/s; retrying slower]")
            rate /= 2
        sys.exit("upload failed")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tests", nargs="*", help="test name prefixes (default: all)")
    ap.add_argument("--attach", action="store_true", help="don't boot: use the running shell")
    ap.add_argument("--boot", default="--reconfig --autoboot",
                    help="qerv_boot.py arguments for the boot (default: %(default)s)")
    ap.add_argument("--port", default="/dev/ttyUSB1")
    ap.add_argument("--rate", type=float, default=8192, help="upload rate, bytes/s")
    ap.add_argument("--cpu-hz", type=int, default=42000000)
    ap.add_argument("--out", help="results file (default perf/board/results/<date>.txt)")
    ap.add_argument("--log", help="raw UART log of the run (default $WORK/qperf/<date>.uart.log)")
    a = ap.parse_args()

    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M")
    out = a.out or os.path.join(HERE, "results", f"{stamp}.txt")
    log_path = a.log or f"{WORK}/qperf/{stamp}.uart.log"
    os.makedirs(os.path.dirname(out), exist_ok=True)

    data = build(a.cpu_hz)
    print(f"[qperf: {len(data)} B]")
    if not a.attach:
        boot_log = f"{WORK}/qperf/{stamp}.boot.log"
        cmd = [sys.executable, os.path.join(REPO, "sw/tools/qerv_boot.py"), "--port", a.port,
               *shlex.split(a.boot), "--timeout", "120", "--log", boot_log]
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        tail = [l for l in r.stdout.splitlines() if l.startswith("[")]
        print("\n".join(tail[-3:]))
        if r.returncode:
            sys.exit(f"boot failed: {' '.join(cmd)} (log {boot_log})")

    log = open(log_path, "wb")
    sh = Shell(Rom(a.port, 1000000, log))
    sh.sync()
    uname = sh.run("uname -a").strip()
    sh.upload(data, "/tmp/qperf", a.rate)
    print(f"[running qperf {' '.join(a.tests)}]")
    t0 = time.time()
    res = sh.run("/tmp/qperf " + " ".join(a.tests), timeout=1800, echo=True)
    print(f"[qperf took {time.time() - t0:.0f} s]")
    log.close()
    with open(out, "w") as f:
        f.write(f"# {stamp}  {uname}\n")
        f.write(f"# boot: {'(attached)' if a.attach else a.boot}; qperf md5 "
                f"{hashlib.md5(data).hexdigest()}\n")
        f.write(res)
    print(f"[results: {os.path.relpath(out)}]")


if __name__ == "__main__":
    main()
