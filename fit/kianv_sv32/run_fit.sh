#!/usr/bin/env bash
# Fit the KianV SV32 core for one TLB configuration.
#
#   fit/kianv_sv32/run_fit.sh [ITLB_ENTRIES] [DTLB_ENTRIES]     (default 64 64)
#
# Rewrites kianv_cfg.v, then runs fit/run_probe.sh with label itlb<I>_dtlb<D>.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITLB="${1:-64}"
DTLB="${2:-64}"

# ITLB is 4-way, DTLB 8-way (sv32.v): entries must be WAYS x 2^k.
for pair in "$ITLB:4" "$DTLB:8"; do
    n="${pair%%:*}"; ways="${pair##*:}"; sets=$((n / ways))
    if (( n % ways != 0 || sets < 1 || (sets & (sets - 1)) != 0 )); then
        echo "TLB entries must be $ways x 2^k (got $n)" >&2
        exit 1
    fi
done

sed -i -E \
    -e "s/^\`define NUM_ENTRIES_ITLB .*/\`define NUM_ENTRIES_ITLB $ITLB/" \
    -e "s/^\`define NUM_ENTRIES_DTLB .*/\`define NUM_ENTRIES_DTLB $DTLB/" \
    "$HERE/kianv_cfg.v"

exec "$HERE/../run_probe.sh" kianv_sv32 "itlb${ITLB}_dtlb${DTLB}"
