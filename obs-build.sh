#!/bin/bash
set -eux
# This script expects the almalinux:8 intermediate image built from Containerfile.almalinux,
# which already has the OBS build dependencies and the linuxdeploy tools baked in.
#
# It builds the DroidCam OBS client (a slim OBS Studio 27.2 fork) in the "portable" layout
# (UNIX_STRUCTURE=0), which is relocatable by design: the binary resolves its plugins/data via
# CWD-relative paths ("../../obs-plugins/64bit", "../../data"), so launching with CWD=bin/64bit
# makes the whole tree work from anywhere inside the AppImage mount.
OUT_DIR="/tmp/out"

# Upstream source. The tag looks like "droidcam-7.2.1"; OBS_VERSION is the bare "7.2.1".
OBS_REPO="https://github.com/dev47apps/droidcam-obs-client"
OBS_TAG="droidcam-7.2.1"
OBS_VERSION="${OBS_TAG#droidcam-}"

# The droidcam_obs *source* (the thing that connects to the phone) lives in a separate GPLv2 repo,
# NOT in the client repo. We build it with DROIDCAM_OVERRIDE so it pairs with the override UI client
# above: only then does it register the droidcam_obs source + the droidcam_connect/disconnect
# signals + the custom Add-Device dialog the client's UI drives. Tag tracks the same product release.
DROIDCAM_PLUGIN_REPO="https://github.com/dev47apps/droidcam-obs-plugin"
DROIDCAM_PLUGIN_TAG="2.5.0"

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
export CMAKE_BUILD_PARALLEL_LEVEL="$(nproc)"
if [[ -d /usr/lib64/ccache ]]
then
    export PATH="/usr/lib64/ccache:$PATH"
elif [[ -d /usr/lib/ccache ]]
then
    export PATH="/usr/lib/ccache:$PATH"
fi

APPDIR="$BUILD_DIR/AppDir"
INSTALL_PREFIX="$APPDIR/usr"

echo "Fetching DroidCam OBS client ${OBS_TAG}..."
# No submodules needed: browser/CEF is disabled and FTL auto-disables without its submodule.
git clone --depth 1 --branch "$OBS_TAG" "$OBS_REPO" src
SRC="$BUILD_DIR/src"

# Upstream's stats (ClientOpen telemetry) payload only implements the _WIN32 branch; the __linux__
# branch is a hard '#error "Linux"' that fails the compile. Provide a minimal valid Linux entry so
# the object initializer builds. (The runtime guard at line ~317 still gates whether anything is
# actually sent — this only unblocks compilation, matching the Windows code path's shape.)
sed -i 's|#error "Linux"|{"$os", "Linux"},|' "$SRC/UI/window-basic-droidcam-overrides.cpp"

# Give the DROIDCAM_OVERRIDE client a working virtual camera on Linux. Out of the box the override
# build has none: it never sets vcamEnabled, it requests the Windows-only "droidcam_virtual_output",
# and its slim plugin set (CMakeLists return()s early) skips linux-v4l2. So:
#   1. Build linux-v4l2 (registers the standard "virtualcam_output" that writes to v4l2loopback).
#   2. Repoint the override client's output id from droidcam_virtual_output -> virtualcam_output.
#   3. Force vcamEnabled = true so the virtualCam output is actually created (and the button added,
#      which also avoids a null vcamButton deref if StartVirtualCam ever fails).
sed -i 's@\(\tadd_subdirectory(obs-transitions)\)@\1\n\tif("${CMAKE_SYSTEM_NAME}" MATCHES "Linux")\n\t\tadd_subdirectory(linux-v4l2)\n\tendif()@' "$SRC/plugins/CMakeLists.txt"
sed -i 's|droidcam_virtual_output|virtualcam_output|g' "$SRC/UI/window-basic-main-outputs.cpp"
sed -i 's|vcamEnabled = obs_data_get_bool(obsData, "vcamEnabled");|vcamEnabled = true;|' "$SRC/UI/window-basic-main.cpp"

# Fix a crash when opening File > Settings: on non-Windows the settings ctor deletes and nulls
# ui->hideOBSFromCapture (a Windows-only "hide OBS from capture" checkbox), but the override block
# later calls ui->hideOBSFromCapture->setToolTip() with no null guard (the surrounding HIDE_ITEM
# lines are guarded; this one isn't). Add the missing guard.
sed -i 's|ui->hideOBSFromCapture->setToolTip(QString());|if (ui->hideOBSFromCapture) ui->hideOBSFromCapture->setToolTip(QString());|' "$SRC/UI/window-basic-settings.cpp"

# The override layout hides the Controls dock, so the auto-added Start Virtual Camera button is
# never visible. Add a checkable "Virtual Camera" entry to the (visible) View menu that toggles it
# via the existing VCamButtonClicked slot, so the camera can be started without the --startvirtualcam
# arg. Mirror the hidden vcamButton's checked state (kept in sync by OnVirtualCamStart/Stop) onto the
# menu item so its checkmark reflects whether the camera is running.
sed -i 's|\t\tSLOT(on_resetUI_triggered()));|&\n\tQAction *vcamAction = ui->viewMenu->addAction(QStringLiteral("Virtual Camera"), this, \&OBSBasic::VCamButtonClicked);\n\tvcamAction->setCheckable(true);\n\tif (vcamButton)\n\t\tconnect(vcamButton.data(), \&QAbstractButton::toggled, vcamAction, \&QAction::setChecked);|' "$SRC/UI/window-basic-main.cpp"

echo "Building DroidCam OBS client..."
cmake -GNinja -S "$SRC" -B "$BUILD_DIR/build" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DUNIX_STRUCTURE=0 \
    -DDROIDCAM_OVERRIDE=ON \
    -DENABLE_V4L2=ON \
    -DBUILD_BROWSER=OFF \
    -DBUILD_VST=OFF \
    -DENABLE_SCRIPTING=OFF \
    -DENABLE_PIPEWIRE=OFF \
    -DENABLE_WAYLAND=OFF
cmake --build "$BUILD_DIR/build"
cmake --install "$BUILD_DIR/build"
echo "Building DroidCam OBS client done."

echo "Building DroidCam OBS source plugin ${DROIDCAM_PLUGIN_TAG}..."
git clone --depth 1 --branch "$DROIDCAM_PLUGIN_TAG" "$DROIDCAM_PLUGIN_REPO" droidcam-obs-plugin
PLUGIN_SRC="$BUILD_DIR/droidcam-obs-plugin"
mkdir -p "$PLUGIN_SRC/build"
# The plugin links against libobs/obs-frontend-api symbols (resolved at runtime from the OBS process,
# so undefined-at-link is fine for a -shared object) and needs their headers + the generated
# obsconfig.h plus ffmpeg/Qt5. Inject the OBS source/build include dirs via CPLUS_INCLUDE_PATH so we
# don't have to fight the plugin Makefile's own INCLUDES, and point the linker at the just-built
# libobs.so for its -lobs.
(
    export CPLUS_INCLUDE_PATH="$SRC/libobs:$SRC/UI/obs-frontend-api:$BUILD_DIR/build/config:/usr/include/ffmpeg${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"
    export LIBRARY_PATH="$APPDIR/usr/bin/64bit${LIBRARY_PATH:+:$LIBRARY_PATH}"
    make -C "$PLUGIN_SRC" \
        DROIDCAM_OVERRIDE=1 \
        LIBIMOBILEDEV=libimobiledevice-1.0 \
        MOC=/usr/lib64/qt5/bin/moc \
        UIC=/usr/lib64/qt5/bin/uic \
        CXX="${CXX:-g++}"
)
# Install into the portable tree exactly like a normal OBS plugin: <plugin>.so under
# usr/obs-plugins/64bit, data under usr/data/obs-plugins/droidcam-obs (see the upstream zip layout).
cp "$PLUGIN_SRC/build/droidcam-obs.so" "$APPDIR/usr/obs-plugins/64bit/"
mkdir -p "$APPDIR/usr/data/obs-plugins/droidcam-obs"
cp -R "$PLUGIN_SRC"/data/* "$APPDIR/usr/data/obs-plugins/droidcam-obs/"
echo "Building DroidCam OBS source plugin done."

# Bundle the v4l2loopback kernel modules built in stage 1 (provides usr/lib/modules/<kver>/...).
zstd -d -k -c "$OUT_DIR/v4l2loopback.tar.zst" | tar -xf - -C "$APPDIR"

# Launcher placed at usr/bin/droidcam (the desktop file's Exec target). It sets CWD to the
# portable tree's bin/64bit so OBS's relative plugin/data lookups resolve, then execs the real
# binary. LD_LIBRARY_PATH is exported by the apprun-hook from linuxdeploy-plugin-obs.sh.
# (Extra args pass through, so the virtual camera can be auto-started on demand with
# `<AppImage> --startvirtualcam`; it's intentionally not forced on by default.)
mkdir -p "$INSTALL_PREFIX/bin"
cat > "$INSTALL_PREFIX/bin/droidcam" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
cd "$HERE/64bit" || exit 1
exec ./droidcam "$@"
EOF
chmod +x "$INSTALL_PREFIX/bin/droidcam"

# Desktop entry (AppImage-relative Exec/Icon).
mkdir -p "$INSTALL_PREFIX/share/applications"
cat > "$INSTALL_PREFIX/share/applications/droidcam.desktop" <<'EOF'
[Desktop Entry]
Name=DroidCam Client (OBS)
Comment=Use your phone as a webcam
Exec=droidcam
Icon=droidcam
Terminal=false
Type=Application
Categories=AudioVideo;Video;
EOF

# linuxdeploy tooling is pre-installed under /opt/linuxdeploy by the intermediate image.
# linuxdeploy discovers plugins located alongside its own binary, so copy everything here.
cp /opt/linuxdeploy/linuxdeploy-x86_64.AppImage .
cp /opt/linuxdeploy/linuxdeploy-plugin-appimage-x86_64.AppImage .
cp /opt/linuxdeploy/linuxdeploy-plugin-qt-x86_64.AppImage .
cp "$OUT_DIR/linuxdeploy-plugin-obs.sh" .
chmod +x linuxdeploy-plugin-obs.sh

# Tell the Qt plugin which qmake to use (EL8 ships it as qmake-qt5).
export QMAKE=/usr/bin/qmake-qt5

# Gather external dependencies (Qt5, ffmpeg, x264, ...) for the real ELF binary, libobs, and
# every plugin, WITHOUT relocating them out of the portable tree (--deploy-deps-only). The
# resolved libraries land in usr/lib; the apprun-hook adds usr/lib + usr/bin/64bit to the path.
deps_args=(--deploy-deps-only "$APPDIR/usr/bin/64bit/droidcam")
for so in "$APPDIR"/usr/bin/64bit/*.so "$APPDIR"/usr/obs-plugins/64bit/*.so
do
    [[ -e "$so" ]] && deps_args+=(--deploy-deps-only "$so")
done

KERNEL_VERSION="$(zstd -d -k -c "$OUT_DIR/v4l2loopback.tar.zst" | tar -tf - | grep '/v4l2loopback\.ko' | sed 's#^[./]*##' | sort -u | tail -n 1 | cut -d/ -f4)"
OUTPUT_NAME="DroidCam-OBS-${OBS_VERSION}-${KERNEL_VERSION}-x86_64_SteamDeck.AppImage"

# OBS plugins under usr/obs-plugins/64bit link against libobs.so.0, which lives in usr/bin/64bit
# (portable layout), not a standard library dir. linuxdeploy resolves each ELF's NEEDED libraries
# via LD_LIBRARY_PATH, so point it there or it aborts with "Could not find dependency: libobs.so.0".
export LD_LIBRARY_PATH="$APPDIR/usr/bin/64bit${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

OUTPUT="$OUTPUT_NAME" ./linuxdeploy-x86_64.AppImage --appdir "$APPDIR" \
    "${deps_args[@]}" \
    --desktop-file "$INSTALL_PREFIX/share/applications/droidcam.desktop" \
    --icon-file "$SRC/UI/forms/images/obs_256x256.png" \
    --icon-filename droidcam \
    --plugin qt \
    --plugin obs \
    --output appimage

mv DroidCam*.AppImage "$OUT_DIR"
