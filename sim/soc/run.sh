#!/usr/bin/env bash
# Build the QERV SoC Verilator model and boot the stage-1 Linux image on it.
#
#   sim/soc/run.sh                              # boot to the shell prompt
#   INPUT='free\nls /\n' sim/soc/run.sh         # then type commands
#   W=1 sim/soc/run.sh                          # SERV instead of QERV
#   FLASH=1 sim/soc/run.sh                      # boot ROM copies Image+DTB from SPI flash
#   BREAK_PC=8003ea70 sim/soc/run.sh            # stop there, dump last 20k fetches + CPU state
#   UART_LOG=<file> sim/soc/run.sh              # console copy elsewhere than results/
#   PC_PROF=1 sim/soc/run.sh                    # cycle profile per PC -> $WORK/soc_<tag>.pcprof
#     PROF_FROM='text' PROF_TO='text'           # ... only between two console messages
#   CONFIG=mmu sim/soc/run.sh                   # stage 2: S-mode CPU + MMU kernel (boot ROM 'B')
#   ROM_INPUT=recs.bin sim/soc/run.sh           # boot ROM command records (see sim_main.cpp);
#                                               # default: 'b' (preloaded RAM) or 'f' (FLASH=1)
#   ROM_CMD=b sim/soc/run.sh                    # that one command instead (CONFIG=mmu: 'B')
#   IMAGE=<file.bin> sim/soc/run.sh             # boot this instead of the kernel Image
#                                               # (bare-metal tests: sw/tests/build.sh)
#
# Image/DTB come from sw/build.sh ($WORK/images-tang9k). The Verilator build lives in
# $WORK/verilator-soc-w<W>; the console log goes to sim/soc/results/.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${WORK:-/mnt/data/build/tang9k_linux}"
W="${W:-4}"
case "${CONFIG:-nommu}" in
  nommu) SMODE=0 TAG="w$W" IMG="$WORK/images-tang9k" DTB=tang9k.dtb BOOT=b ;;
  mmu)   SMODE=1 TAG="w$W-mmu" IMG="$WORK/images-tang9k-mmu" DTB=tang9k-mmu.dtb BOOT=B ;;
  *)     echo "CONFIG must be nommu or mmu" >&2; exit 1 ;;
esac
# VIDEO=1: the video controller, at the board's clocks (CPU 42 MHz, pixel 25.2 MHz);
# FRAME_DUMP=1 writes every 60th frame as $WORK/frames-<tag>/f<n>.ppm
VIDEO="${VIDEO:-0}"
CLK_HZ=27000000
if [[ "$VIDEO" == 1 ]]; then TAG="$TAG-video"; CLK_HZ=42000000; fi
OBJ="$WORK/verilator-soc-$TAG"

"$REPO/sw/bootrom/build.sh" "$OBJ/bootrom.hex" > /dev/null

SRCS=("$HERE/tb_soc.v" "$REPO"/rtl/soc/*.v "$REPO"/rtl/i2c/*.v "$REPO"/rtl/qerv/*.v "$REPO/rtl/sim/psram_ui_model.v" "$REPO/rtl/sim/spi_flash_model.v" "$REPO/rtl/sim/i2c_eeprom_model.v"
      "$REPO/rtl/video/video_ctrl.v" "$REPO/rtl/video/video_dma.v" "$REPO/rtl/video/video_out.v" "$REPO/rtl/video/tmds_encoder.v"
      "$REPO/external/mdu/rtl/mdu_top.v" "$REPO/external/sparrow-serv/servile/servile_arbiter.v")
for f in "$REPO"/external/sparrow-serv/rtl/*.v; do
  case "$f" in *serv_synth_wrapper.v|*serv_debug.v) ;; *) SRCS+=("$f") ;; esac
done

verilator --cc --exe --build -j "$(nproc)" -O3 --x-assign fast --x-initial fast \
    -Wno-fatal -Wno-lint -Wno-style --top-module tb_soc -Mdir "$OBJ" \
    -GCPU_W="$W" -GCPU_SMODE="$SMODE" -GVIDEO="$VIDEO" -GCLK_HZ="$CLK_HZ" -GFONT_FILE="\"$REPO/rtl/video/font8x16.hex\"" -GBOOTROM_FILE="\"$OBJ/bootrom.hex\"" \
    "${SRCS[@]}" "$HERE/sim_main.cpp" -o Vtb_soc > "$OBJ.build.log" 2>&1 \
  || { tail -30 "$OBJ.build.log"; exit 1; }

mkdir -p "$HERE/results"
if [[ -n "${FLASH:-}" ]]; then
  python3 "$REPO/sw/mkflash.py" "$IMG/Image" "$IMG/$DTB" "$IMG/flash.bin" $([[ $SMODE == 1 ]] && echo --smode) > /dev/null
  args=(+flash_load="$IMG/flash.bin" +flash_addr=0)
else
  args=(+psram_load0="${IMAGE:-$IMG/Image}" +psram_addr0=0 +psram_load1="$IMG/$DTB" +psram_addr1=7ff000)
fi
if [[ -z "${ROM_INPUT:-}" ]]; then
  ROM_INPUT="$OBJ/rom_input.bin"
  python3 -c 'import sys,struct; c=sys.argv[2].encode(); open(sys.argv[1],"wb").write(struct.pack("<I",len(c))+c)' \
      "$ROM_INPUT" "$([[ -n "${FLASH:-}" ]] && echo f || echo ${ROM_CMD:-$BOOT})"
fi
args+=(+rom_input="$ROM_INPUT" +uart_log="${UART_LOG:-$HERE/results/soc_$TAG.uart.log}" +clk_hz="$CLK_HZ")
if [[ "$VIDEO" == 1 ]]; then
  args+=(+video)
  [[ -n "${FRAME_DUMP:-}" ]] && { mkdir -p "$WORK/frames-$TAG"; args+=(+frame_dump="$WORK/frames-$TAG/f"); }
fi
[[ -n "${INPUT:-}" ]] && args+=(+input="$INPUT")
[[ -n "${MAX_CYCLES:-}" ]] && args+=(+max_cycles="$MAX_CYCLES")
[[ -n "${FETCH_TRACE:-}" ]] && args+=(+fetch_trace="$HERE/results/soc_$TAG.fetch")
[[ -n "${PC_PROF:-}" ]] && args+=(+pc_prof="$WORK/soc_$TAG.pcprof")   # big: kept off the root disk
[[ -n "${PROF_FROM:-}" ]] && args+=(+prof_from="$PROF_FROM")
[[ -n "${PROF_TO:-}" ]] && args+=(+prof_to="$PROF_TO")
[[ -n "${BREAK_PC:-}" ]] && args+=(+break_pc="$BREAK_PC" +break_dump="$HERE/results/soc_$TAG.break.txt")
time "$OBJ/Vtb_soc" "${args[@]}" ${QUIET:+ +quiet}
