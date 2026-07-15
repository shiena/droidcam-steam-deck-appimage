# DroidCam OBS Client AppImage for the Steam Deck

- https://github.com/dev47apps/droidcam-obs-client
- https://play.google.com/store/apps/details?id=com.dev47apps.droidcam
- https://play.google.com/store/apps/details?id=com.dev47apps.droidcamx

This builds the **DroidCam OBS client** (a slim fork of OBS Studio 27.2 by dev47apps) into a
single AppImage for the Steam Deck. It bundles the standard `v4l2loopback` kernel module for the
known SteamOS kernel versions so the OBS **Virtual Camera** output works out of the box, letting
other apps (browser, Discord, ...) use your phone as a webcam.

The goal is to make it as easy as possible to use DroidCam on the Steam Deck.

# How it works

The app is built in the "portable" OBS layout, which resolves its plugins and data relative to
the executable, so the whole tree runs from anywhere inside the AppImage mount.

Before launching the GUI, the AppImage tries to load the bundled `v4l2loopback` module (used by
OBS's Virtual Camera) if it isn't already loaded. It needs root credentials and uses an
appropriate or manually set `SUDO_ASKPASS` helper for this. Because SteamOS ships a read-only
`/usr/lib/modules`, it merges the currently running kernel's module folder with the one shipping
in the AppImage using `overlayfs`, then loads the module labeled `DroidCam Virtual Camera`.

If the module can't be loaded (e.g. the password prompt is cancelled, or no matching module is
bundled for the running kernel), the GUI still launches — only the Virtual Camera output is
unavailable until `v4l2loopback` is installed by other means.

# Usage

The DroidCam OBS client UI does not show a *Start Virtual Camera* button, so launch the AppImage
with `--startvirtualcam` to start the Virtual Camera output:

```sh
./DroidCam-OBS-*-x86_64_SteamDeck.AppImage --startvirtualcam
```

With the camera started, the connected phone's video is written to the bundled `v4l2loopback`
device, so other apps (browser, Discord, ...) can use it as a webcam.

# Build

Requires podman or docker.

It uses the Arch Linux image converted into a SteamOS base to build the `v4l2loopback` kernel
module against each known SteamOS kernel.

The DroidCam OBS GUI is built in AlmaLinux 8 (its older glibc keeps the binaries
forward-compatible with the newer SteamOS userland) and packaged with `linuxdeploy` + the Qt
plugin.

```sh
./build.sh
```

The resulting AppImage will appear as `DroidCam-OBS-*-x86_64_SteamDeck.AppImage`.

# Signing (optional)

```sh
./sign.sh DroidCam-OBS-*-x86_64_SteamDeck.AppImage
```
