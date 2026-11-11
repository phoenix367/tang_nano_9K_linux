#!/usr/bin/env bash
# Bare-metal SoC tests (sw/tests/*.S): each becomes <name>.bin, a raw image for 0x80000000
# that the boot ROM starts like a kernel.
#   sw/tests/build.sh [out_dir]          default: /mnt/data/build/tang9k_linux/tests
# Run one in the SoC simulation (stage-2 CPU, ROM 'b' = M-mode) or on the board:
#   IMAGE=<out>/cbo_test.bin CONFIG=mmu ROM_CMD=b sim/soc/run.sh
#   sw/tools/qerv_boot.py --bitstream <fs> --load <out>/cbo_test.bin@0x80000000 --boot --console
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/mnt/data/build/tang9k_linux/tests}"
TC="${RISCV_PREFIX:-/mnt/data/xilinx/2025.2/Vitis/gnu/riscv/lin/bin/riscv64-unknown-elf-}"
mkdir -p "$OUT"
for src in "$HERE"/*.S; do
  n=$(basename "$src" .S)
  "${TC}gcc" -march=rv32ima_zicsr -mabi=ilp32 -nostdlib -nostartfiles -Wl,--build-id=none \
      -Wl,-Ttext=0x80000000 "$src" -o "$OUT/$n.elf"
  "${TC}objcopy" -O binary "$OUT/$n.elf" "$OUT/$n.bin"
  "${TC}objdump" -d "$OUT/$n.elf" > "$OUT/$n.dis"
  echo "$OUT/$n.bin ($(stat -c %s "$OUT/$n.bin") bytes)"
done
