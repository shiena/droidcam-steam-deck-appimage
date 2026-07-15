#! /bin/bash

# exit whenever a command called in this script fails
set -e

appdir=""

show_usage() {
    echo "Usage: bash $0 --appdir <AppDir>"
}

while [ "$1" != "" ]; do
    case "$1" in
        --plugin-api-version)
            echo "0"
            exit 0
            ;;
        --appdir)
            appdir="$2"
            shift
            shift
            ;;
        *)
            echo "Invalid argument: $1"
            echo
            show_usage
            exit 2
    esac
done

if [[ "$appdir" == "" ]]; then
    show_usage
    exit 2
fi

echo "linuxdeploy-plugin-obs"
echo "\$LINUXDEPLOY: \"$LINUXDEPLOY\""

# Remove unused files
rm -rf "$appdir"/usr/share/doc "$appdir"/usr/share/man

set -x
mkdir -p "$appdir"/usr/bin

# zenity-based askpass helper, used as SUDO_ASKPASS when no graphical askpass is available.
cat > "$appdir"/usr/bin/zenity-askpass <<\EOF
#!/bin/sh
exec zenity --password --title="$1"
EOF
chmod +x "$appdir"/usr/bin/zenity-askpass

# Root helper: make the bundled standard v4l2loopback module available to the running kernel
# (SteamOS ships a read-only /usr/lib/modules, so we overlay-merge the bundled module dir), then
# load it with the card label DroidCam OBS expects (OBS_V4L2_CARD_LABEL = "DroidCam Virtual
# Camera"). Loading it here means OBS sees the module already loaded and skips its own pkexec.
cat > "$appdir"/usr/bin/droidcam-module-load <<\EOF
#!/bin/sh
set -e
if [ "$(id -u)" -ne 0 ]
then
    echo "Needs to be run as root." >&2
    exit 1
fi
CARD_LABEL="DroidCam Virtual Camera"
LOWER_DIR="$1"
KVER="$(uname -r)"
if ! modinfo v4l2loopback >/dev/null 2>&1
then
    if [ -n "$LOWER_DIR" ] && [ -d "$LOWER_DIR" ]
    then
        TMP_DIR="$(mktemp -d -p /tmp appimage-droidcam.XXXXXX)"
        cleanup() {
            if [ -d "$TMP_DIR" ]
            then
                umount -l "/usr/lib/modules/$KVER" || true
                rm -rf "$TMP_DIR" || true
            fi
        }
        trap cleanup EXIT
        mkdir "$TMP_DIR/upper" "$TMP_DIR/work"
        mount -t overlay -o lowerdir="$LOWER_DIR":"/usr/lib/modules/$KVER",upperdir="$TMP_DIR/upper",workdir="$TMP_DIR/work" overlay "/usr/lib/modules/$KVER"
        depmod -A
    fi
fi
modprobe videodev
if ! lsmod | grep -q '^v4l2loopback\b'
then
    modprobe v4l2loopback exclusive_caps=1 card_label="$CARD_LABEL"
fi
EOF
chmod +x "$appdir"/usr/bin/droidcam-module-load

mkdir -p "$appdir"/apprun-hooks
cat > "$appdir"/apprun-hooks/linuxdeploy-plugin-obs.sh <<\EOF
export PATH="$APPDIR/usr/bin:$PATH"
# The OBS portable tree keeps libobs and co-located libs in bin/64bit ($ORIGIN rpath); external
# deps gathered by linuxdeploy live in usr/lib. Make both discoverable.
export LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/bin/64bit${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Belt-and-suspenders: also expose the OBS plugin tree explicitly (AddExtraModulePaths reads these),
# so plugins load even if the launcher's CWD-relative lookup ever changes.
export OBS_PLUGINS_PATH="$APPDIR/usr/obs-plugins/64bit"
export OBS_PLUGINS_DATA_PATH="$APPDIR/usr/data/obs-plugins"

# linuxdeploy-plugin-qt bundles the Qt plugins under usr/plugins and writes a qt.conf next to
# usr/bin, but the real Qt binary lives in usr/bin/64bit (OBS portable layout), so Qt reads neither
# and aborts with: could not find the Qt platform plugin "xcb". Point Qt at the bundled plugins.
export QT_PLUGIN_PATH="$APPDIR/usr/plugins${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
export QT_QPA_PLATFORM_PLUGIN_PATH="$APPDIR/usr/plugins/platforms"

if command -v zenity >/dev/null
then
    has_zenity=1
else
    has_zenity=0
fi

# Best-effort: ensure the standard v4l2loopback module is loaded so OBS's Virtual Camera works on
# SteamOS. If this fails or the user cancels the password prompt, OBS still launches (without the
# virtual camera output).
if ! lsmod | grep -q '^v4l2loopback\b'
then
    if [ -z "$SUDO_ASKPASS" ]
    then
        for ap in ksshaskpass ssh-askpass zenity
        do
            if apc="$(command -v "$ap")"
            then
                if [ "$ap" = "zenity" ]
                then
                    apc="$(command -v "zenity-askpass")"
                fi
                export SUDO_ASKPASS="$apc"
                break
            fi
        done
    fi

    # Locate the bundled module dir, preferring an exact match for the running kernel.
    if [ -d "$APPDIR/usr/lib/modules/$(uname -r)" ]
    then
        LOWER_DIR="$APPDIR/usr/lib/modules/$(uname -r)"
    else
        LOWER_DIR="$(find "$APPDIR/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | tail -n 1)"
        if [ -z "$LOWER_DIR" ] && ! modinfo v4l2loopback >/dev/null 2>&1
        then
            echo "WARNING! No v4l2loopback module found for the current kernel. The appimage may need to be updated."
            if [ "$has_zenity" -eq 1 ]
            then
                zenity --warning --width=300 --text="WARNING! No v4l2loopback module found that matches the current kernel. The Virtual Camera may be unavailable; the appimage may need to be updated." || true
            fi
        fi
    fi

    if [ -n "$LOWER_DIR" ] || modinfo v4l2loopback >/dev/null 2>&1
    then
        TMP_DIR="$(mktemp -d -p /tmp appimage-droidcam.XXXXXX)"
        mkdir "$TMP_DIR/lower"
        if [ -n "$LOWER_DIR" ]
        then
            cp -a "$LOWER_DIR"/. "$TMP_DIR/lower/"
        fi
        LOG_FILE="$TMP_DIR/appimage-droidcam.log"
        touch "$LOG_FILE"
        progress_pid=
        if [ "$has_zenity" -eq 1 ]
        then
            mkfifo -m 600 "$TMP_DIR/progress"
            cat "$TMP_DIR/progress" | zenity --progress --pulsate --no-cancel --auto-close --title="DroidCam OBS - Virtual Camera" --width=300 --text="Loading v4l2loopback kernel module" &
            progress_pid="$!"
        fi
        sudo_status="$TMP_DIR/sudo_status"
        if ! cat "$APPDIR/usr/bin/droidcam-module-load" | { sudo -A sh -s "$TMP_DIR/lower" 2>&1 || echo "$?" > "$sudo_status" ;} | tee -a "$LOG_FILE" >&2 || \
            { [ -f "$sudo_status" ] && [ "$(cat "$sudo_status")" -ne 0 ] ;}
        then
            echo "WARNING! Failed to load v4l2loopback. The Virtual Camera will be unavailable." 2>&1 | tee -a "$LOG_FILE" >&2
            if [ "$has_zenity" -eq 1 ]
            then
                zenity --warning --width=300 --title="DroidCam OBS" --text="$(cat "$LOG_FILE")" || true
            fi
        fi
        if [ "$has_zenity" -eq 1 ]
        then
            echo 100 > "$TMP_DIR/progress"
            wait "$progress_pid" || true
        fi
        rm -rf "$TMP_DIR"
    fi
fi
EOF
