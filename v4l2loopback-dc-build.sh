#!/bin/bash
set -eux
# podman pull archlinux:latest
# podman run -v ./:/tmp/out --rm -ti archlinux:latest /tmp/out/v4l2loopback-dc-build.sh
# archlinux image
OUT_DIR="/tmp/out"
TMP_PKG_DIR="/tmp/v4l2loopback-dc"
repo_suffixes=('-staging' '-main' '-beta' '-rel' '-3.6' '-3.5' '-3.3.3' '-3.3.2' '-3.3.1' '-3.3' '-3.2' '-3.1' '-3.0' '')
_rs=("${repo_suffixes[@]:0:${#repo_suffixes[@]}-1}")
for s in "${_rs[@]}"
do
    repo_suffixes=("${repo_suffixes[@]:0:${#_rs[@]}+1}" "$s" "${repo_suffixes[@]:${#_rs[@]}+1}")
done
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

# Setup builduser and module directory
useradd -m builduser
mkdir -p /etc/sudoers.d
echo 'builduser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builduser
mkdir -p "$TMP_PKG_DIR"
tar -xf "$OUT_DIR/v4l2loopback-dc.tar.zst" -C "$TMP_PKG_DIR"
find "$TMP_PKG_DIR" -type f -name '*.xz' -exec unxz -f '{}' +
find "$TMP_PKG_DIR" -type f -name '*.gz' -exec gunzip -f '{}' +
find "$TMP_PKG_DIR" -type f -name '*.zst' -exec unzstd -f --rm '{}' +

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
pacman -Syy --noconfirm
# libverto is safe to pre-remove (pacman doesn't link to it). Skip cleanly if absent.
pacman -Qq libverto &>/dev/null && pacman -Rndd --noconfirm libverto || true
# libngtcp2 / libngtcp2-quictls / libngtcp2-crypto-ossl CANNOT be pre-removed: pacman's
# libcurl in current archlinux:latest hard-links to libngtcp2_crypto_ossl.so.0, so
# deleting the package breaks pacman immediately ("error while loading shared libraries").
# These packages also pull libssl.so=3 / libcrypto.so=3, which conflicts with the SteamOS
# openssl 1.1.x downgrade we're about to apply.
#
# Workaround: exclude them from the install set and use --assume-installed to satisfy the
# libssl.so / libcrypto.so virtual provides during the transaction. After the overwrite
# libcurl is replaced with the older SteamOS build that no longer depends on libngtcp2,
# so we can then remove the now-orphaned libngtcp2* packages safely.
mapfile -t _qqn < <(pacman -Qqn | grep -vE '^(libverto|libngtcp2|libngtcp2-quictls|libngtcp2-crypto-ossl)$')
pacman -S \
    --overwrite='*' \
    --assume-installed='libssl.so=3-64' \
    --assume-installed='libcrypto.so=3-64' \
    --noconfirm "${_qqn[@]}"
# Drop the orphaned libngtcp2* packages now that pacman is on the SteamOS libcurl.
for _p in libngtcp2 libngtcp2-quictls libngtcp2-crypto-ossl
do
    pacman -Qq "$_p" &>/dev/null && pacman -Rndd --noconfirm "$_p" || true
done
# The SteamOS snapshot of pacman.conf carries a DisableSandboxFilesystem directive that
# the older pacman binary we just downgraded to doesn't recognise. In rootless podman
# that combination makes pacman's Landlock setup fail with
# "could not apply the landlock ruleset", aborting every subsequent transaction.
# Strip the directive after the downgrade is in place.
sed -i -e '/^\s*DisableSandboxFilesystem\b/d' /etc/pacman.conf
pacman -S --noconfirm --needed base-devel git mkinitcpio sudo wget
rm -rf /usr/share/libalpm/hooks/*mkinitcpio*.hook || true
su -l -c '[ ! -d droidcam ] && git clone https://aur.archlinux.org/droidcam.git ; cd droidcam ; sed -i -e "s/^\(pkgname\s*=\).*$/\1v4l2loopback-dc-dkms/" -e "s/^\(makedepends\s*=\)/#\1/" -e "s/^\(build()\)/_\1/" PKGBUILD ; makepkg -cCfsi --noconfirm' builduser
for pkg in "${kernel_pkg_list[@]}"
do
    if ! pacman --noconfirm -U "${kernel_pkg_prefix}/${pkg}" "${kernel_pkg_prefix}/$(echo "${pkg}" | sed 's/\(-[0-9]\.\)/-headers\1/')"
    then
        continue
    fi
    kernel_targets=()
    readarray -t kernel_targets < <(pacman -Qsq linux-neptune | grep -v headers)
    my_break=0
    for kt in "${kernel_targets[@]}"
    do
        kf="$(pacman -Qlq "$kt" | grep '/usr/lib/modules/[^/]\+/' | head -n 1)"
        dkms_src="$(basename /usr/src/v4l2loopback-dc*)"
        if dkms install "${dkms_src%-*}/${dkms_src##*-}" -k "$(basename "$kf")"
        then
            tar -cf - "${kf}updates/dkms" | tar -xf - -C "$TMP_PKG_DIR"
            tar -cf - /etc/modules-load.d /etc/modprobe.d | tar -xf - -C "$TMP_PKG_DIR"
        else
            cat /var/lib/dkms/v4l2loopback-dc/*/build/make.log || true
            if grep -q -e 'incompatible gcc/plugin versions' -e 'cannot load plugin' /var/lib/dkms/v4l2loopback-dc/*/build/make.log
            then
                my_break=1
                break
            fi
        fi
    done
    if [[ "${my_break}" -eq 1 ]]
    then
        break
    fi
done

find "$TMP_PKG_DIR" -type f -name '*.xz' -exec unxz -f '{}' +
find "$TMP_PKG_DIR" -type f -name '*.gz' -exec gunzip -f '{}' +
find "$TMP_PKG_DIR" -type f -name '*.zst' -exec unzstd -f --rm '{}' +
# finally package the modules tar
tar -cf - --numeric-owner -C "$TMP_PKG_DIR" . | zstd -19 > "$OUT_DIR/v4l2loopback-dc.tar.zst"
