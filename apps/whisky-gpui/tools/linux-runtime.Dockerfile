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
