#!/usr/bin/env bash
# Build boot_trace and trace Linux images to the shell prompt.
#
#   perf/boot_trace/run.sh                 # our image (sw/build.sh output), 8 MB
#   STOCK=1 perf/boot_trace/run.sh         # cnlohr's prebuilt images, RAM_MB="8 16"
#   RAM_MB=16 US="0.3 0.45" perf/boot_trace/run.sh
#   TRACE=1 perf/boot_trace/run.sh         # also dump a PC trace (<out>.pc, u32 per instr)
#   PROFILE=1 perf/boot_trace/run.sh       # PC histogram (<out>.hist); see profile.py
#   INPUT='free\ncat /proc/meminfo\n' perf/boot_trace/run.sh   # type commands at the prompt
#
# Each run writes perf/boot_trace/results/<name>_m<MB>_u<US>.json plus the UART log.
# Downloads and build output live under $WORK (default /mnt/data/build/tang9k_linux).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${WORK:-/mnt/data/build/tang9k_linux}"
STOCK_IMAGES=(linux-6.1.14-rv32nommu-cnl-1 linux-6.8-rc1-rv32nommu-cnl-1)

mkdir -p "$HERE/results"
gcc -O2 -Wall -Wno-unused-function -I"$REPO/external/mini-rv32ima/mini-rv32ima" \
    "$HERE/boot_trace.c" -o "$WORK/boot_trace"

# name|image|dtb ("" = emulator's built-in DTB)
RUNS=()
if [[ -n "${STOCK:-}" ]]; then
    mkdir -p "$WORK/images"
    for img in "${STOCK_IMAGES[@]}"; do
        if [[ ! -f "$WORK/images/$img/Image" ]]; then
            curl -sSfL -o "$WORK/images/$img.zip" \
                "https://raw.githubusercontent.com/cnlohr/mini-rv32ima-images/master/images/$img.zip"
            mkdir -p "$WORK/images/$img"
            unzip -o -q "$WORK/images/$img.zip" -d "$WORK/images/$img"
        fi
        RUNS+=("$img|$WORK/images/$img/Image|")
    done
    read -r -a RAM_LIST <<< "${RAM_MB:-8 16}"
else
    RUNS+=("tang9k|$WORK/images-tang9k/Image|$WORK/images-tang9k/tang9k.dtb")
    read -r -a RAM_LIST <<< "${RAM_MB:-8}"
fi
read -r -a US_LIST <<< "${US:-0.3}"

for run in "${RUNS[@]}"; do
    IFS='|' read -r name image dtb <<< "$run"
    for mb in "${RAM_LIST[@]}"; do
        for us in "${US_LIST[@]}"; do
            out="$HERE/results/${name}_m${mb}_u${us}"
            echo "== $name, ${mb} MB, ${us} us/instr"
            args=(-q -f "$image" -m $((mb * 1024 * 1024)) -u "$us" -o "$out.json" -L "$out.uart.log")
            [[ -n "$dtb" ]] && args+=(-b "$dtb")
            [[ -n "${TRACE:-}" ]] && args+=(-T "$out.pc")
            [[ -n "${PROFILE:-}" ]] && args+=(-P "$out.hist")
            [[ -n "${INPUT:-}" ]] && args+=(-i "$INPUT")
            "$WORK/boot_trace" "${args[@]}" || echo "   (did not reach the shell: see $out.uart.log)"
        done
    done
done
