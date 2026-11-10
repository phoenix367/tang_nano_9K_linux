#!/usr/bin/env bash
# Build the stage-1 Linux image (toolchain, kernel 6.18 + initramfs, DTB) with Buildroot.
#
#   sw/build.sh                 # configure (first run) + full build
#   sw/build.sh linux-rebuild   # any Buildroot make target, e.g. busybox-menuconfig
#
# Buildroot is pinned to $BR_TAG and checked out under $WORK; output goes to $WORK/br-tang9k.
# Results are copied to $WORK/images-tang9k/{Image,tang9k.dtb}.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-/mnt/data/build/tang9k_linux}"
BR_TAG="${BR_TAG:-2026.08.1}"
BR="$WORK/buildroot"
OUT="$WORK/br-tang9k"
EXT="$HERE/br2-external"

if [[ ! -d "$BR/.git" ]]; then
    git clone --depth 1 --branch "$BR_TAG" https://gitlab.com/buildroot.org/buildroot.git "$BR"
fi
have="$(git -C "$BR" describe --tags --exact-match 2>/dev/null || true)"
[[ "$have" == "$BR_TAG" ]] || { echo "$BR is at '$have', expected $BR_TAG" >&2; exit 1; }

# Always re-apply the defconfig so .config tracks the repo (packages are not rebuilt by this;
# use e.g. `sw/build.sh uclibc-dirclean` after changing what a built package depends on).
make -C "$BR" O="$OUT" BR2_EXTERNAL="$EXT" tang9k_nommu_defconfig > /dev/null

make -C "$BR" O="$OUT" "$@"

if [[ $# -eq 0 ]]; then
    mkdir -p "$WORK/images-tang9k"
    cp "$OUT/images/Image" "$OUT/images/tang9k.dtb" "$WORK/images-tang9k/"
    ls -la "$WORK/images-tang9k"
fi
