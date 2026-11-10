#!/usr/bin/env bash
# UART unit test (rtl/soc/uart_16550.v: 256-byte FIFOs, interrupt output), Icarus, a few seconds.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
mkdir -p "$HERE/build"
iverilog -g2012 -o "$HERE/build/tb_uart.vvp" -s tb_uart "$HERE/tb_uart.v" "$REPO/rtl/soc/uart_16550.v"
out=$(vvp -n "$HERE/build/tb_uart.vvp" | grep -vE "^VCD|finish called" || true)
echo "$out"
grep -q "^PASS" <<<"$out"
