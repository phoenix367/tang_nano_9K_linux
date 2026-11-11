#!/usr/bin/env bash
# Video scanout system test (doc/video_plan.md): cache + PSRAM arbiter + video controller +
# PSRAM model, two clocks, real 640x480 timing, worst-case CPU traffic (~3 min).
#   verif/video/run_sys.sh            FRAMES=4 SEED=1 YOFF=0 (start line)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
B="$HERE/build"
mkdir -p "$B"
iverilog -g2012 -o "$B/tb_video_sys.vvp" -s tb_video_sys \
  -P tb_video_sys.FRAMES=${FRAMES:-4} -P tb_video_sys.SEED=${SEED:-1} -P tb_video_sys.YOFF=${YOFF:-0} \
  -P tb_video_sys.FONT_FILE="\"$REPO/rtl/video/font8x16.hex\"" \
  "$HERE/tb_video_sys.v" "$REPO/rtl/soc/l1_cache.v" "$REPO/rtl/soc/psram_arb.v" \
  "$REPO/rtl/sim/hyperram_x16_model.v" "$REPO/rtl/video/video_ctrl.v" "$REPO/rtl/video/video_dma.v" \
  "$REPO/rtl/video/video_out.v" "$REPO/rtl/video/tmds_encoder.v"
out=$(vvp -n "$B/tb_video_sys.vvp" | grep -vE "^VCD|finish called" || true)
echo "$out"
grep -q "^PASS" <<<"$out"
