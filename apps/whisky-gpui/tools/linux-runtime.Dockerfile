# Runtime and headless acceptance environments share the same system libraries.
FROM ubuntu:24.04 AS runtime
COPY install-linux-runtime-deps.sh linux-runtime-packages.txt /tmp/whisky-runtime/
RUN bash /tmp/whisky-runtime/install-linux-runtime-deps.sh \
    && rm -rf /tmp/whisky-runtime /var/lib/apt/lists/*

FROM runtime AS acceptance
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pyatspi python3-gi xvfb xauth dbus-x11 xdotool xterm imagemagick \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 whisky-test \
    && mkdir /evidence && chown whisky-test:whisky-test /evidence
USER whisky-test
ENV HOME=/home/whisky-test
WORKDIR /home/whisky-test

FROM ubuntu:24.04 AS wayland-input-build
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libwayland-dev libwayland-bin pkg-config \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get update && apt-get install -y --no-install-recommends libxkbcommon-dev \
    && rm -rf /var/lib/apt/lists/*
COPY wayland-input /build
WORKDIR /build
RUN wayland-scanner client-header wlr-virtual-pointer-unstable-v1.xml virtual-pointer-client.h \
    && wayland-scanner private-code wlr-virtual-pointer-unstable-v1.xml virtual-pointer-protocol.c \
    && wayland-scanner client-header virtual-keyboard-unstable-v1.xml virtual-keyboard-client.h \
    && wayland-scanner private-code virtual-keyboard-unstable-v1.xml virtual-keyboard-protocol.c \
    && cc -Wall -Wextra -Werror -O2 main.c virtual-pointer-protocol.c virtual-keyboard-protocol.c \
       $(pkg-config --cflags --libs wayland-client xkbcommon) -o /whisky-wayland-input

FROM acceptance AS wayland-acceptance
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    sway wtype grim foot wayland-utils wl-clipboard \
    && rm -rf /var/lib/apt/lists/*
COPY --from=wayland-input-build /whisky-wayland-input /usr/local/bin/whisky-wayland-input
USER whisky-test
