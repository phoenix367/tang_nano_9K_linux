#!/usr/bin/env bash
# Open the board's serial console (1 Mbaud 8N1, /dev/ttyUSB1) in a terminal program.
#
#   sw/tools/console.sh            gtkterm (miniterm if gtkterm is not installed)
#   sw/tools/console.sh miniterm   pyserial's miniterm in this terminal (Ctrl-] quits)
#   sw/tools/console.sh --prime    only prepare the port, for any other program
#
# The board's USB-UART bridge (BL702) applies the baud rate of the PREVIOUS port open, so a
# program that opens the port once at 1 Mbaud after something else used 9600 talks at 9600
# and shows garbage. Opening and closing the port at 1 Mbaud first fixes that (qerv_boot.py
# does the same). The divider is fixed in the FPGA (fpga/build.sh BAUD), so the rate cannot
# be changed from the board side.
#
# Env: PORT (default /dev/ttyUSB1; /dev/ttyUSB0 is the JTAG side), BAUD (default 1000000).
# Paste at most ~16 characters at a time: the console UART is polled and drops the rest.
set -euo pipefail
PORT="${PORT:-/dev/ttyUSB1}"
BAUD="${BAUD:-1000000}"
MODE="${1:-gtkterm}"

[[ -e "$PORT" ]] || { echo "$PORT not found: is the board plugged in?" >&2; exit 1; }
if users=$(fuser "$PORT" 2>/dev/null) && [[ -n "${users// /}" ]]; then
  echo "$PORT is in use by PID(s)${users}; close that program first" >&2
  exit 1
fi

python3 -c "import serial, sys; serial.Serial(sys.argv[1], int(sys.argv[2])).close()" "$PORT" "$BAUD"

case "$MODE" in
  --prime) echo "$PORT primed for $BAUD baud" ;;
  gtkterm)
    if command -v gtkterm > /dev/null; then
      exec gtkterm -p "$PORT" -s "$BAUD"
    fi
    echo "gtkterm not found, using miniterm" >&2
    exec python3 -m serial.tools.miniterm --raw "$PORT" "$BAUD" ;;
  miniterm) exec python3 -m serial.tools.miniterm --raw "$PORT" "$BAUD" ;;
  *) echo "usage: $0 [gtkterm|miniterm|--prime]" >&2; exit 1 ;;
esac
