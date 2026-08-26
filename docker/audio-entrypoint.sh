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
#   /run/pulse/native ONE bind-mounted socket -- not $XDG_RUNTIME_DIR, which
#                     would have carried the Wayland socket in with it
# No network, no capabilities, read-only root, and it runs as nobody.
set -euo pipefail
log() { printf '[audio] %s\n' "$*" >&2; }

DIR="${NVKVM_AUDIO_DIR:-/run/nvkvm/audio}"
FIFO="$DIR/pcm"
PULSE="${NVKVM_PULSE_SOCKET:-/run/pulse/native}"

# 0755, NOT the volume root: fs.protected_fifos refuses O_WRONLY on a fifo the
# writer does not own inside a sticky world-writable directory, and the volume
# root is drwxrwxrwt.  No sysctl change, just somewhere the rule does not apply.
mkdir -p "$DIR" && chmod 0755 "$DIR"
rm -f "$FIFO"
mkfifo -m 0622 "$FIFO"          # the VMM writes; it can never read
log "fifo ready at $FIFO"

[ -S "$PULSE" ] || log "WARNING: no socket at $PULSE -- there is nothing to play to"

# Hold it open read-write for the life of the container: opening a fifo for
# WRITE fails with ENXIO while no reader is attached, and QEMU opens its
# audiodev during startup, so without this the container start order decided
# whether the VM had sound.  It also means one player survives every VM
# restart instead of needing a respawn loop.
exec 3<>"$FIFO"
log "playing to $PULSE"
while :; do
    PULSE_SERVER="unix:$PULSE" \
    pacat --playback --raw \
          --rate="${NVKVM_AUDIO_RATE:-48000}" \
          --channels="${NVKVM_AUDIO_CHANNELS:-2}" \
          --format="${NVKVM_AUDIO_FORMAT:-s16le}" \
          --stream-name=nvkvm-guest \
          "$FIFO" >/dev/null 2>&1 || true
    sleep 1     # only reached if the player itself dies
done
