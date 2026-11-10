#!/usr/bin/env bash
# Video unit tests (doc/video_plan.md), Icarus with Gowin's primitive simulation models.
#   verif/video/run.sh            PHY=1 (reduced timing through OSER10) and PHY=0 (640x480)
#   PHYS="1" verif/video/run.sh   one of them
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GOWIN_PATH="${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}"
PRIM="$GOWIN_PATH/IDE/simlib/gw1n/prim_sim.v"
B="$HERE/build"
mkdir -p "$B"
fail=0
for phy in ${PHYS:-1 0}; do
  iverilog -g2012 -o "$B/tb_video_out_phy$phy.vvp" -s tb_video_out -P tb_video_out.PHY=$phy \
    -P tb_video_out.FONT_FILE="\"$REPO/rtl/video/font8x16.hex\"" \
    "$HERE/tb_video_out.v" "$REPO/rtl/video/video_out.v" "$REPO/rtl/video/tmds_encoder.v" \
    "$REPO/rtl/video/hdmi_phy_gowin.v" "$PRIM"
  out=$(vvp -n "$B/tb_video_out_phy$phy.vvp" | grep -vE "^VCD|^\$finish" || true)
  echo "$out"
  grep -q "^PASS" <<<"$out" || fail=1
done
exit $fail
