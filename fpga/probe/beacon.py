#!/usr/bin/env python3
"""Load a probe bitstream into SRAM and print its UART beacon lines for a few seconds.

  fpga/probe/beacon.py BITSTREAM [SECONDS]
"""
import subprocess
import sys
import time

import serial

PORT, BAUD = "/dev/ttyUSB1", 1000000
fs = sys.argv[1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
serial.Serial(PORT, BAUD).close()      # the BL702 bridge applies the previous open's rate
s = serial.Serial(PORT, BAUD, timeout=0.05)
subprocess.run(["openFPGALoader", "-b", "tangnano9k", fs], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
s.reset_input_buffer()
end, buf = time.time() + secs, b""
while time.time() < end:
    buf += s.read(4096)
lines = [l for l in buf.decode(errors="replace").split("\r\n") if l.strip()]
for l in lines[:3] + (["..."] if len(lines) > 6 else []) + lines[-3:] if len(lines) > 6 else lines:
    print(l)
