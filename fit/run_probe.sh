#!/usr/bin/env bash
# Synthesize + place-and-route one fit probe and keep its reports.
#
#   fit/run_probe.sh PROBE [LABEL]
#
# PROBE is a directory under fit/ holding <PROBE>_fit.gprj with top module <PROBE>_fit_top.
# Reports are copied to fit/<PROBE>/results/<LABEL>/ (LABEL defaults to "default") and
# summarized by fit/summarize.py. fit/<PROBE>/impl/ is scratch build output.
#
# Env: GOWIN_PATH (default /mnt/data/Gowin_V1.9.12.02_SP2_linux), STAGE (default all).
set -euo pipefail

FIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${1:?usage: run_probe.sh PROBE [LABEL]}"
LABEL="${2:-default}"
DIR="$FIT/$PROBE"

export GOWIN_PATH="${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}"
export STAGE="${STAGE:-all}"
export GPRJ="$DIR/${PROBE}_fit.gprj"
export TOP="${PROBE}_fit_top"
[[ -f "$GPRJ" ]] || { echo "no project $GPRJ" >&2; exit 1; }

rm -rf "$DIR/impl/gwsynthesis" "$DIR/impl/pnr"
"$FIT/../scripts/gw_run.sh"

OUT="$DIR/results/$LABEL"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$DIR"/*_cfg.v "$OUT/" 2>/dev/null || true
find "$DIR/impl/gwsynthesis" "$DIR/impl/pnr" -maxdepth 1 -type f \
    \( -name '*.rpt.html' -o -name '*.rpt.txt' -o -name '*_tr_content.html' -o -name '*.log' \) \
    -exec cp {} "$OUT/" \;
python3 "$FIT/summarize.py" "$OUT"
