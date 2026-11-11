#!/usr/bin/env python3
"""Boot ROM command test on the Verilator SoC model (sim/soc/run.sh, ~1 min plus the build).

Sends one command per "> " prompt (see sw/bootrom/bootrom.S) and checks the replies:
  - memtest over 64 KB across the middle of the PSRAM (bit 22) and larger than the cache
  - memtest over the boot ROM, which must FAIL at its first word (writes are ignored)
  - load of an odd-length random block: the "ok" hash must match the data
  - hash of the same memory: the data must have landed in PSRAM
  - status: the PSRAM controller initialized (SYSCON word 0 = 3)
  - an unknown command ("?"), then poweroff, which ends the simulation
"""
import os
import random
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def djb(data, h=5381):
    for b in data:
        h = (h * 33 + b) & 0xFFFFFFFF
    return h


def rec(cmd, *words, data=b""):
    body = cmd.encode() + b"".join(struct.pack("<I", w) for w in words) + data
    return struct.pack("<I", len(body)) + body


def main():
    w = os.environ.get("W", "4")
    work = os.environ.get("WORK", "/mnt/data/build/tang9k_linux")
    blob = random.Random(1).randbytes(4099)
    recs = (rec("s") + rec("m", 0x803F8000, 0x10000) + rec("m", 0x0, 0x40) +
            rec("l", 0x80100003, len(blob), data=blob) + rec("c", 0x80100003, len(blob)) +
            rec("x") + rec("q"))
    path = os.path.join(work, f"verilator-soc-w{w}.rom_test.bin")
    with open(path, "wb") as f:
        f.write(recs)
    log_path = os.path.join(HERE, "results", f"soc_w{w}.rom_test.log")
    if os.path.exists(log_path):          # a failed build must not leave an old log to check
        os.remove(log_path)
    env = dict(os.environ, ROM_INPUT=path, QUIET="1", MAX_CYCLES="60000000", UART_LOG=log_path)
    r = subprocess.run([os.path.join(HERE, "run.sh")], env=env, capture_output=True, text=True)
    sys.stderr.write(r.stderr[-600:])
    if not os.path.exists(log_path):
        sys.exit(f"FAIL: no UART log (sim/soc/run.sh exit {r.returncode})")
    log = open(log_path, errors="replace", newline="").read()
    print(log.replace("\r", ""))

    h = f"{djb(blob):08x}"
    checks = [
        ("banner", "QERV boot ROM" in log),
        ("status: PSRAM ready", re.search(r"status 00000003 (?:[0-9a-f]{8} ){6}", log)),
        ("memtest 64 KB across 4 MB ok", re.search(r"memtest w\.r\.w\.r\.bok", log)),
        ("memtest on ROM fails at 0", re.search(r"FAIL n=[0-9a-f]{8} @00000000", log)),
        ("load hash", log.count(f"ok {h}") >= 1),
        ("memory hash", log.count(f"ok {h}") == 2),
        ("unknown command", "?\r\n" in log),
        ("poweroff", "end: poweroff" in r.stderr),
    ]
    bad = [n for n, ok in checks if not ok]
    for n, ok in checks:
        print(f"{'PASS' if ok else 'FAIL'}  {n}")
    print("expected hash", h)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
