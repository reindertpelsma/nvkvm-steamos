#!/usr/bin/env bash
# The guest's audio, played by a process that can do nothing else.
#
# This container exists so that the player is NOT the broker.  The broker holds
# the Wayland/X connection, the keyboard grab and the clipboard; putting a
# process that parses attacker-controlled bytes next to all of that means a bug
# in the player reaches the display.  Here it reaches a fifo and one socket.
#
# What this container can touch, in full:
#   /run/nvkvm        the shared volume, for the fifo the VMM writes
#   /run/pw/pipewire-0 ONE bind-mounted socket -- not $XDG_RUNTIME_DIR, which
#                     would have carried the Wayland socket in with it
# No network, no capabilities, read-only root, and it runs as nobody.
set -euo pipefail
log() { printf '[audio] %s\n' "$*" >&2; }

DIR="${NVKVM_AUDIO_DIR:-/run/nvkvm/audio}"
FIFO="$DIR/pcm"
PW_DIR="${NVKVM_PW_RUNTIME_DIR:-/run/pw}"
PW_SOCK="$PW_DIR/pipewire-0"
PULSE_SOCK="${NVKVM_PULSE_SOCKET:-/run/pulse/native}"

# 0755, NOT the volume root: fs.protected_fifos refuses O_WRONLY on a fifo the
# writer does not own inside a sticky world-writable directory, and the volume
# root is drwxrwxrwt.  No sysctl change, just somewhere the rule does not apply.
mkdir -p "$DIR" && chmod 0755 "$DIR"
#
# REATTACH, do not replace.  Recreating the fifo unconditionally means that
# restarting THIS container while a VM is running orphans QEMU's file
# descriptor: it keeps writing into the old inode, which now has no reader, and
# the guest goes silent with no error anywhere to explain it.  depends_on does
# not help -- it orders startup, not restarts.  MEASURED exactly that way.
#
# So keep an existing fifo and only create one when there is none, or when
# something that is not a fifo is sitting in its place.
if [ -p "$FIFO" ]; then
    log "reusing the existing fifo (a running VM may already hold it open)"
else
    rm -f "$FIFO"
    mkfifo -m 0622 "$FIFO"      # the VMM writes; it can never read
    log "created $FIFO"
fi
log "fifo ready at $FIFO"

#
# WHICH PLAYER, decided by what the host actually offers.
#
# pw-cat is preferred: PipeWire is the actively developed stack, whereas
# PulseAudio is in maintenance mode and pacat.c has had no functional change
# since 2018.  But a legacy host runs PulseAudio and has no pipewire socket at
# all, and "no sound on anything older than the author's machine" is not a
# supported product.  So: use the maintained client where it exists, and the
# one that works where it does not.  Both are --raw, so the guest's bytes stay
# opaque payload either way; only the client differs.
if [ -S "$PW_SOCK" ]; then
    PLAYER=pw
    log "host offers pipewire; using pw-cat"
elif [ -S "$PULSE_SOCK" ]; then
    PLAYER=pulse
    log "host offers pulseaudio only; using pacat"
else
    PLAYER=none
    log "WARNING: no pipewire socket at $PW_SOCK and no pulse socket at"
    log "WARNING: $PULSE_SOCK -- there is nothing to play to.  On a host with"
    log "WARNING: neither, point NVKVM_AUDIO_PW_SOCKET/NVKVM_AUDIO_PULSE_SOCKET"
    log "WARNING: at the right paths, or /dev/null to silence this."
fi

# Hold it open read-write for the life of the container: opening a fifo for
# WRITE fails with ENXIO while no reader is attached, and QEMU opens its
# audiodev during startup, so without this the container start order decided
# whether the VM had sound.  It also means one player survives every VM
# restart instead of needing a respawn loop.
exec 3<>"$FIFO"
log "player=$PLAYER"
while :; do
    # --raw is the security property, not a convenience: without it BOTH
    # players hand the fifo to libsndfile, a full multi-format C parser with a
    # real CVE history, and the guest's bytes stop being opaque payload.
    # Never remove it from either branch.
    if [ "$PLAYER" = pw ]; then
        PIPEWIRE_RUNTIME_DIR="$PW_DIR" \
        pw-cat --playback --raw \
               --rate "${NVKVM_AUDIO_RATE:-48000}" \
               --channels "${NVKVM_AUDIO_CHANNELS:-2}" \
               --format "${NVKVM_AUDIO_FORMAT:-s16}" \
               --media-role Game \
               "$FIFO" >/dev/null 2>&1 || true
    elif [ "$PLAYER" = pulse ]; then
        PULSE_SERVER="unix:$PULSE_SOCK" \
        pacat --playback --raw \
              --rate="${NVKVM_AUDIO_RATE:-48000}" \
              --channels="${NVKVM_AUDIO_CHANNELS:-2}" \
              --format="${NVKVM_AUDIO_FORMAT_PULSE:-s16le}" \
              --stream-name=nvkvm-guest \
              "$FIFO" >/dev/null 2>&1 || true
    else
        sleep 30            # nothing to play to; do not spin
    fi
    sleep 1     # only reached if the player itself dies
done
