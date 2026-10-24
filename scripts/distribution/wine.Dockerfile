# syntax=docker/dockerfile:1
# Build context: the Wine repository supplied by --wine-repo.
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends sudo python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY install-deps.sh /tmp/install-wine-deps.sh
RUN bash /tmp/install-wine-deps.sh && rm /tmp/install-wine-deps.sh \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /wine
