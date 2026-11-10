#!/usr/bin/env bash
# Fit the QERV-Linux CPU (SERV LINUX=1 + MDU + AMO unit) at one datapath width.
#
#   fit/qerv_linux/run_fit.sh [W]     W = 1 (SERV) or 4 (QERV, default)
#
# Rewrites qerv_linux_cfg.v, then runs fit/run_probe.sh with label w<W>.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${1:-4}"
[[ "$W" == 1 || "$W" == 4 ]] || { echo "W must be 1 or 4 (got $W)" >&2; exit 1; }

sed -i -E "s/^\`define SERV_W .*/\`define SERV_W $W/" "$HERE/qerv_linux_cfg.v"

exec "$HERE/../run_probe.sh" qerv_linux "w${W}"
