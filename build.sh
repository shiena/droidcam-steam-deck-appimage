#!/bin/bash
set -eux

# Local image tags for the pre-baked intermediate images (see Containerfile.*).
ARCH_IMAGE='droidcam-build/archlinux:local'
ALMALINUX_IMAGE='droidcam-build/almalinux:local'

# Host cache directories — created if missing so podman bind-mounts succeed.
CACHE_DIR="$(pwd)/.cache"
PACMAN_PKG_CACHE="${CACHE_DIR}/pacman-pkg"
KERNEL_PKG_CACHE="${CACHE_DIR}/kernel-pkg"
CCACHE_DIR="${CACHE_DIR}/ccache"
mkdir -p "$PACMAN_PKG_CACHE" "$KERNEL_PKG_CACHE" "$CCACHE_DIR"

# Build (or rebuild) the intermediate images. podman caches layers so re-runs are cheap.
{ set +x; } 2>/dev/null
set -x
podman build -t "$ARCH_IMAGE" -f Containerfile.archlinux .
podman build -t "$ALMALINUX_IMAGE" -f Containerfile.almalinux .

# Released SteamOS snapshots only — dev/preview rolling channels (-staging/-main) ship kernels
# that never reach a release, and their snapshot drifts on every build, so their modules go stale
# and aren't used by released devices. The kept suffixes are NOT strict supersets of each other,
# so all are built and the already-built dedup collapses the overlap:
#   '-3.8.1x' newest released snapshot; sole source of the latest 6.16 point releases
#             (e.g. linux-neptune-616 6.16.12.valve24.4, absent from '-3.8').
#   '-3.8'    prior release; sole source of the -1.1 pkgrel rebuilds of the 6.11/6.16/6.18
#             kernels (e.g. 6.11.11.valve29-1.1, 6.18.33.valve2-1.1) absent from '-3.8.1x'.
#   '-3.7'    older release kept as overlap/resilience (mostly skipped via already-built dedup).
# Maintenance: when a newer SteamOS ships a new kernel, prepend its snapshot suffix here.
repo_suffixes=('-3.8.1x' '-3.8' '-3.7')
total="${#repo_suffixes[@]}"
i=0
for s in "${repo_suffixes[@]}"
do
    i=$((i+1))
    { set +x; } 2>/dev/null
    set -x
    podman run \
        -v ./:/tmp/out \
        -v "${PACMAN_PKG_CACHE}:/var/cache/pacman/pkg" \
        -v "${KERNEL_PKG_CACHE}:/tmp/kernel-pkg-cache" \
        -v "${CCACHE_DIR}:/ccache" \
        --tmpfs /tmp/build:exec \
        -e CCACHE_DIR=/ccache \
        --rm -ti "$ARCH_IMAGE" /tmp/out/v4l2loopback-build.sh "$s"
done
{ set +x; } 2>/dev/null
set -x
podman run \
    --device=/dev/fuse --cap-add SYS_ADMIN \
    --tmpfs /tmp:exec \
    -v ./:/tmp/out \
    -v "${CCACHE_DIR}:/ccache" \
    -e CCACHE_DIR=/ccache \
    --rm -ti "$ALMALINUX_IMAGE" /tmp/out/obs-build.sh
{ set +x; } 2>/dev/null
