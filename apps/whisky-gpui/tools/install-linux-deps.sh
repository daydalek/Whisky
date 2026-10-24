#!/usr/bin/env bash
# Ubuntu 24.04 development and headless acceptance dependencies. Run as root.
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends \
    build-essential clang curl ca-certificates pkg-config patchelf libssl-dev \
    libasound2-dev libudev-dev libfontconfig1-dev libfreetype-dev libzstd-dev \
    libgdk-pixbuf-2.0-dev libgtk-4-dev webp-pixbuf-loader \
    libxkbcommon-dev libxkbcommon-x11-dev libwayland-dev libx11-xcb-dev \
    libxcb-shape0-dev libxcb-xfixes0-dev libxcb-render0-dev libxcb-randr0-dev \
    libxcb-xinput-dev libxcb-cursor-dev libvulkan-dev mesa-vulkan-drivers \
    xvfb xauth dbus-x11 xdotool xterm imagemagick fonts-noto-cjk python3 python3-pyatspi python3-gi desktop-file-utils xdg-utils
