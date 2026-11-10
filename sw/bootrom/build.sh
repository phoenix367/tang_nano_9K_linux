#!/usr/bin/env bash
# Assemble the boot ROM into a $readmemh file for rtl/soc/bootrom.v (1024 words).
#   sw/bootrom/build.sh [out.hex]     (default: sw/bootrom/build/bootrom.hex)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="${RISCV_PREFIX:-/mnt/data/xilinx/2025.2/Vitis/gnu/riscv/lin/bin/riscv64-unknown-elf-}"
OUT="${1:-$HERE/build/bootrom.hex}"
B="$(dirname "$OUT")"
mkdir -p "$B"
"${TC}gcc" -march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles -Wl,--build-id=none \
    -Wl,-Ttext=0 -o "$B/bootrom.elf" "$HERE/bootrom.S"
"${TC}objcopy" -O binary "$B/bootrom.elf" "$B/bootrom.bin"
"${TC}objdump" -d "$B/bootrom.elf" > "$B/bootrom.dis"
python3 - "$B/bootrom.bin" "$OUT" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) <= 4096, "boot ROM larger than 4 KB"
data += bytes(4096 - len(data))
open(sys.argv[2], "w").write("\n".join(
    f"{int.from_bytes(data[i:i + 4], 'little'):08x}" for i in range(0, 4096, 4)) + "\n")
PY
echo "boot ROM: $(stat -c %s "$B/bootrom.bin") bytes -> $OUT"
