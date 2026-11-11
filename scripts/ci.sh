#!/usr/bin/env bash
# Checks that need no FPGA tools, no board and no Buildroot build. The GitHub workflow
# (.github/workflows/ci.yml) runs them; they run the same way on a workstation.
#
#   scripts/ci.sh cpu     the CPU: directed tests in lockstep with verif/qerv/iss.py,
#                         riscv-tests on the stage-1 and stage-2 cores (W=4 and W=1),
#                         per-class cycle costs against perf/serv_cpi's ISS
#   scripts/ci.sh units   unit benches: cache + arbiter, PSRAM model, UART, I2C, SPI,
#                         video scan-out under CPU load
#   scripts/ci.sh soc     the Verilator SoC: boot ROM commands, then the bare-metal
#                         cache-block test (sw/tests/cbo_test.S) on the stage-2 CPU
#   scripts/ci.sh all     all three
#
# Not covered: verif/video/run.sh (needs Gowin's primitive models), the Gowin build and
# timing, the kernel and the board.
#
# Needs: iverilog, verilator, python3, a bare-metal RISC-V GCC. Env:
#   RISCV_PREFIX  default riscv64-unknown-elf- (the distribution's package on the PATH)
#   WORK          scratch directory for the SoC model and test images (default: a new
#                 temporary directory)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
export RISCV_PREFIX="${RISCV_PREFIX:-riscv64-unknown-elf-}"
export WORK="${WORK:-$(mktemp -d)}"
mkdir -p "$WORK"

step() { echo; echo "=== $*"; }

cpu() {
  step "CPU directed tests (lockstep with iss.py)"
  verif/qerv/run_directed.sh
  step "riscv-tests, stage-1 core"
  verif/qerv/run_riscv_tests.sh
  step "riscv-tests, stage-2 core (S-mode)"
  SMODE=1 verif/qerv/run_riscv_tests.sh
  step "cycle costs (perf/serv_cpi)"
  perf/serv_cpi/run.sh
}

units() {
  step "cache + PSRAM arbiter"
  verif/cache/run.sh
  step "PSRAM model"
  verif/psram/run.sh
  step "UART"
  verif/uart/run.sh
  step "I2C"
  verif/i2c/run.sh
  step "SPI master"
  verif/spi/run.sh
  step "video scan-out under CPU load"
  verif/video/run_sys.sh
}

soc() {
  # sim/soc/run.sh always preloads a kernel Image and DTB from $WORK/images-*. These tests
  # boot neither, so empty placeholders keep the model from reporting missing files.
  local d
  for d in images-tang9k images-tang9k-mmu; do mkdir -p "$WORK/$d"; done
  touch "$WORK/images-tang9k/Image" "$WORK/images-tang9k/tang9k.dtb" \
        "$WORK/images-tang9k-mmu/Image" "$WORK/images-tang9k-mmu/tang9k-mmu.dtb"

  step "boot ROM commands on the SoC model (sim/soc/test_bootrom.py)"
  python3 sim/soc/test_bootrom.py

  step "cache-block operations on the SoC model (sw/tests/cbo_test.S, stage-2 CPU)"
  sw/tests/build.sh "$WORK/tests"
  local log="$WORK/cbo_test.uart.log"
  IMAGE="$WORK/tests/cbo_test.bin" CONFIG=mmu ROM_CMD=b QUIET=1 MAX_CYCLES=20000000 \
    UART_LOG="$log" sim/soc/run.sh
  cat "$log"
  grep -q "cbo test: PASS" "$log"
}

case "${1:-all}" in
  cpu)   cpu ;;
  units) units ;;
  soc)   soc ;;
  all)   cpu; units; soc ;;
  *)     echo "usage: $0 [cpu|units|soc|all]" >&2; exit 1 ;;
esac
echo; echo "=== ${1:-all}: PASS"
