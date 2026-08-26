#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR=/run/host-runtime
SOCKET=/run/nvkvm/steamos.sock
BACKEND="${NVKVM_BROKER_BACKEND:-auto}"
SIZE="${NVKVM_BROKER_SIZE:-1280x800}"
SCALE="${NVKVM_BROKER_SCALE:-aspect}"

die() { printf '[broker-container] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[broker-container] %s\n' "$*" >&2; }

[ -d "$RUNTIME_DIR" ] || die "$RUNTIME_DIR is not the host desktop runtime mount"
[ -d /run/nvkvm ] || die "/run/nvkvm is not the shared broker-socket volume"

desktop_uid="$(stat -c %u "$RUNTIME_DIR")"
desktop_gid="$(stat -c %g "$RUNTIME_DIR")"
case "$desktop_uid:$desktop_gid" in
    *[!0-9:]*|:|*:|:*) die "could not determine the desktop uid/gid" ;;
esac

# Container uid 0 has no DAC_OVERRIDE after cap_drop=ALL, so it cannot inspect
# a mode-0700 desktop runtime directory. Become its owner before looking for
# Wayland. The marker also handles the unusual case of a root-owned session.
if [ "${NVKVM_BROKER_DROPPED:-0}" != 1 ]; then
    export NVKVM_BROKER_DROPPED=1
    # CAP_SETUID/CAP_SETGID are kept ONLY so the broker can drop FURTHER once
    # its window is up -- see NVKVM_BROKER_DROP_UID below.  It spends them on
    # that one transition and clears the whole capability set immediately
    # after, proving the drop took by checking setuid(0) now fails.  Everything
    # else is still dropped here.
    exec setpriv \
        --reuid "$desktop_uid" --regid "$desktop_gid" --clear-groups \
        --inh-caps=+setuid,+setgid --ambient-caps=+setuid,+setgid \
        --no-new-privs \
        "$0" "$@"
fi

# A uid that owns nothing.
#
# Until the display connection exists the broker must BE the desktop user: the
# runtime directory is mode 0700 and the Wayland socket lives inside it.  After
# that, every resource it needs is an open fd, and staying the desktop user
# only means retaining reach into that user's files, keys and autostart
# directory for no benefit.
#
# `auto` lets the BROKER choose, because only it can read /proc/self/uid_map.
# Under `dockerd --userns-remap` or sysbox-runc the container is given a mapped
# range -- commonly 65536 uids -- and a uid outside it fails setuid() with
# EINVAL.  A number picked here in shell cannot know that; the broker can.
# Set NVKVM_BROKER_DROP_UID to pin one instead.

if [ "$BACKEND" = auto ]; then
    if [ -n "${WAYLAND_DISPLAY:-}" ] \
       && [ -S "$RUNTIME_DIR/${WAYLAND_DISPLAY##*/}" ]; then
        BACKEND=wayland
    elif [ -n "${DISPLAY:-}" ] && [ -d /tmp/.X11-unix ]; then
        BACKEND=x11
    else
        die "no usable Wayland or X11 display socket was mounted"
    fi
fi

case "$BACKEND" in
    wl|wayland)
        BACKEND=wayland
        export XDG_RUNTIME_DIR="$RUNTIME_DIR"
        export WAYLAND_DISPLAY="${WAYLAND_DISPLAY##*/}"
        [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] \
            || die "Wayland socket $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY is absent"
        ;;
    x11)
        [ -n "${DISPLAY:-}" ] || die "DISPLAY is empty for the X11 backend"
        if [ -s /run/host-xauthority ]; then
            export XAUTHORITY=/run/host-xauthority
        else
            unset XAUTHORITY
            log "no Xauthority file was supplied; the X server must already allow this local uid"
        fi
        ;;
    *) die "NVKVM_BROKER_BACKEND must be auto, wl, wayland, or x11" ;;
esac

extra=()
[ "${NVKVM_BROKER_FULLSCREEN:-0}" = 1 ] && extra+=(--fullscreen)
# Advertise only DRM_FORMAT_MOD_LINEAR, forcing the VMM to read frames back
# into a linear buffer rather than handing over the guest's native tiling.
# Set it to reproduce a cross-vendor host on a single-GPU one, or when a
# compositor advertises a modifier it then fails to import.  Costs one GPU
# transfer per frame.  An explicit boolean rather than an argv passthrough:
# this process owns a window and input focus, and letting compose inject
# arbitrary arguments into it is a widening for no benefit.
[ "${NVKVM_BROKER_LINEAR_ONLY:-0}" = 1 ] && extra+=(--linear-only)
[ -n "${NVKVM_BROKER_PRESENT_MODE:-}" ] && extra+=(--present-mode="$NVKVM_BROKER_PRESENT_MODE")
extra+=(--drop-user "${NVKVM_BROKER_DROP_UID:-auto}")

# Clipboard.  Validated here rather than passed through, for the same reason as
# every other option above: this process owns a window and input focus.
#
#   off            nothing crosses (the broker's own default)
#   guest-to-host  the guest may write YOUR clipboard; it can never read it
#   consent        the above, plus host->guest on an explicit paste key
#
# Needs QEMU's qemu-vdagent chardev on the VMM side and spice-vdagent in the
# guest; without either, this is inert rather than broken.
case "${NVKVM_BROKER_CLIPBOARD:-off}" in
    off)                       ;;
    guest-to-host|consent)     extra+=(--clipboard "$NVKVM_BROKER_CLIPBOARD") ;;
    *) die "NVKVM_BROKER_CLIPBOARD must be off, guest-to-host or consent" ;;
esac
# Which keys mean "paste".  The broker validates the list itself and refuses to
# start on a bad one, so this only has to decide whether to pass it at all.
[ -n "${NVKVM_BROKER_CLIPBOARD_TRIGGER:-}" ] \
    && extra+=(--clipboard-trigger "$NVKVM_BROKER_CLIPBOARD_TRIGGER")

# ── audio ────────────────────────────────────────────────────────────────────
# PLAYBACK ONLY, AND ONE DIRECTION BY CONSTRUCTION.
#
# The VMM writes PCM into a fifo on the shared /run/nvkvm volume; this
# container reads it and plays it to the host.  The fifo is the whole security
# argument: it cannot be read from the VMM's side, so there is no path back --
# no microphone, no monitoring of other applications, no host audio socket in
# the untrusted container at all.  Anyone who wants a microphone or a camera
# uses QEMU's own passthrough for those, which is a deliberately larger
# decision than "the game should have sound".
#
# The host connection lives HERE because this container is the trusted one: it
# already holds the display, and $XDG_RUNTIME_DIR is mounted at
# /run/host-runtime for exactly that reason.
#
# IN A SUBDIRECTORY, and not for tidiness: fs.protected_fifos is 1 on any
# modern distro, and it refuses O_WRONLY on a fifo you do not OWN inside a
# sticky world-writable directory.  The shared volume root is exactly that
# (drwxrwxrwt), so the VMM -- which does not own a fifo this container
# created -- got EACCES no matter what the mode bits said.  MEASURED: 0666
# made no difference; a plain 0755 subdirectory made it work at once.
AUDIO_DIR="$(dirname "$SOCKET")/audio"
AUDIO_FIFO="${NVKVM_AUDIO_FIFO:-$AUDIO_DIR/pcm}"
if [ "${NVKVM_AUDIO:-1}" = 1 ] && command -v pacat >/dev/null 2>&1; then
    mkdir -p "$AUDIO_DIR" && chmod 0755 "$AUDIO_DIR" 2>/dev/null
    rm -f "$AUDIO_FIFO"
    if mkfifo -m 0622 "$AUDIO_FIFO" 2>/dev/null; then
        # 0622: the VMM writes, only this container reads.
        log "audio: playing the guest stream from $AUDIO_FIFO"
        (
            # HOLD THE FIFO OPEN, read-write, for the life of this container.
            #
            # Opening a fifo for WRITE fails with ENXIO while no reader is
            # attached, and QEMU opens its audiodev during startup -- so a VM
            # that booted before the player was ready died with "Could not
            # create a backend for voice 'virtio-sound.out'" and ran silent
            # until something restarted it.  MEASURED on the first attempt.
            #
            # An O_RDWR holder never blocks, and means the writer always finds
            # a reader no matter which container starts first.  It also stops
            # the player seeing EOF when a VM shuts down, so one pw-cat serves
            # every VM restart instead of needing a respawn loop.  The holder
            # never reads, so the player still receives the whole stream.
            exec 3<>"$AUDIO_FIFO"
            while :; do
                PULSE_SERVER="unix:/run/host-runtime/pulse/native" \
                XDG_RUNTIME_DIR=/run/host-runtime \
                pacat --playback --raw \
                      --rate="${NVKVM_AUDIO_RATE:-48000}" \
                      --channels="${NVKVM_AUDIO_CHANNELS:-2}" \
                      --format="${NVKVM_AUDIO_FORMAT:-s16le}" \
                      --stream-name=nvkvm-guest \
                      "$AUDIO_FIFO" >/dev/null 2>&1
                sleep 1     # only reached if the player itself dies
            done
        ) &
    else
        log "audio: could not create $AUDIO_FIFO; the guest will have no sound"
    fi
else
    log "audio: disabled (NVKVM_AUDIO=0 or pacat missing)"
fi

log "backend=$BACKEND desktop_uid=$desktop_uid desktop_gid=$desktop_gid socket=$SOCKET"
log "the VMM has no display mount; CTRL+ALT+G toggles the broker input grab"

# The shared volume is private to these two services. Mode 0666 avoids a
# machine-specific desktop GID in Compose; SO_PEERCRED still admits only the
# VMM's uid 0, and no unrelated container has the volume mounted. This script
# is already running as the desktop uid; the only caps still inheritable are
# CAP_SETUID/CAP_SETGID, which the broker spends on the --drop-user transition
# above and then clears.
exec /usr/local/bin/nvkvm-display-broker \
        --socket "$SOCKET" \
        --socket-mode 0666 \
        --allow-user root \
        --backend "$BACKEND" \
        --size "$SIZE" \
        --scale "$SCALE" \
        --title "SteamOS — nvkvm" \
        --persist \
        "${extra[@]}" "$@"
