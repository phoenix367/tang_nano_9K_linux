#!/usr/bin/env bash
# SD-card SPI master (rtl/soc/spi_master.v) against a mode-0 slave model. A few seconds.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
B="$HERE/build"
mkdir -p "$B"
iverilog -g2012 -o "$B/tb_spi_master.vvp" -s tb_spi_master \
  "$HERE/tb_spi_master.v" "$REPO/rtl/soc/spi_master.v"
vvp -n "$B/tb_spi_master.vvp" | tee "$B/tb_spi_master.log"
grep -q '^PASS' "$B/tb_spi_master.log"
