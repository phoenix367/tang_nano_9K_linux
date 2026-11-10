#!/usr/bin/env bash
# Build a Linux image (toolchain, kernel 6.18 + initramfs, DTB) with Buildroot.
#
#   sw/build.sh                 # configure (first run) + full build
#   sw/build.sh linux-rebuild   # any Buildroot make target, e.g. busybox-menuconfig
#   CONFIG=mmu sw/build.sh      # stage 2 (S-mode kernel, SV32) instead of stage 1 (no-MMU)
#
# Buildroot is pinned to $BR_TAG and checked out under $WORK. Output goes to $WORK/br-tang9k
# (stage 1) or $WORK/br-tang9k-mmu, and the results are copied to $WORK/images-tang9k/
# {Image,tang9k.dtb} or $WORK/images-tang9k-mmu/{Image,tang9k-mmu.dtb}.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-/mnt/data/build/tang9k_linux}"
BR_TAG="${BR_TAG:-2026.08.1}"
BR="$WORK/buildroot"
case "${CONFIG:-nommu}" in
  nommu) DEFCONFIG=tang9k_nommu_defconfig OUT="$WORK/br-tang9k" IMAGES="$WORK/images-tang9k" DTB=tang9k.dtb ;;
  mmu)   DEFCONFIG=tang9k_mmu_defconfig OUT="$WORK/br-tang9k-mmu" IMAGES="$WORK/images-tang9k-mmu" DTB=tang9k-mmu.dtb ;;
  *)     echo "CONFIG must be nommu or mmu" >&2; exit 1 ;;
esac
EXT="$HERE/br2-external"

if [[ ! -d "$BR/.git" ]]; then
    git clone --depth 1 --branch "$BR_TAG" https://gitlab.com/buildroot.org/buildroot.git "$BR"
fi
have="$(git -C "$BR" describe --tags --exact-match 2>/dev/null || true)"
[[ "$have" == "$BR_TAG" ]] || { echo "$BR is at '$have', expected $BR_TAG" >&2; exit 1; }

# Always re-apply the defconfig so .config tracks the repo (packages are not rebuilt by this;
# use e.g. `sw/build.sh uclibc-dirclean` after changing what a built package depends on).
make -C "$BR" O="$OUT" BR2_EXTERNAL="$EXT" "$DEFCONFIG" > /dev/null

make -C "$BR" O="$OUT" "$@"

if [[ $# -eq 0 ]]; then
    mkdir -p "$IMAGES"
    cp "$OUT/images/Image" "$OUT/images/$DTB" "$IMAGES/"
    ls -la "$IMAGES"
fi
