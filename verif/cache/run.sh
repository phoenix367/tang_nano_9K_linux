#!/usr/bin/env bash
# L1 cache + PSRAM arbiter unit test (Icarus, ~1 min): random cached and uncached traffic with
# an 8-line cache, cache-block operations (Zicbom), plus a video-like DMA reader on the
# arbiter (DMA=0 to leave it out).
#   verif/cache/run.sh            DMA on and off
#   DMAS=1 OPS=100000 SEED=7 verif/cache/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
B="$HERE/build"
mkdir -p "$B"
fail=0
for dma in ${DMAS:-1 0}; do
  iverilog -g2012 -o "$B/tb_cache_dma$dma.vvp" -s tb_cache -P tb_cache.DMA=$dma \
    -P tb_cache.OPS=${OPS:-40000} -P tb_cache.SEED=${SEED:-1} \
    "$HERE/tb_cache.v" "$REPO/rtl/soc/l1_cache.v" "$REPO/rtl/soc/psram_arb.v" "$REPO/rtl/sim/psram_ui_model.v"
  out=$(vvp -n "$B/tb_cache_dma$dma.vvp" | grep -vE "^VCD|finish called" || true)
  echo "DMA=$dma: $out" | sed '2,$s/^/       /'
  grep -q "^PASS" <<<"$out" || fail=1
done
exit $fail
