#!/usr/bin/env bash
# Write a Linux image to the Tang Nano 9K's external SPI flash for the boot ROM (~1 min).
#
#   sw/tools/flash_linux.sh [mmu|nommu]      default mmu (stage 2)
#
# Builds the flash image with sw/mkflash.py (mmu: header flag for S-mode boot) and programs
# it with Gowin's programmer_cli, operation 38 ("exFlash C Bin Erase,Program thru
# GAO-Bridge"): the programmer loads a bridge design into the FPGA's SRAM and writes the flash
# through it in ~1 min. openFPGALoader --external-flash bit-bangs SPI over the 6 MHz JTAG and
# takes ~1 h for the same 2.7 MB. The FPGA's SRAM holds the bridge afterwards, so load the
# SoC bitstream again or reconfigure from the internal flash (qerv_boot.py --reconfig).
#
# Env: GOWIN_PATH (default /mnt/data/Gowin_V1.9.12.02_SP2_linux),
#      WORK (default /mnt/data/build/tang9k_linux), SPLASH (boot splash picture; default: the
#      one sw/tools/mksplash.py draws), JTAG_FREQ (the cable's TCK for the bridge, default
#      2.5MHz, programmer_cli's own default; it also takes 2MHz, 1.5MHz, 1.1MHz, 0.9MHz,
#      0.75MHz, 0.5MHz, ...: slower writes take longer, ~70 KB/s at 2.5MHz).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GOWIN_PATH="${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}"
WORK="${WORK:-/mnt/data/build/tang9k_linux}"
JTAG_FREQ="${JTAG_FREQ:-2.5MHz}"
case "${1:-mmu}" in
  mmu)   IMG="$WORK/images-tang9k-mmu" DTB=tang9k-mmu.dtb OPT=--smode ;;
  nommu) IMG="$WORK/images-tang9k" DTB=tang9k.dtb OPT= ;;
  *)     echo "usage: $0 [mmu|nommu]" >&2; exit 1 ;;
esac
# boot splash (doc/video_plan.md): SPLASH=<image> to use a picture, default: the generated one
python3 "$REPO/sw/tools/mksplash.py" "$IMG/splash.rle" ${SPLASH:+"$SPLASH"}
python3 "$REPO/sw/mkflash.py" "$IMG/Image" "$IMG/$DTB" "$IMG/flash.bin" $OPT --splash "$IMG/splash.rle"
# programmer_cli cannot open the JTAG channel while the kernel's ftdi_sio driver holds it
# (/dev/ttyUSB0; openFPGALoader re-attaches it on exit), so detach that interface first.
detach_jtag() {
python3 -I - <<'PY'
import ctypes, ctypes.util, sys
lib = ctypes.CDLL(ctypes.util.find_library("usb-1.0"))
lib.libusb_open_device_with_vid_pid.restype = ctypes.c_void_p
ctx = ctypes.c_void_p()
lib.libusb_init(ctypes.byref(ctx))
h = ctypes.c_void_p(lib.libusb_open_device_with_vid_pid(ctx, 0x0403, 0x6010))
if not h.value:
    sys.exit("Tang Nano 9K debugger (0403:6010) not found")
if lib.libusb_kernel_driver_active(h, 0) == 1 and lib.libusb_detach_kernel_driver(h, 0) != 0:
    sys.exit("cannot detach ftdi_sio from the JTAG interface")
lib.libusb_close(h)
PY
}
cd "$GOWIN_PATH/Programmer/bin"
# The GAO-bridge write takes ~1 min, but now and then it hangs at the first sector erase
# ("Erasing sector at 0... 0%"; 5 of 12 runs). The hung runs reported bridge status
# 0x0003F020, the good ones 0x0001F020; once it hangs, retries in the same state hang too, and
# reconfiguring the FPGA from its internal flash cleared it. It can also stop partway through
# programming (once at 43%, for 45 min). So a watchdog stops an attempt whose progress line has
# not changed for 60 s, and the next attempt first reconfigures (openFPGALoader -r), then
# detaches ftdi_sio again and rescans the cable; each attempt starts by erasing the SRAM.
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
for attempt in 1 2 3; do
  if [[ $attempt -gt 1 ]]; then
    openFPGALoader -b tangnano9k -r > /dev/null 2>&1 || true
    sleep 1
  fi
  detach_jtag
  # cable-index 4 = "USB Debugger A", the board's BL702; --location from the cable scan
  LOC=$(./programmer_cli --scan-cables 2>&1 | sed -n 's#.*Cable found:  USB Debugger A/0/\([0-9]*\)/.*#\1#p' | head -1)
  # SRAM erase; it can hang too (seen after the board was power-cycled), so bound it
  timeout -s KILL 30 ./programmer_cli --device GW1NR-9C --run 24 --cable-index 4 \
      --location "${LOC:-0}" --frequency "$JTAG_FREQ" > /dev/null 2>&1 \
      || echo "attempt $attempt: SRAM erase failed or hung"
  echo "attempt $attempt: writing at TCK $JTAG_FREQ"
  ./programmer_cli --device GW1NR-9C --run 38 --mcuFile "$IMG/flash.bin" --spiaddr 0x000000 \
      --cable-index 4 --location "${LOC:-0}" --frequency "$JTAG_FREQ" > "$LOG" 2>&1 &
  PID=$!
  stall=0 last=
  while kill -0 "$PID" 2>/dev/null; do
    sleep 5
    cur=$(tr '\r' '\n' < "$LOG" | grep -a '%' | tail -1 || true)
    if [[ "$cur" != "$last" ]]; then
      last=$cur stall=0
    else
      stall=$((stall + 5))
      if [[ $stall -ge 60 ]]; then
        echo "attempt $attempt: GAO bridge stuck${cur:+ at ${cur%%:*} ${cur##* }}, retrying"
        # stuck there, programmer_cli ignores SIGTERM; and under set -e a kill of a process
        # that is already gone would end the script
        kill -9 "$PID" 2>/dev/null || true
        break
      fi
    fi
  done
  wait "$PID" || true
  if grep -q "Program flash finished" "$LOG"; then
    tr '\r' '\n' < "$LOG" | grep -av '%' | grep -av '^\s*$'
    exit 0
  fi
done
tr '\r' '\n' < "$LOG" | grep -av '%' | grep -av '^\s*$' | tail -5
echo "flash write failed after 3 attempts" >&2
exit 1
