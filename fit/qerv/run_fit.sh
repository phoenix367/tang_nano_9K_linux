#!/usr/bin/env bash
# Fit SERV + MDU at one datapath width.
#
#   fit/qerv/run_fit.sh [W]     W = 1 (SERV) or 4 (QERV, default)
#
# Rewrites qerv_cfg.v, then runs fit/run_probe.sh with label w<W>.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${1:-4}"
[[ "$W" == 1 || "$W" == 4 ]] || { echo "W must be 1 or 4 (got $W)" >&2; exit 1; }

sed -i -E "s/^\`define SERV_W .*/\`define SERV_W $W/" "$HERE/qerv_cfg.v"

exec "$HERE/../run_probe.sh" qerv "w${W}"
