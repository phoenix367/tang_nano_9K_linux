#!/usr/bin/env bash
# M1 directed tests (verif/qerv/tests/*.S) on the QERV-Linux CPU, checked two ways:
# the program checks itself (HALT value 0 = pass, else the failing test id) and the RTL
# fetch sequence and stores must match verif/qerv/iss.py exactly.
#
#   verif/qerv/run_directed.sh        # W=4 and W=1, each with 0 and 1 extra wait states
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
B="$HERE/build/directed"
TC="${RISCV_PREFIX:-/mnt/data/xilinx/2025.2/Vitis/gnu/riscv/lin/bin/riscv64-unknown-elf-}"
MEMSIZE=65536

rm -rf "$B"
mkdir -p "$B"
RTL="$REPO/rtl/qerv/qerv_cpu.v $REPO/rtl/qerv/amo_unit.v \
     $(ls "$REPO"/external/serv/rtl/*.v | grep -v serv_synth_wrapper) \
     $REPO/external/mdu/rtl/mdu_top.v \
     $REPO/external/serv/servile/servile_arbiter.v $REPO/external/serv/servant/servant_ram.v"

status=0
for src in "$HERE"/tests/*.S; do
  name=$(basename "$src" .S)
  d="$B/$name"; mkdir -p "$d"
  "${TC}gcc" -march=rv32ima_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
      -Wl,--build-id=none -T "$HERE/link.ld" "$src" -o "$d/prog.elf"
  "${TC}objcopy" -O binary "$d/prog.elf" "$d/prog.bin"
  "${TC}objdump" -d "$d/prog.elf" > "$d/prog.dis"
  python3 - "$d/prog.bin" "$d/prog.hex" "$MEMSIZE" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
size = int(sys.argv[3])
data += bytes(size - len(data))
open(sys.argv[2], "w").write("\n".join(
    f"{int.from_bytes(data[i:i + 4], 'little'):08x}" for i in range(0, size, 4)) + "\n")
PY
  python3 "$HERE/iss.py" "$d/prog.bin" "$d/iss.json"
  for W in 4 1; do
    for L in 0 1; do
      iverilog -g2012 -s qerv_tb -o "$d/tb.vvp" -P qerv_tb.W=$W -P qerv_tb.EXTRA_WAIT=$L \
        -P qerv_tb.MEMSIZE=$MEMSIZE -P qerv_tb.TIMEOUT=2000000 \
        -P "qerv_tb.memfile=\"$d/prog.hex\"" "$HERE/tb/qerv_tb.v" $RTL
      res=$(vvp -n "$d/tb.vvp" +trace="$d/trace_w${W}_l${L}.log" | grep -E "HALT|TIMEOUT|TOHOST")
      if python3 "$HERE/compare.py" "$d/iss.json" "$d/trace_w${W}_l${L}.log" "$name W=$W wait=$L: $res"; then
        :
      else
        status=1
      fi
    done
  done
done
exit $status
