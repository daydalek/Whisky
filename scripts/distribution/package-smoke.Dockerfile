# syntax=docker/dockerfile:1
FROM ubuntu:24.04 AS ubuntu-base
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 ca-certificates xvfb xauth xdotool dbus-x11 imagemagick \
    fonts-noto-cjk mesa-vulkan-drivers libegl1 libgl1 libgles2 libvulkan1 \
    libxkbcommon-x11-0 libxcb-cursor0 libwayland-client0 libglib2.0-bin \
    xdg-utils desktop-file-utils \
    && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --uid 10001 whisky-test && mkdir /evidence && chown whisky-test:whisky-test /evidence
COPY smoke-format.py /tests/smoke-format.py
COPY check-linux-wine-update.py check-diagnostics.py /tests/
ENV HOME=/home/whisky-test
WORKDIR /home/whisky-test

FROM ubuntu-base AS deb
COPY package.deb /package.deb
RUN apt-get update && apt-get install -y --no-install-recommends /package.deb \
    && rm -rf /var/lib/apt/lists/* /package.deb

FROM ubuntu-base AS appimage-ubuntu
COPY Whisky.AppImage /opt/Whisky.AppImage
RUN chmod 755 /opt/Whisky.AppImage

FROM fedora:44 AS fedora-base
RUN --mount=type=cache,id=whisky-fedora44-metadata,target=/var/cache/libdnf5,sharing=locked \
    dnf --setopt=timeout=15 --setopt=retries=2 --setopt=install_weak_deps=False \
    --disablerepo=fedora-cisco-openh264 install -y python3 ca-certificates xorg-x11-server-Xvfb xorg-x11-xauth xdotool \
    dbus-daemon ImageMagick google-noto-sans-cjk-fonts mesa-vulkan-drivers \
    libglvnd-egl libglvnd-glx libglvnd-gles vulkan-loader libxkbcommon-x11 xcb-util-cursor \
    glib2 xdg-utils desktop-file-utils util-linux
RUN useradd --create-home --uid 10001 whisky-test && mkdir /evidence && chown whisky-test:whisky-test /evidence
COPY smoke-format.py /tests/smoke-format.py
COPY check-linux-wine-update.py check-diagnostics.py /tests/
ENV HOME=/home/whisky-test
WORKDIR /home/whisky-test

FROM fedora-base AS rpm
COPY package.rpm /package.rpm
RUN --mount=type=cache,id=whisky-fedora44-metadata,target=/var/cache/libdnf5,sharing=locked \
    dnf --setopt=timeout=15 --setopt=retries=2 --setopt=install_weak_deps=False \
    --disablerepo=fedora-cisco-openh264 install -y /package.rpm && rm /package.rpm

FROM fedora-base AS appimage-fedora
COPY Whisky.AppImage /opt/Whisky.AppImage
RUN chmod 755 /opt/Whisky.AppImage
