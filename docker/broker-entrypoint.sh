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
# directory for no benefit.  So it becomes a uid nothing on the system owns.
#
# Random rather than fixed so two brokers, or a broker and anything else that
# picked a "sensible" number, cannot end up sharing an identity.  The range is
# above the usual system and login ranges and below the isolate's 500000+
# window (a different container, but worth not colliding on principle).
if [ -z "${NVKVM_BROKER_DROP_UID:-}" ]; then
    NVKVM_BROKER_DROP_UID=$(( 100000 + ($(od -An -N3 -tu4 /dev/urandom) % 300000) ))
fi
case "$NVKVM_BROKER_DROP_UID" in
    0|"") die "NVKVM_BROKER_DROP_UID must be a non-zero uid" ;;
esac

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
extra+=(--drop-user "$NVKVM_BROKER_DROP_UID")

log "backend=$BACKEND desktop_uid=$desktop_uid desktop_gid=$desktop_gid socket=$SOCKET"
log "the VMM has no display mount; CTRL+ALT+G toggles the broker input grab"

# The shared volume is private to these two services. Mode 0666 avoids a
# machine-specific desktop GID in Compose; SO_PEERCRED still admits only the
# VMM's uid 0, and no unrelated container has the volume mounted. This script
# is already running as the desktop uid with no effective/permitted caps.
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
