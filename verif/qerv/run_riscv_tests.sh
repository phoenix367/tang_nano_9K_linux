#!/usr/bin/env bash
# Run the official riscv-tests (rv32ui, rv32um, rv32ua; "p" environment, user mode) on the
# QERV-Linux CPU in Icarus, at W=4 (QERV) and W=1 (SERV).
#
#   verif/qerv/run_riscv_tests.sh            # all suites, both widths
#   WIDTHS=4 SUITES="rv32ua" verif/qerv/run_riscv_tests.sh
#   SMODE=1 SUITES="rv32si rv32ui" verif/qerv/run_riscv_tests.sh   # stage-2 core (S-mode)
#   SMODE=1 ENV=v SUITES=rv32ui verif/qerv/run_riscv_tests.sh  # user tests on demand-paged
#                                                              # SV32 (riscv-tests env/v)
#
# On the stage-2 core rv32si-p-dirty is skipped: it needs mstatus.MPRV (not implemented;
# Linux and the boot ROM firmware do not use it).
#
# rv32ui-p-ma_data is skipped: it needs misaligned loads/stores to work, SERV traps them
# (Linux emulates them in its M-mode trap handler).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
RT="$REPO/external/riscv-tests"
B="$HERE/build/riscv-tests"
TC="${RISCV_PREFIX:-/mnt/data/xilinx/2025.2/Vitis/gnu/riscv/lin/bin/riscv64-unknown-elf-}"
WIDTHS="${WIDTHS:-4 1}"
SUITES="${SUITES:-rv32ui rv32um rv32ua}"
SMODE="${SMODE:-0}"
ENV="${ENV:-p}"
SKIP="${SKIP:-ma_data$([[ $SMODE == 1 ]] && echo ' dirty')}"
MEMSIZE=65536
[[ "$ENV" == v ]] && MEMSIZE=524288  # env/v pages its 63 user pages in above the program

rm -rf "$B"
mkdir -p "$B"

RTL="$REPO/rtl/qerv/qerv_cpu.v $REPO/rtl/qerv/amo_unit.v $REPO/rtl/qerv/sv32_mmu.v \
     $(ls "$REPO"/external/serv/rtl/*.v | grep -v serv_synth_wrapper) \
     $REPO/external/mdu/rtl/mdu_top.v \
     $REPO/external/serv/servile/servile_arbiter.v $REPO/external/serv/servant/servant_ram.v"

for W in $WIDTHS; do
  iverilog -g2012 -s qerv_tb -o "$B/tb_w$W.vvp" -P qerv_tb.W=$W -P qerv_tb.SMODE=$SMODE -P qerv_tb.MEMSIZE=$MEMSIZE -P qerv_tb.TIMEOUT=2000000 \
    -P 'qerv_tb.memfile="prog.hex"' "$HERE/tb/qerv_tb.v" $RTL
done

tests=()
for s in $SUITES; do
  for t in $(sed -n "/^${s}_sc_tests = /,/^\$/p" "$RT/isa/$s/Makefrag" | tr -d '\\' | tail -n +2); do
    [[ " $SKIP " == *" $t "* ]] && continue
    tests+=("$s-$ENV-$t")
  done
done

for t in "${tests[@]}"; do
  s="${t%%-$ENV-*}"; n="${t#*-$ENV-}"
  d="$B/$t"; mkdir -p "$d"
  if [[ "$ENV" == v ]]; then
    # F only so vm.c's never-executed "fssr x0" pattern assembles; ilp32 = no FP code is made
    "${TC}gcc" -march=rv32imaf_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany \
        -fvisibility=hidden -nostdlib -nostartfiles -Wl,--build-id=none -std=gnu99 -O2 \
        -DENTROPY=0x$(echo "$t" | md5sum | cut -c 1-7) -T "$RT/env/v/link.ld" \
        -I "$RT/env/v" -I "$RT/isa/macros/scalar" "$RT/env/v/entry.S" "$RT"/env/v/*.c \
        "$RT/isa/$s/$n.S" -lgcc -o "$d/prog.elf"
  else
    "${TC}gcc" -march=rv32ima_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany \
        -fvisibility=hidden -nostdlib -nostartfiles -Wl,--build-id=none -T "$RT/env/p/link.ld" \
        -I "$RT/env/p" -I "$RT/isa/macros/scalar" "$RT/isa/$s/$n.S" -o "$d/prog.elf"
  fi
  "${TC}objcopy" -O binary "$d/prog.elf" "$d/prog.bin"
  python3 - "$d/prog.bin" "$d/prog.hex" "$MEMSIZE" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
size = int(sys.argv[3])
data += bytes(size - len(data))
open(sys.argv[2], "w").write("\n".join(
    f"{int.from_bytes(data[i:i + 4], 'little'):08x}" for i in range(0, size, 4)) + "\n")
PY
  "${TC}nm" "$d/prog.elf" | awk '$3 == "tohost" {print $1}' > "$d/tohost"
done

fail=0
for W in $WIDTHS; do
  pass=0; total=0; bad=()
  for t in "${tests[@]}"; do
    d="$B/$t"
    out=$(cd "$d" && vvp -n "$B/tb_w$W.vvp" +tohost="$(cat tohost)" 2>&1 | grep -E "TOHOST|HALT|TIMEOUT" || true)
    total=$((total + 1))
    if [[ "$out" == TOHOST\ value=00000001* ]]; then
      pass=$((pass + 1))
    else
      bad+=("$t: ${out:-no result}")
    fi
  done
  echo "W=$W: $pass/$total passed"
  for b in "${bad[@]+"${bad[@]}"}"; do echo "  FAIL $b"; done
  [[ $pass -eq $total ]] || fail=1
done
exit $fail
