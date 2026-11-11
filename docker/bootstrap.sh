#!/usr/bin/env bash
# Build the project's Docker build environment and configure docker/run.sh.
#
#   docker/bootstrap.sh [options]
#
# Options (all optional; defaults in brackets):
#   --gowin-path DIR   Gowin EDA install root on the host, the dir containing IDE/
#                      [$GOWIN_PATH, else /mnt/data/Gowin_V1.9.12.02_SP2_linux]. Not copied
#                      into the image: run.sh bind-mounts it read-only at /opt/gowin.
#   --work-dir DIR     host directory for the container's builds, $WORK inside it (Buildroot,
#                      its output, the kernel images) [/mnt/data/build/tang9k_linux/docker].
#                      Keep it apart from the host's own build directory: Buildroot's host
#                      tools are linked against the libc they were built with.
#   --dl-dir DIR       Buildroot download cache, BR2_DL_DIR inside [the host build's
#                      $WORK/buildroot/dl if it exists, else <work-dir>/dl]. Tarballs are
#                      portable, so sharing it saves the ~340 MB of downloads.
#   --tag NAME[:TAG]   image name [tang9k-linux-build:latest]
#   --uid N / --gid N  uid/gid of the container user (files in the mounted directories get
#                      this owner) [current user's]
#   --no-cache         rebuild every layer
#   --dry-run          print the docker build command and the run.sh settings, build nothing
#
# Writes docker/.env (read by run.sh) and builds the image from docker/Dockerfile with docker/
# as the build context (the Dockerfile copies nothing from the repository). The image is about
# 2 GB; Docker's data root needs that much free space.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

GOWIN="${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}"
HOST_WORK="${WORK:-/mnt/data/build/tang9k_linux}"
WORK_DIR="$HOST_WORK/docker"
DL_DIR=
TAG=tang9k-linux-build:latest
BUILD_UID=$(id -u)
BUILD_GID=$(id -g)
NO_CACHE=
DRY_RUN=0

while [ $# -gt 0 ]; do
	case "$1" in
	--gowin-path) GOWIN=$2; shift 2 ;;
	--work-dir) WORK_DIR=$2; shift 2 ;;
	--dl-dir) DL_DIR=$2; shift 2 ;;
	--tag) TAG=$2; shift 2 ;;
	--uid) BUILD_UID=$2; shift 2 ;;
	--gid) BUILD_GID=$2; shift 2 ;;
	--no-cache) NO_CACHE=--no-cache; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	-h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

if [ -z "$DL_DIR" ]; then
	if [ -d "$HOST_WORK/buildroot/dl" ]; then DL_DIR="$HOST_WORK/buildroot/dl"; else DL_DIR="$WORK_DIR/dl"; fi
fi
GOWIN=$(readlink -m "$GOWIN"); WORK_DIR=$(readlink -m "$WORK_DIR"); DL_DIR=$(readlink -m "$DL_DIR")
[ -x "$GOWIN/IDE/bin/gw_sh" ] || echo "warning: $GOWIN/IDE/bin/gw_sh not found; FPGA builds in the container will not work until --gowin-path points at a Gowin install" >&2
command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }

args=(build -f "$HERE/Dockerfile" -t "$TAG" $NO_CACHE
      --build-arg "BUILD_UID=$BUILD_UID" --build-arg "BUILD_GID=$BUILD_GID" "$HERE")

cat >"$HERE/.env" <<EOF
# written by docker/bootstrap.sh on $(date -I); read by docker/run.sh
IMAGE=$TAG
GOWIN_PATH=$GOWIN
WORK_DIR=$WORK_DIR
DL_DIR=$DL_DIR
EOF
echo ">> wrote $HERE/.env:"; sed 's/^/   /' "$HERE/.env"

if [ "$DRY_RUN" = 1 ]; then echo ">> docker ${args[*]}"; exit 0; fi

# Docker keeps the image under its data root; refuse early if that cannot hold it.
root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
free_kb=$(df -Pk "$root" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${free_kb:-}" ] && [ "$free_kb" -lt $((4*1024*1024)) ]; then
	echo "error: only $((free_kb/1024)) MB free under Docker's data root ($root); the image needs ~2 GB plus build scratch." >&2
	echo "       Move the data root (e.g. {\"data-root\": \"/mnt/data/docker\"} in /etc/docker/daemon.json, then restart docker) or free space." >&2
	exit 1
fi

mkdir -p "$WORK_DIR" "$DL_DIR"
echo ">> docker ${args[*]}"
docker "${args[@]}"
echo ">> image $TAG ready. Use docker/run.sh <command> (or docker/run.sh for a shell)."
