#!/usr/bin/env bash
# OpenCores I2C master (rtl/i2c) as soc_top wires it, against the sim's EEPROM model
# (rtl/sim/i2c_eeprom_model.v), with the i2c-ocores driver's register sequences. Seconds.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
B="$HERE/build"
mkdir -p "$B"
iverilog -g2012 -o "$B/tb_i2c.vvp" -s tb_i2c "$HERE/tb_i2c.v" "$REPO"/rtl/i2c/*.v \
  "$REPO/rtl/sim/i2c_eeprom_model.v"
vvp -n "$B/tb_i2c.vvp" | tee "$B/tb_i2c.log"
grep -q '^PASS' "$B/tb_i2c.log"
