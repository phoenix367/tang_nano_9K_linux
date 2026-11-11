#!/usr/bin/env bash
# Simulate fpga/probe_psram16 (rtl/psram/hyperram_x16.v + its test sequencer) against two
# W955D8MBYA die models with protocol checkers, in Icarus, with Gowin's primitive models.
#   verif/psram16/run.sh                       both die-1 clock wirings, 45 degrees
#   PHASES="1.488 2.976 4.464" verif/psram16/run.sh   CK phases in ns (22.5 deg = 1.488 ns)
#   LINES=64                                   lines per pass (default 64; the board does 262144)
# The probe's four configurations try both clock polarities of both dies (iv= bit 1 die 1,
# bit 0 die 0). The model ignores CK polarity for the data, so every configuration passes in
# simulation; the wrong polarities show up only as the model's protocol errors. On the board
# only the right ones work.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GOWIN="${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}"
PRIM="$GOWIN/IDE/simlib/gw1n/prim_sim.v"
B="$HERE/build"
mkdir -p "$B"
for ck1n in ${CK1NS:-1 0}; do
  for ph in ${PHASES:-2.976}; do
    tag="ck1n${ck1n}_ph${ph}"
    iverilog -g2012 -o "$B/$tag.vvp" -s tb_psram16 -P tb_psram16.CK1_N=$ck1n \
      -P tb_psram16.PHASE_NS=$ph -DPROBE_SIM -DPROBE_LINES="${LINES:-64}" \
      "$HERE/tb_psram16.v" "$REPO/fpga/probe_psram16/psram16_probe_top.v" \
      "$REPO/rtl/psram/hyperram_x16.v" "$HERE/model/w955d8mbya_die.sv" "$PRIM"
    echo "== CK1_N=$ck1n phase=${ph} ns"
    vvp -n "$B/$tag.vvp" > "$B/$tag.log" 2>&1 || true
    grep -E "UART|errors|TIMEOUT" "$B/$tag.log"
    # the model's protocol errors, by kind (the wrong-polarity configurations make some)
    grep -E "ERROR" "$B/$tag.log" | sed 's/.*\] //' | sort | uniq -c | sort -rn | head -6 | sed 's/^/   model: /' || true
  done
done
