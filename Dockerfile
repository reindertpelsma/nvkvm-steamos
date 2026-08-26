# syntax=docker/dockerfile:1.7
# Standalone SteamOS/nvkvm build. Compose supplies `nvkvm-source` as a named
# context: public main by default, or an explicitly selected local checkout.

FROM ubuntu:24.04 AS nvkvm-build

ARG DEBIAN_FRONTEND=noninteractive
ARG NVKVM_SOURCE_LABEL=https://github.com/reindertpelsma/nvkvm-pv.git#main

# spice-protocol is HEADERS ONLY (no spice server). It is what gates QEMU's
# qemu-vdagent chardev -- without it the clipboard transport does not exist.
RUN apt-get update -q && apt-get install -y --no-install-recommends \
        build-essential git ca-certificates \
        ninja-build meson libglib2.0-dev libpixman-1-dev \
        python3 python3-venv python3-tomli libslirp-dev pkg-config \
        libattr1-dev libepoxy-dev libgbm-dev libegl-dev libdrm-dev xxd \
        libwayland-dev wayland-protocols libspice-protocol-dev \
        libxcb1-dev libxcb-dri3-dev libxcb-present-dev libxcb-xinput-dev \
        libxcb-render0-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=nvkvm-source / /opt/nvkvm
RUN test -x /opt/nvkvm/scripts/build_qemu.sh \
    && (git -C /opt/nvkvm rev-parse HEAD 2>/dev/null || echo "$NVKVM_SOURCE_LABEL") \
        > /opt/nvkvm/.nvkvm-upstream-commit

WORKDIR /opt/nvkvm
RUN bash scripts/build_qemu.sh \
    && make -C src/broker clean all \
    && test -x src/broker/nvkvm-display-broker

# The source share seen by SteamOS is nvkvm-pv plus this repository's boot and
# installer policy. It is assembled once in the image and exported read-only.
COPY boot /opt/nvkvm/boot
COPY install_steamos_vm.sh /opt/nvkvm/install_steamos_vm.sh
COPY vm /opt/nvkvm/vm
COPY scripts/steamos-container-entrypoint.sh /opt/nvkvm/scripts/steamos-container-entrypoint.sh
COPY scripts/steamos-ssh.sh /opt/nvkvm/scripts/steamos-ssh.sh
COPY scripts/steamos-serial.sh /opt/nvkvm/scripts/steamos-serial.sh

RUN find src boot tests/validate.sh -type f -print0 \
        | sort -z | xargs -0 sha256sum | sha256sum | cut -d ' ' -f1 \
        > /opt/nvkvm/.nvkvm-source-id \
    && rm -rf /opt/nvkvm/.git


FROM ubuntu:24.04 AS vmm

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -y --no-install-recommends \
        libglib2.0-0t64 libpixman-1-0 libslirp0 libepoxy0 libgbm1 libegl1 libgl1 \
        libdrm2 libattr1 seabios ipxe-qemu \
        curl wget ca-certificates qemu-utils genisoimage \
        bzip2 cpio gzip tar ovmf util-linux \
        openssh-client sshpass \
        socat \
    && rm -rf /var/lib/apt/lists/*

COPY --from=nvkvm-build /opt/qemu-nvkvm /opt/qemu-nvkvm
COPY --from=nvkvm-build /usr/lib/nvkvm /usr/lib/nvkvm
COPY --from=nvkvm-build /opt/nvkvm /opt/nvkvm
RUN ln -s /opt/nvkvm/scripts/steamos-ssh.sh /usr/local/bin/nvkvm-steamos-ssh \
    && ln -s /opt/nvkvm/scripts/steamos-serial.sh /usr/local/bin/nvkvm-steamos-serial

WORKDIR /opt/nvkvm
EXPOSE 15022
ENTRYPOINT ["/opt/nvkvm/scripts/steamos-container-entrypoint.sh"]


FROM ubuntu:24.04 AS broker

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -y --no-install-recommends \
        libwayland-client0 libxcb1 libxcb-dri3-0 libxcb-present0 \
        libxcb-xinput0 libxcb-render0 util-linux ca-certificates \
        `# pw-cat: plays the guest's audio stream. The TRUSTED container holds` \
        `# the connection to the host's PipeWire; the VMM only ever writes to` \
        `# a fifo.` \
    && rm -rf /var/lib/apt/lists/*

COPY --from=nvkvm-build /opt/nvkvm/src/broker/nvkvm-display-broker /usr/local/bin/
COPY docker/broker-entrypoint.sh /usr/local/bin/nvkvm-broker-entrypoint
ENTRYPOINT ["/usr/local/bin/nvkvm-broker-entrypoint"]


# ── audio player ─────────────────────────────────────────────────────────────
# Its own stage, and NOT the broker's base, for one reason: pw-cat only grew
# --raw after 24.04's PipeWire, and --raw is the whole security argument.  With
# it, the guest's bytes are opaque payload -- read() into a buffer, write to a
# stream, no parser.  Without it pw-cat hands the file to libsndfile, a full
# multi-format C parser with a CVE history (CVE-2021-3246, CVE-2022-33065),
# which is precisely what must not touch attacker-controlled bytes.
#
# pw-cat rather than pacat because PulseAudio is in maintenance mode -- pacat.c
# has had no functional change since 2018 and upstream carries no threat model
# for a hostile input source -- while PipeWire is the actively developed stack
# and is what the host actually runs.
FROM ubuntu:26.04 AS audio

ARG DEBIAN_FRONTEND=noninteractive
# BOTH clients, because the host decides which one is usable: a PipeWire host
# gets pw-cat, a legacy PulseAudio-only host gets pacat.  Neither is large, and
# shipping only the modern one would mean no sound on anything older.
RUN apt-get update -q && apt-get install -y --no-install-recommends \
        pipewire-bin pulseaudio-utils \
    && rm -rf /var/lib/apt/lists/*

COPY docker/audio-entrypoint.sh /usr/local/bin/nvkvm-audio-entrypoint
ENTRYPOINT ["/usr/local/bin/nvkvm-audio-entrypoint"]
