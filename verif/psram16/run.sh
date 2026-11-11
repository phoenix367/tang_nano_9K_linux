#!/usr/bin/env bash
# Tests of the 16-bit HyperRAM controller (rtl/psram/hyperram_x16.v), in Icarus:
#   1. tb_hyperram.v: random traffic on the controller's command interface (line and word
#      writes with masks, reads from any word of a line) against two W955D8MBYA die models with
#      protocol checkers, per CK phase and seed; then the same traffic on the cycle model
#      rtl/sim/hyperram_x16_model.v, which the cache, video and SoC simulations use. Both must
#      pass, and the model must take as many cycles as the controller.
#   2. tb_psram16.v: the board probe fpga/probe_psram16 (its whole memory test, on LINES lines).
# The Gowin I/O primitives come from rtl/sim/gowin_io_sim.v, so no Gowin install is needed.
# Env: PHASES  CK phases in ns (default "2.976 5.952" = 45 and 90 degrees at 42 MHz). The die
#              model's datasheet limits bound its window: the first CK edge comes one phase after
#              CS# falls, so tCSS (2 ns) needs 30 degrees or more, and the worst-case tCKD
#              (5.5 ns) fails beyond ~95. The board passes 22.5 to 157.5 degrees.
#      SEEDS   (default "1 7")   OPS (default 2000)   LINES (default 64; the board does 262144)
#      PRIM=gowin  Gowin's own primitive models instead (IDE/simlib/gw1n/prim_sim.v)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
B="$HERE/build"
mkdir -p "$B"
if [[ "${PRIM:-}" == gowin ]]; then
  PRIMS=("$(echo "${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}")/IDE/simlib/gw1n/prim_sim.v")
  PDEF=(-DGOWIN_PRIM)
else
  PRIMS=("$REPO/rtl/sim/gowin_io_sim.v")
  PDEF=()
fi
PHASES="${PHASES:-2.976 5.952}" SEEDS="${SEEDS:-1 7}" OPS="${OPS:-2000}"
fail=0

check() {                                     # $1 log: PASS line and no FAIL
  grep -q "^PASS" "$1" && ! grep -q "FAIL" "$1"
}
cycles() { sed -n 's/.* in \([0-9]*\) cycles.*/\1/p' "$1"; }

for seed in $SEEDS; do
  m="$B/hr_model_s$seed.log"
  iverilog -g2012 -o "$B/hr_model_s$seed.vvp" -s tb_hyperram -P tb_hyperram.MODEL=1 \
    -P tb_hyperram.OPS="$OPS" -P tb_hyperram.SEED="$seed" "$HERE/tb_hyperram.v" \
    "$REPO/rtl/sim/hyperram_x16_model.v"
  vvp -n "$B/hr_model_s$seed.vvp" > "$m" 2>&1 || true
  mc=$(cycles "$m")
  echo "== tb_hyperram model seed $seed: $(grep -E '^(PASS|FAIL)' "$m" | head -1), ${mc:-?} cycles"
  check "$m" || { fail=1; tail -5 "$m"; }
  for ph in $PHASES; do
    l="$B/hr_rtl_s${seed}_ph$ph.log"
    iverilog -g2012 -o "$B/hr_rtl_s$seed.vvp" -s tb_hyperram -P tb_hyperram.MODEL=0 \
      -P tb_hyperram.OPS="$OPS" -P tb_hyperram.SEED="$seed" -P tb_hyperram.PHASE_NS="$ph" \
      "${PDEF[@]}" "$HERE/tb_hyperram.v" "$REPO/rtl/psram/hyperram_x16.v" \
      "$HERE/model/w955d8mbya_die.sv" "${PRIMS[@]}"
    vvp -n "$B/hr_rtl_s$seed.vvp" > "$l" 2>&1 || true
    rc=$(cycles "$l")
    echo "== tb_hyperram rtl seed $seed phase $ph ns: $(grep -E '^(PASS|FAIL)' "$l" | head -1)," \
         "${rc:-?} cycles, $(grep -o 'protocol errors: .*' "$l" || echo 'no error count')"
    check "$l" || { fail=1; grep -E "ERROR|FAIL" "$l" | head -5 || true; }
    if [[ -n "$rc" && "$rc" != "$mc" ]]; then
      echo "   FAIL: the model took $mc cycles, the controller $rc"; fail=1
    fi
  done
done

for ph in $PHASES; do
  l="$B/probe_ph$ph.log"
  iverilog -g2012 -o "$B/probe.vvp" -s tb_psram16 -P tb_psram16.PHASE_NS="$ph" -DPROBE_SIM \
    -DPROBE_LINES="${LINES:-64}" "${PDEF[@]}" "$HERE/tb_psram16.v" \
    "$REPO/fpga/probe_psram16/psram16_probe_top.v" "$REPO/rtl/psram/hyperram_x16.v" \
    "$HERE/model/w955d8mbya_die.sv" "${PRIMS[@]}"
  vvp -n "$B/probe.vvp" > "$l" 2>&1 || true
  echo "== probe phase $ph ns: $(grep -E 'UART|TIMEOUT' "$l" | sed 's/^UART: //')"
  # every count zero: e0 e1 s0 s1, and no model protocol error
  if ! grep -qE "UART: sim0 e0=000000 e1=000000 s0=00000 s1=00000 " "$l" ||
     ! grep -q "protocol errors: die0 0, die1 0" "$l"; then
    fail=1; grep -E "protocol|ERROR" "$l" | head -5 || true
  fi
done

if [[ $fail == 0 ]]; then echo "psram16: PASS"; else echo "psram16: FAIL"; exit 1; fi
