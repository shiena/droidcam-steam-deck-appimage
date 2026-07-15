#!/bin/bash
set -eux
# podman pull archlinux:latest
# podman run -v ./:/tmp/out --rm -ti archlinux:latest /tmp/out/v4l2loopback-build.sh
# archlinux image
# Builds the standard v4l2loopback kernel module (used by DroidCam OBS's Virtual Camera)
# for every available SteamOS kernel and appends the modules to v4l2loopback.tar.zst.
OUT_DIR="/tmp/out"
TMP_PKG_DIR="/tmp/v4l2loopback"
MODULE_TAR="$OUT_DIR/v4l2loopback.tar.zst"
KERNEL_PKG_CACHE="${KERNEL_PKG_CACHE:-/tmp/kernel-pkg-cache}"
mkdir -p "$KERNEL_PKG_CACHE"

# Build parallelism. ccache is wired later (after the SteamOS overwrite + pacman install).
export MAKEFLAGS="-j$(nproc)"

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
i=0
for s in "${repo_suffixes[@]}"
do
    if [[ "$s" == "${1:-}" ]]
    then
        break
    fi
    i=$((i+1))
done
if [[ "$i" -ge "${#repo_suffixes[@]}" ]]
then
    exit 1
fi
ret_code="$(curl -sSLIo /dev/null -w '%{http_code}' "https://steamdeck-packages.steamos.cloud/archlinux-mirror/jupiter${repo_suffixes[${i}]}/os/x86_64/jupiter${repo_suffixes[${i}]}.db")"
if [[ "$ret_code" != '200' ]]
then
    exit 0
fi

# Setup builduser and module directory (idempotent — the intermediate image may have pre-created the user)
id builduser &>/dev/null || useradd -m builduser
mkdir -p /etc/sudoers.d
echo 'builduser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builduser
mkdir -p "$TMP_PKG_DIR"
# Re-use modules from a previous run if the tar already exists; first run starts empty.
[[ -f "$MODULE_TAR" ]] && tar -xf "$MODULE_TAR" -C "$TMP_PKG_DIR"
find "$TMP_PKG_DIR" -type f -name '*.xz' -exec unxz -f '{}' +
find "$TMP_PKG_DIR" -type f -name '*.gz' -exec gunzip -f '{}' +
find "$TMP_PKG_DIR" -type f -name '*.zst' -exec unzstd -f --rm '{}' +

# Build list of kernel versions already present in the tar so we can skip rebuilding them later.
already_built=()
if [[ -d "$TMP_PKG_DIR/usr/lib/modules" ]]
then
    while IFS= read -r p
    do
        kver="$(echo "$p" | sed -E 's#^.*/usr/lib/modules/([^/]+)/.*#\1#')"
        already_built+=("$kver")
    done < <(find "$TMP_PKG_DIR/usr/lib/modules" -maxdepth 4 -name 'v4l2loopback.ko' 2>/dev/null || true)
fi

# Add SteamOS server and repos
echo 'Server = https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch' > /etc/pacman.d/mirrorlist
sed -i -e 's/\s*#\?\s*SigLevel\s*=\s*.*$/SigLevel = Never/g' -e '/^Include\s*=/d' /etc/pacman.conf
sed -i -e 's/^\[/[/;T;s/^\(\[options\]\)/\1/;t;d' /etc/pacman.conf
kernel_pkg_list=()
kernel_pkg_prefix=''
for repo in jupiter holo core extra community
do
    for s in "${repo_suffixes[@]:i}"
    do
        ret_code="$(curl -sSLIo /dev/null -w '%{http_code}' "https://steamdeck-packages.steamos.cloud/archlinux-mirror/${repo}${s}/os/x86_64/${repo}${s}.db")"
        if [[ "$ret_code" == '200' ]]
        then
            echo -e "\n\n[${repo}${s}]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
            if [[ "$repo" == 'jupiter' ]]
            then
                kernel_pkg_prefix="https://steamdeck-packages.steamos.cloud/archlinux-mirror/${repo}${s}/os/x86_64"
                readarray -t kernel_pkg_list < <(curl -sSL "https://steamdeck-packages.steamos.cloud/archlinux-mirror/${repo}${s}/os/x86_64/" | grep -oP 'href="\Klinux-neptune[^"]*' | grep -v -e '\.sig$' -e '-headers-' -e '-debug-' -e '-wip-' | sort -rV)
            fi
            break
        fi
    done
done
# Drop leftovers from any prior interrupted download in the shared cache volume.
find /var/cache/pacman/pkg -maxdepth 1 \( -name '*.part' -o -size 0 \) -delete 2>/dev/null || true

# pacman wrapper that retries after deleting cache files reported as corrupted.
# Required because the shared cache volume can hold stale or partial pkg files from a previous
# iteration / repo snapshot, and pacman --noconfirm does not auto-delete-and-retry those.
pacman_retry() {
    local err_log rc victims attempt
    err_log="$(mktemp)"
    for attempt in 1 2 3
    do
        rc=0
        # Capture combined stdout+stderr: pacman emits ":: File X is corrupted" on stdout,
        # while the final "error: failed to commit transaction" appears on stderr.
        # The pipe ensures tee has flushed err_log by the time we read it.
        pacman "$@" 2>&1 | tee "$err_log"
        rc=${PIPESTATUS[0]}
        if [[ $rc -eq 0 ]]
        then
            rm -f "$err_log"
            return 0
        fi
        victims="$(grep -oE '/var/cache/pacman/pkg/[^ ]+\.pkg\.tar\.[a-z]+' "$err_log" | sort -u || true)"
        if [[ -z "$victims" ]]
        then
            rm -f "$err_log"
            return 1
        fi
        echo "$victims" | xargs -r rm -f
        : > "$err_log"
    done
    rm -f "$err_log"
    return 1
}

pacman -Syy --noconfirm
# libverto is safe to pre-remove (pacman doesn't link to it).
pacman -Qq libverto &>/dev/null && pacman -Rndd --noconfirm libverto || true
# libngtcp2 / libngtcp2-quictls / libngtcp2-crypto-ossl CANNOT be pre-removed: pacman's libcurl
# in current archlinux:latest hard-links to libngtcp2_crypto_ossl.so.0, so deleting the package
# breaks pacman immediately ("error while loading shared libraries").
#
# Instead, exclude them from the install set and use --assume-installed to satisfy their
# libssl.so=3 / libcrypto.so=3 dep against SteamOS's openssl 1.1.x. After the transaction
# libcurl is replaced with the older SteamOS build that doesn't depend on libngtcp2,
# so subsequent pacman calls succeed even though libngtcp2 itself remains broken on disk.
mapfile -t _qqn < <(pacman -Qqn | grep -vE '^(libverto|libngtcp2|libngtcp2-quictls|libngtcp2-crypto-ossl)$')
pacman_retry -S \
    --overwrite='*' \
    --assume-installed='libssl.so=3-64' \
    --assume-installed='libcrypto.so=3-64' \
    --noconfirm "${_qqn[@]}"
# Optional cleanup: once the SteamOS libcurl is in place, libngtcp2* are inert junk we can drop.
for _p in libngtcp2 libngtcp2-quictls libngtcp2-crypto-ossl
do
    pacman -Qq "$_p" &>/dev/null && pacman -Rndd --noconfirm "$_p" || true
done
sed -i -e '/^\s*DisableSandboxFilesystem\b/d' /etc/pacman.conf
pacman_retry -S --noconfirm --needed base-devel git mkinitcpio sudo wget
# ccache is optional — older SteamOS snapshots may not ship it. Fall back silently.
pacman_retry -S --noconfirm --needed ccache || true
rm -rf /usr/share/libalpm/hooks/*mkinitcpio*.hook || true
# Wire ccache for DKMS gcc invocations (no-op when ccache wasn't installed).
if [[ -d /usr/lib/ccache/bin ]]
then
    export PATH="/usr/lib/ccache/bin:$PATH"
fi
if [[ -d /ccache ]]
then
    chown -R builduser:builduser /ccache 2>/dev/null || true
fi
# Provide the standard v4l2loopback DKMS source under /usr/src so the per-kernel dkms loop can
# build it. We pin a known-good upstream release instead of the SteamOS/Arch 'extra' mirror's
# v4l2loopback-dkms package: that mirror ships a stale 0.15.0 which fails to build against the
# 6.16/6.18 SteamOS kernels. Two API breaks hit 0.15.0 there:
#   - v4l2_fh_add()/v4l2_fh_del() gained a 'struct file *' argument in 6.18 (too few arguments).
#   - 'from_timer' was dropped in 6.16, so 0.15.0's '#if defined(timer_setup) && defined(from_timer)'
#     detection turns off HAVE_TIMER_SETUP and falls back to the long-removed setup_timer().
# 0.15.4 fixes both while keeping backward-compat for the older kernels, so it builds every
# SteamOS kernel we target. dkms itself used to arrive as a dependency of the v4l2loopback-dkms
# package; install it explicitly now that we no longer pull that package.
V4L2LOOPBACK_TAG='v0.15.4'
pacman_retry -S --noconfirm --needed dkms
rm -rf /tmp/v4l2loopback-src
git clone --depth 1 --branch "$V4L2LOOPBACK_TAG" https://github.com/umlaeute/v4l2loopback /tmp/v4l2loopback-src
# dkms reads name/version from the bundled dkms.conf and copies the tree into /usr/src.
dkms add /tmp/v4l2loopback-src
# Register the source with dkms (idempotent — already added by the line above).
dkms_src="$(basename /usr/src/v4l2loopback-*)"
dkms add "${dkms_src%-*}/${dkms_src##*-}" 2>/dev/null || true

# Helper: download a kernel pkg via the host-mounted cache (no-op if cached) and return the local path on stdout.
fetch_kernel_pkg() {
    local fname="$1"
    local dest="${KERNEL_PKG_CACHE}/${fname}"
    if [[ ! -s "$dest" ]]
    then
        curl -sSLfo "$dest.part" "${kernel_pkg_prefix}/${fname}" && mv "$dest.part" "$dest"
    fi
    echo "$dest"
}

# Print the module version (the /usr/lib/modules/<kver> dir name) recorded inside a kernel
# package WITHOUT installing it, so already-built kernels can be skipped before the costly
# pacman -U + dkms build.
pkg_kver() {
    pacman -Qlp "$1" 2>/dev/null | grep -oP '/usr/lib/modules/\K[^/]+' | head -n1
}

is_already_built() {
    local k="$1" b
    for b in "${already_built[@]}"
    do
        [[ "$b" == "$k" ]] && return 0
    done
    return 1
}

for pkg in "${kernel_pkg_list[@]}"
do
    pkg_local="$(fetch_kernel_pkg "${pkg}")" || continue
    # Resolve the kernel module version from the (cached) package up front so already-built
    # kernels are skipped without re-downloading headers, re-installing the kernel, or rebuilding.
    kver="$(pkg_kver "$pkg_local")"
    if [[ -n "$kver" ]] && is_already_built "$kver"
    then
        echo "Skipping already-built kernel module: $kver"
        continue
    fi
    headers_pkg="$(echo "${pkg}" | sed 's/\(-[0-9]\.\)/-headers\1/')"
    headers_local="$(fetch_kernel_pkg "${headers_pkg}")" || continue
    if ! pacman --noconfirm -U "${pkg_local}" "${headers_local}"
    then
        continue
    fi
    # Fall back to scanning the freshly installed kernel if the package file list was unreadable.
    if [[ -z "$kver" ]]
    then
        kt="$(pacman -Qsq linux-neptune | grep -v headers | tail -n1)"
        kf="$(pacman -Qlq "$kt" | grep '/usr/lib/modules/[^/]\+/' | head -n 1)"
        kver="$(basename "$kf")"
        is_already_built "$kver" && continue
    fi
    if MAKEFLAGS="$MAKEFLAGS" dkms install "${dkms_src%-*}/${dkms_src##*-}" -k "$kver"
    then
        tar -cf - "/usr/lib/modules/${kver}/updates/dkms" | tar -xf - -C "$TMP_PKG_DIR"
        tar -cf - /etc/modules-load.d /etc/modprobe.d | tar -xf - -C "$TMP_PKG_DIR" 2>/dev/null || true
        already_built+=("$kver")
    else
        cat /var/lib/dkms/v4l2loopback/*/build/make.log || true
        if grep -q -e 'incompatible gcc/plugin versions' -e 'cannot load plugin' /var/lib/dkms/v4l2loopback/*/build/make.log
        then
            break
        fi
    fi
done

find "$TMP_PKG_DIR" -type f -name '*.xz' -exec unxz -f '{}' +
find "$TMP_PKG_DIR" -type f -name '*.gz' -exec gunzip -f '{}' +
find "$TMP_PKG_DIR" -type f -name '*.zst' -exec unzstd -f --rm '{}' +
# finally package the modules tar
tar -cf - --numeric-owner -C "$TMP_PKG_DIR" . | zstd -19 > "$MODULE_TAR"
