#!/bin/bash
set -eux
# This script expects the centos:7 intermediate image built from Containerfile.centos,
# which already has yum deps, libjpeg-turbo, and the linuxdeploy tools baked in.
OUT_DIR="/tmp/out"

TEMP_BASE=/tmp
BUILD_DIR="$(mktemp -d -p "$TEMP_BASE" appimage-build-XXXXXX)"

# make sure to clean up build dir, even if errors occur
cleanup() {
    if [[ -d "$BUILD_DIR" ]]; then
        rm -rf "$BUILD_DIR"
    fi
}
trap cleanup EXIT

cd "$BUILD_DIR"

# Compiler flags and parallelism — the intermediate image already provides the toolchain.
export CFLAGS="$(rpm --eval "%{optflags}")"
export CXXFLAGS="$CFLAGS"
export MAKEFLAGS="-j$(nproc)"
if [[ -d /usr/lib64/ccache ]]
then
    export PATH="/usr/lib64/ccache:$PATH"
elif [[ -d /usr/lib/ccache ]]
then
    export PATH="/usr/lib/ccache:$PATH"
fi

export pkgdir="$BUILD_DIR/AppDir"

# droidcam
# https://aur.archlinux.org/cgit/aur.git/tree/PKGBUILD?h=droidcam
echo "Building droidcam..."
(
    pkgbase=droidcam
    pkgname='droidcam'
    _name=droidcam-linux-client
    pkgver=2.1.5
    url="https://github.com/dev47apps/droidcam-linux-client"
    #makedepends=('alsa-lib' 'ffmpeg' 'gtk3' 'libappindicator-gtk3' 'libjpeg-turbo' 'libusbmuxd' 'speex')
    #depends=('alsa-lib' 'ffmpeg' 'glib2' 'glibc' 'gtk3' 'libappindicator-gtk3' 'libjpeg-turbo' 'libusbmuxd' 'libx11' 'pango' 'speex' 'V4L2LOOPBACK-MODULE')

    curl -sSLo "${pkgbase}-${pkgver}.tar.gz" "${url}/archive/refs/tags/v${pkgver}.tar.gz"
    echo "00ec96ec7a660e4e3ffb2adc536d14af89c635766dadbf53326c1216187021f8 ${pkgbase}-${pkgver}.tar.gz" > "${pkgbase}-${pkgver}.tar.gz.sha256"
    sha256sum -c "${pkgbase}-${pkgver}.tar.gz.sha256"

    tar -xf "${pkgbase}-${pkgver}.tar.gz"

    cd "${_name}-${pkgver}"
    patch -Np1 -i "$OUT_DIR/appimage-app-icon.patch"
    make JPEG_DIR="" JPEG_INCLUDE="" JPEG_LIB="" JPEG="$(pkg-config --libs --cflags libturbojpeg)" CFLAGS="$CFLAGS -std=gnu99"

    install -Dm755 "${pkgbase}" "$pkgdir/usr/bin/${pkgbase}"
    install -Dm755 "${pkgbase}-cli" "$pkgdir/usr/bin/${pkgbase}-cli"
    install -Dm644 icon2.png "${pkgdir}/usr/share/pixmaps/${pkgbase}.png"
    install -Dm644 "${pkgbase}.desktop" "${pkgdir}/usr/share/applications/${pkgbase}.desktop"

    strip -s "$pkgdir/usr/bin/droidcam-cli"
    sed -i -e 's/^\(TryExec=\).*$/\1droidcam/' -e 's/^\(Exec=\).*$/\1droidcam/' -e 's/^\(Icon=\).*$/\1droidcam/' "${pkgdir}/usr/share/applications/${pkgbase}.desktop"
)
echo "Building droidcam done."

mkdir -p AppDir
zstd -d -k -c "$OUT_DIR/v4l2loopback-dc.tar.zst" | tar -xf - -C AppDir

# linuxdeploy tooling is pre-installed under /opt/linuxdeploy by the intermediate image.
cp /opt/linuxdeploy/linuxdeploy-x86_64.AppImage .
cp /opt/linuxdeploy/linuxdeploy-plugin-appimage-x86_64.AppImage .
cp /opt/linuxdeploy/linuxdeploy-plugin-gtk.sh .
cp "$OUT_DIR/linuxdeploy-plugin-droidcam.sh" .

DROIDCAM_VERSION=2.1.5
KERNEL_VERSION="$(zstd -d -k -c "$OUT_DIR/v4l2loopback-dc.tar.zst" | tar -tf - | grep /v4l2loopback-dc\.ko | sed 's#^[./]*##' | sort -u | tail -n 1 | cut -d/ -f4)"

OUTPUT="DroidCam-${DROIDCAM_VERSION}-${KERNEL_VERSION}-x86_64_SteamDeck.AppImage" ./linuxdeploy-x86_64.AppImage --appdir AppDir \
    --executable AppDir/usr/bin/droidcam \
    --desktop-file AppDir/usr/share/applications/droidcam.desktop \
    --icon-file AppDir/usr/share/pixmaps/droidcam.png \
    --plugin gtk \
    --plugin droidcam \
    --output appimage

mv DroidCam*.AppImage "$OUT_DIR"
