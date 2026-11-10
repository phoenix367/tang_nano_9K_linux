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
#      WORK (default /mnt/data/build/tang9k_linux).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GOWIN_PATH="${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}"
WORK="${WORK:-/mnt/data/build/tang9k_linux}"
case "${1:-mmu}" in
  mmu)   IMG="$WORK/images-tang9k-mmu" DTB=tang9k-mmu.dtb OPT=--smode ;;
  nommu) IMG="$WORK/images-tang9k" DTB=tang9k.dtb OPT= ;;
  *)     echo "usage: $0 [mmu|nommu]" >&2; exit 1 ;;
esac
python3 "$REPO/sw/mkflash.py" "$IMG/Image" "$IMG/$DTB" "$IMG/flash.bin" $OPT
# programmer_cli cannot open the JTAG channel while the kernel's ftdi_sio driver holds it
# (/dev/ttyUSB0; openFPGALoader re-attaches it on exit), so detach that interface first.
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
cd "$GOWIN_PATH/Programmer/bin"
# cable-index 4 = "USB Debugger A", the board's BL702; --location from the cable scan
LOC=$(./programmer_cli --scan-cables 2>&1 | sed -n 's#.*Cable found:  USB Debugger A/0/\([0-9]*\)/.*#\1#p' | head -1)
# Erase the FPGA's SRAM first: with a design running (e.g. ours, loaded from the internal
# flash) the GAO-bridge write crawls (>12 min instead of ~1 min).
./programmer_cli --device GW1NR-9C --run 24 --cable-index 4 --location "${LOC:-0}" > /dev/null
./programmer_cli --device GW1NR-9C --run 38 --mcuFile "$IMG/flash.bin" --spiaddr 0x000000 \
    --cable-index 4 --location "${LOC:-0}" 2>&1 | tr '\r' '\n' | grep -av '%' | grep -av '^\s*$'
