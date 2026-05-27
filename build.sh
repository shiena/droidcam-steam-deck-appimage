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

repo_suffixes=('-staging' '-main' '-beta' '-rel' '-3.6' '-3.5' '-3.3.3' '-3.3.2' '-3.3.1' '-3.3' '-3.2' '-3.1' '-3.0' '')
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
        --rm -ti "$ARCH_IMAGE" /tmp/out/v4l2loopback-dc-build.sh "$s"
done
{ set +x; } 2>/dev/null
set -x
podman run \
    --device=/dev/fuse --cap-add SYS_ADMIN \
    --tmpfs /tmp:exec \
    -v ./:/tmp/out \
    -v "${CCACHE_DIR}:/ccache" \
    -e CCACHE_DIR=/ccache \
    --rm -ti "$ALMALINUX_IMAGE" /tmp/out/droidcam-build.sh
{ set +x; } 2>/dev/null
