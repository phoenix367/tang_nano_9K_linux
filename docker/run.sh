#!/usr/bin/env bash
# Run a command (default: an interactive shell) in the build image. Mounts:
#   the repository                 at /work   (the working directory)
#   WORK_DIR, the build directory  at /build  ($WORK in the container: Buildroot, its output,
#                                              the kernel images, the SoC model)
#   DL_DIR, Buildroot's downloads  at /dl     (BR2_DL_DIR; can be the host build's cache)
#   GOWIN_PATH, the Gowin install  at /opt/gowin, read-only
# Settings come from docker/.env, written by docker/bootstrap.sh; IMAGE, GOWIN_PATH, WORK_DIR
# and DL_DIR in the environment override them.
#
#   docker/run.sh                                     # shell
#   docker/run.sh env CONFIG=mmu sw/build.sh          # MMU kernel + DTB -> WORK_DIR/images-tang9k-mmu
#   docker/run.sh env SMODE=1 VIDEO=1 fpga/build.sh   # bitstream (needs the licence server)
#   docker/run.sh scripts/ci.sh all                   # the CI checks
#   docker/run.sh sw/tools/flash_linux.sh mmu         # write the SPI flash (board on USB)
#
# WORK_DIR is a directory of its own, not the host's build directory: Buildroot's host tools
# are linked against the libc they were built with, so trees built on the host and in the
# container must not mix.
#
# USB (openFPGALoader, programmer_cli) and the console UARTs present at start are passed
# through; the container runs as the uid/gid chosen at bootstrap, so the host's udev rules must
# already give that user the devices (it is in dialout and plugdev).
set -euo pipefail

case "${1:-}" in
-h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-; exit 0 ;;
esac

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
[ -f "$HERE/.env" ] && { set -a; . "$HERE/.env"; set +a; }
IMAGE=${IMAGE:-tang9k-linux-build:latest}
GOWIN_PATH=${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}
WORK_DIR=${WORK_DIR:-/mnt/data/build/tang9k_linux/docker}
DL_DIR=${DL_DIR:-$WORK_DIR/dl}

mkdir -p "$WORK_DIR" "$DL_DIR"
opts=(--rm -v "$REPO:/work" -v "$WORK_DIR:/build" -v "$DL_DIR:/dl" -e BR2_DL_DIR=/dl
      -w /work -e TERM="${TERM:-xterm}")
[ -t 0 ] && [ -t 1 ] && opts+=(-it)
[ -d "$GOWIN_PATH/IDE" ] && opts+=(-v "$GOWIN_PATH:/opt/gowin:ro")
[ -d /dev/bus/usb ] && opts+=(--device /dev/bus/usb)
for t in /dev/ttyUSB* /dev/ttyACM*; do [ -e "$t" ] && opts+=(--device "$t"); done
# git inside the container (sw/build.sh checks the Buildroot tag, the scripts find the repo):
# the mounted trees belong to the same uid, but git still wants the paths whitelisted
opts+=(-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*')

exec docker run "${opts[@]}" "$IMAGE" "$@"
