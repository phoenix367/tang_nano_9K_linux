#!/usr/bin/env bash
# Build the QERV SoC Verilator model and boot the stage-1 Linux image on it.
#
#   sim/soc/run.sh                              # boot to the shell prompt
#   INPUT='free\nls /\n' sim/soc/run.sh         # then type commands
#   W=1 sim/soc/run.sh                          # SERV instead of QERV
#   FLASH=1 sim/soc/run.sh                      # boot ROM copies Image+DTB from SPI flash
#   BREAK_PC=8003ea70 sim/soc/run.sh            # stop there, dump last 20k fetches + CPU state
#
# Image/DTB come from sw/build.sh ($WORK/images-tang9k). The Verilator build lives in
# $WORK/verilator-soc-w<W>; the console log goes to sim/soc/results/.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${WORK:-/mnt/data/build/tang9k_linux}"
W="${W:-4}"
OBJ="$WORK/verilator-soc-w$W"
IMG="$WORK/images-tang9k"

"$REPO/sw/bootrom/build.sh" "$OBJ/bootrom.hex" > /dev/null

SRCS=("$HERE/tb_soc.v" "$REPO"/rtl/soc/*.v "$REPO"/rtl/qerv/*.v "$REPO/rtl/sim/psram_ui_model.v" "$REPO/rtl/sim/spi_flash_model.v"
      "$REPO/external/mdu/rtl/mdu_top.v" "$REPO/external/serv/servile/servile_arbiter.v")
for f in "$REPO"/external/serv/rtl/*.v; do
  case "$f" in *serv_synth_wrapper.v|*serv_debug.v) ;; *) SRCS+=("$f") ;; esac
done

verilator --cc --exe --build -j "$(nproc)" -O3 --x-assign fast --x-initial fast \
    -Wno-fatal -Wno-lint -Wno-style --top-module tb_soc -Mdir "$OBJ" \
    -GCPU_W="$W" -GBOOTROM_FILE="\"$OBJ/bootrom.hex\"" \
    "${SRCS[@]}" "$HERE/sim_main.cpp" -o Vtb_soc > "$OBJ.build.log" 2>&1 \
  || { tail -30 "$OBJ.build.log"; exit 1; }

mkdir -p "$HERE/results"
if [[ -n "${FLASH:-}" ]]; then
  python3 "$REPO/sw/mkflash.py" "$IMG/Image" "$IMG/tang9k.dtb" "$IMG/flash.bin" > /dev/null
  args=(+flash_load="$IMG/flash.bin" +flash_addr=0)
else
  args=(+psram_load0="$IMG/Image" +psram_addr0=0 +psram_load1="$IMG/tang9k.dtb" +psram_addr1=7ff000)
fi
args+=(+uart_log="$HERE/results/soc_w$W.uart.log")
[[ -n "${INPUT:-}" ]] && args+=(+input="$INPUT")
[[ -n "${MAX_CYCLES:-}" ]] && args+=(+max_cycles="$MAX_CYCLES")
[[ -n "${FETCH_TRACE:-}" ]] && args+=(+fetch_trace="$HERE/results/soc_w$W.fetch")
[[ -n "${BREAK_PC:-}" ]] && args+=(+break_pc="$BREAK_PC" +break_dump="$HERE/results/soc_w$W.break.txt")
time "$OBJ/Vtb_soc" "${args[@]}" ${QUIET:+ +quiet}
