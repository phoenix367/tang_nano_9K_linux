#!/usr/bin/env bash
# PSRAM user-interface model checks.
#
#   verif/psram/run.sh            fast checks (seconds):
#                                   1. tb_model_unit in Icarus and Verilator
#                                   2. tb_psram_ip stimulus replayed on the model
#                                      alone, diffed against the recorded real-IP
#                                      trace verif/psram/golden/trace_ip.txt
#   verif/psram/run.sh --ip       full run against the real Gowin netlist + pin
#                                   models (Icarus, ~16 ms simulated, about an
#                                   hour of wall time; the IP's read-calibration
#                                   sweep dominates). Compares the model live,
#                                   then refreshes golden/trace_ip.txt and
#                                   golden/ip_run.log.
#
# Env: OV7670 (default ~/projects/tang_nano_9K_ov7670), GOWIN (default $GOWIN_PATH, else
# /mnt/data/Gowin_V1.9.12.02_SP2_linux), OUT (work dir, default verif/psram/build, git-ignored),
# TCKD (pin-model CK->DQ read delay in ns, default 2.0).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MODEL="$ROOT/rtl/sim/psram_ui_model.v"
OV7670="${OV7670:-$HOME/projects/tang_nano_9K_ov7670}"
GOWIN="${GOWIN:-${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}}"
IPVO="$OV7670/src/psram_memory_interface_hs_2ch/psram_memory_interface_hs_2ch.vo"
PRIM="$GOWIN/IDE/simlib/gw1n/prim_sim.v"
OUT="${OUT:-$HERE/build}"
TCKD="${TCKD:-2.0}"
mkdir -p "$OUT"
cd "$OUT"
echo "work dir: $OUT"

# model parameters the benches use (keep in sync with psram_ui_model defaults)
MDEFS=(-DM_RD_LATENCY=16 -DM_WR_BEAT0=0 -DM_CHECK_RD_BUSY=0)

fail=0
legal_phases() { awk '$1 <= 6' "$1"; }

if [[ "${1:-}" == "--ip" ]]; then
    [[ -f "$IPVO" ]] || { echo "missing $IPVO"; exit 2; }
    [[ -f "$PRIM" ]] || { echo "missing $PRIM"; exit 2; }
    echo "== real IP + pin models + model (long)"
    iverilog -g2012 -DTCKD="$TCKD" "${MDEFS[@]}" -DM_CALIB=1055888 -s tb_psram_ip -s GSR -o tb_ip.vvp \
        "$HERE/tb_psram_ip.v" "$HERE/hyperram_model.v" "$MODEL" "$IPVO" "$PRIM" 2> iverilog_ip.log \
        || { cat iverilog_ip.log; exit 1; }
    vvp -n tb_ip.vvp > ip_run.log 2>&1 || true
    grep -E "^==== (init|SUMMARY)|RESULT" ip_run.log || true
    grep -q "RESULT: PASS" ip_run.log || fail=1
    mkdir -p "$HERE/golden"
    cp trace_ip.txt "$HERE/golden/trace_ip.txt"
    cp ip_run.log "$HERE/golden/ip_run.log"
    echo "golden trace refreshed: $HERE/golden/trace_ip.txt"
    exit $fail
fi

echo "== 1. tb_model_unit (Icarus)"
head -c 1000 /dev/urandom > unit_img0.bin
head -c 777 /dev/urandom > unit_img1.bin
PLUS=(+psram_load0=unit_img0.bin +psram_addr0=001000 +psram_load1=unit_img1.bin +psram_addr1=7FF000)
iverilog -g2012 -s tb_model_unit -o tbu.vvp "$HERE/tb_model_unit.v" "$MODEL"
vvp -n tbu.vvp "${PLUS[@]}" > unit_icarus.log 2>&1 || true
tail -1 unit_icarus.log | grep -q . ; grep RESULT unit_icarus.log
grep -q "RESULT: PASS" unit_icarus.log || fail=1

echo "== 1b. tb_model_unit (Verilator)"
if command -v verilator > /dev/null; then
    verilator --binary --timing -j 4 -Wno-fatal -Wno-lint -Wno-style --top-module tb_model_unit \
        "$HERE/tb_model_unit.v" "$MODEL" -o vtbu > verilator_build.log 2>&1 \
        || { tail -20 verilator_build.log; exit 1; }
    ./obj_dir/vtbu "${PLUS[@]}" > unit_verilator.log 2>&1 || true
    grep RESULT unit_verilator.log
    grep -q "RESULT: PASS" unit_verilator.log || fail=1
    verilator --lint-only -Wall "$MODEL" && echo "verilator -Wall lint of the model: clean"
else
    echo "verilator not found, skipped"
fi

echo "== 2. replay of the real-IP stimulus on the model vs golden/trace_ip.txt"
if [[ -f "$HERE/golden/trace_ip.txt" ]]; then
    iverilog -g2012 -DFAST_MODEL_ONLY "${MDEFS[@]}" -DM_CALIB=100 -s tb_psram_ip -o tb_fast.vvp \
        "$HERE/tb_psram_ip.v" "$MODEL"
    vvp -n tb_fast.vvp > fast_run.log 2>&1 || true
    if diff <(legal_phases "$HERE/golden/trace_ip.txt") <(legal_phases trace_model.txt) > trace.diff; then
        echo "model trace == real-IP trace for all legal phases ($(legal_phases trace_model.txt | wc -l) read beats)"
    else
        echo "TRACE MISMATCH (first lines of $OUT/trace.diff):"; head -20 trace.diff; fail=1
    fi
else
    echo "no golden trace yet: run '$0 --ip' once"; fail=1
fi

if [[ $fail -eq 0 ]]; then echo "ALL PASS"; else echo "SOME CHECKS FAILED"; fi
exit $fail
