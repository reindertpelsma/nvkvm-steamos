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
#
# ADOPT NOTHING THE VMM MADE.  The volume root is 1777 and the vmm container
# runs as uid 0 with it mounted rw, so the VMM can create $DIR first and choose
# its mode.  Pre-created 0755 slips through unnoticed (GNU chmod elides the
# syscall when the mode already matches); pre-created 0700 makes the chmod fail
# under `set -e`, and with restart: unless-stopped this container then
# crash-loops forever.  Refuse a directory we do not own rather than taking
# whatever is there.
if [ -e "$DIR" ] && [ "$(stat -c %u "$DIR" 2>/dev/null)" != "$(id -u)" ]; then
    log "ERROR: $DIR exists and is not owned by uid $(id -u) -- refusing to adopt it."
    log "ERROR: the VMM can reach this path; a directory it pre-created is not ours to use."
    exit 1
fi
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
# -p follows symlinks, so "there is already a fifo here" can be answered by an
# inode of the VMM's choosing.  Require it to be a real fifo AND ours before
# reusing it; anything else is replaced.
if [ -p "$FIFO" ] && [ ! -L "$FIFO" ] \
   && [ "$(stat -c %u "$FIFO" 2>/dev/null)" = "$(id -u)" ]; then
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
#
# RE-PROBED EVERY ITERATION, not decided once.  A socket outlives its server:
# `systemctl --user restart pipewire`, a logout, or a session switch leaves the
# file there with nothing behind it.  Deciding once meant PLAYER stayed `pw`
# for the life of the container, pw-cat failed instantly on every iteration,
# and NOBODY READ THE FIFO -- which is the wedge this script exists to prevent,
# reached by a different route than the one 918b1e8 closed.  The sibling
# entrypoint documents the same trap for the Wayland socket.
pick_player() {
    if [ -S "$PW_SOCK" ]; then
        PLAYER=pw
    elif [ -S "$PULSE_SOCK" ]; then
        PLAYER=pulse
    else
        PLAYER=none
    fi
    if [ "$PLAYER" != "${PLAYER_LAST:-}" ]; then
        case "$PLAYER" in
            pw)    log "host offers pipewire; using pw-cat" ;;
            pulse) log "host offers pulseaudio only; using pacat" ;;
            none)  log "no audio server reachable; draining and discarding" ;;
        esac
        PLAYER_LAST="$PLAYER"
    fi
}
pick_player
if [ "$PLAYER" = none ]; then
    log "WARNING: no pipewire socket at $PW_SOCK and no pulse socket at"
    log "WARNING: $PULSE_SOCK -- there is nothing to play to.  On a host with"
    log "WARNING: neither, point NVKVM_AUDIO_PW_SOCKET/NVKVM_AUDIO_PULSE_SOCKET"
    log "WARNING: at the right paths, or /dev/null to silence this."
    log "WARNING: the guest still runs -- its audio is drained and discarded, which"
    log "WARNING: is what keeps QEMU's main loop from blocking on a full fifo"
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
        # NO PLAYER: DRAIN ANYWAY.  This branch used to sleep, which left the
        # fifo with a holder but no reader -- and that FREEZES THE WHOLE VM.
        # QEMU writes guest audio from its MAIN LOOP; once the 64 KiB pipe
        # buffer fills, that write(2) blocks, and with it every timer, the
        # display path and the monitor.
        #
        # MEASURED on a host whose session had no PipeWire and no PulseAudio
        # socket: the guest booted, reached "Reached target Graphical
        # Interface", opened the audio device, and stopped dead.  QEMU's main
        # thread sat in anon_pipe_write, the vCPUs burned zero ticks, QMP went
        # unanswered and the broker held an attached client that never sent a
        # single ATTACH.  It looks exactly like a wedged bootloader, and cost a
        # long detour through GRUB, OVMF and grub.cfg before the pipe turned up.
        #
        # A host with no audio server must degrade to SILENCE, never to a
        # hung guest.  cat is a reader, so the buffer keeps emptying.
        cat "$FIFO" >/dev/null 2>&1 || true
    fi
    #
    # NEVER LEAVE THE FIFO UNREAD, not even for a second.  QEMU's wav backend
    # writes from its MAIN LOOP with a blocking fwrite, paced to real time at
    # 48 kHz x 2ch x s16 = 192 kB/s, so a 64 KiB pipe fills in ~0.34 s.  A bare
    # `sleep 1` between player restarts is therefore long enough to stall every
    # QEMU timer, the display path and QMP.  Drain for the whole gap instead.
    #
    # fd 3 is the read-write holder opened above, so this reads without racing
    # the open.  timeout bounds it so the loop still re-probes.
    timeout 1 cat <&3 >/dev/null 2>&1 || true
    pick_player
done
