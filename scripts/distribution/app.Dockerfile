# syntax=docker/dockerfile:1
# Ubuntu 24.04 ABI baseline; native amd64 builders are preferred for release CI.
FROM swift:6.4.0-noble
COPY install-deps.sh /tmp/install-linux-deps.sh
RUN bash /tmp/install-linux-deps.sh && rm /tmp/install-linux-deps.sh \
    && apt-get install -y --no-install-recommends rpm dpkg-dev squashfs-tools file \
    && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh \
    && sh /tmp/rustup.sh -y --profile minimal --default-toolchain 1.99.1 \
    && rm /tmp/rustup.sh
ENV PATH=/opt/cargo/bin:$PATH CC=/usr/bin/clang-21 CXX=/usr/bin/clang++-21
WORKDIR /workspace
