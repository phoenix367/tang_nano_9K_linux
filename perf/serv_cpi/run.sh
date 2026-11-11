#!/usr/bin/env bash
# Rebuild and rerun the SERV/QERV per-instruction-class cycle benchmark from scratch.
#
#   perf/serv_cpi/run.sh            # W=1 and W=4, plus 1-extra-wait-state runs
#   LATENCY_RUNS=0 perf/serv_cpi/run.sh   # skip the extra-wait-state (sensitivity) runs
#
# Output: perf/serv_cpi/results.json (+ build/ with program, traces, logs).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
B="$HERE/build"
TC="${RISCV_PREFIX:-/mnt/data/xilinx/2025.2/Vitis/gnu/riscv/lin/bin/riscv64-unknown-elf-}"
LATENCY_RUNS="${LATENCY_RUNS:-1}"

rm -rf "$B"
mkdir -p "$B"
cd "$HERE"

echo "== generate + assemble test program"
python3 gen_tests.py "$B"
"${TC}gcc" -march=rv32im_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
    -Wl,--build-id=none -Wl,--no-warn-rwx-segments -T link.ld \
    -o "$B/serv_cpi_tests.elf" "$B/serv_cpi_tests.S"
"${TC}objcopy" -O binary "$B/serv_cpi_tests.elf" "$B/serv_cpi_tests.bin"
"${TC}objdump" -d "$B/serv_cpi_tests.elf" > "$B/serv_cpi_tests.dis"
"${TC}nm" "$B/serv_cpi_tests.elf" > "$B/symbols.txt"
python3 - "$B/serv_cpi_tests.bin" "$B/serv_cpi_tests.hex" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
d += bytes((-len(d)) % 4)
words = [int.from_bytes(d[i:i + 4], "little") for i in range(0, len(d), 4)]
words += [0] * (0x40000 // 4 - len(words))          # fill servant_ram (256 KiB)
open(sys.argv[2], "w").write("\n".join(f"{w:08x}" for w in words) + "\n")
PY

echo "== reference ISS"
python3 iss.py "$B/serv_cpi_tests.bin" "$B/iss.json"

echo "== compile testbenches (iverilog)"
RTL=$(ls "$REPO"/external/sparrow-serv/rtl/*.v | grep -v serv_synth_wrapper)
SRCS="$HERE/tb/serv_cpi_tb.v $RTL $REPO/external/mdu/rtl/mdu_top.v \
      $REPO/external/sparrow-serv/servile/servile_arbiter.v $REPO/external/sparrow-serv/servant/servant_ram.v"
LATS="0"
[ "$LATENCY_RUNS" = "1" ] && LATS="0 1"
pids=()
for W in 1 4; do
  for L in $LATS; do
    iverilog -g2012 -DSERV_CLEAR_RAM -s serv_cpi_tb -o "$B/tb_w${W}_l${L}.vvp" \
      -P serv_cpi_tb.W=$W -P serv_cpi_tb.EXTRA_WAIT=$L -P serv_cpi_tb.TIMEOUT=20000000 \
      -P "serv_cpi_tb.memfile=\"$B/serv_cpi_tests.hex\"" $SRCS
    echo "   simulating W=$W extra_wait=$L ..."
    ( vvp -n "$B/tb_w${W}_l${L}.vvp" +trace="$B/trace_w${W}_l${L}.log" \
        > "$B/sim_w${W}_l${L}.out" 2>&1 ) &
    pids+=($!)
  done
done
for p in "${pids[@]}"; do wait "$p"; done
for f in "$B"/sim_*.out; do echo "   $(basename "$f"): $(grep -E 'HALT|TIMEOUT' "$f" || echo 'no HALT line')"; done

echo "== analyze"
python3 analyze.py "$B" "$HERE/results.json"
python3 report.py "$HERE/results.json"
