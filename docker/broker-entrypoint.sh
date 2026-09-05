#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR=/run/host-runtime
SOCKET=/run/nvkvm/steamos.sock
BACKEND="${NVKVM_BROKER_BACKEND:-auto}"
SIZE="${NVKVM_BROKER_SIZE:-1280x800}"
SCALE="${NVKVM_BROKER_SCALE:-aspect}"

die() { printf '[broker-container] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[broker-container] %s\n' "$*" >&2; }
warn() { printf '[broker-container] WARNING: %s\n' "$*" >&2; }

[ -d "$RUNTIME_DIR" ] || die "$RUNTIME_DIR is not the host desktop runtime mount"
[ -d /run/nvkvm ] || die "/run/nvkvm is not the shared broker-socket volume"

# STAT THE SOCKET, NOT THE DIRECTORY.  Only the Wayland socket is bound in now
# (the rest of the session runtime dir is not the broker's business), so
# /run/host-runtime itself is created by the container runtime and owned by
# root.  Stat'ing it would put us back at desktop_uid=0 -- the exact bug that
# made the broker unable to reach the session it was pointed at.
uid_probe="$RUNTIME_DIR/${WAYLAND_DISPLAY##*/}"
# ON AN X11 HOST, THE X SOCKET IS THE ONLY THING LEFT TO ASK.
#
# There is no Wayland socket to stat -- `make up` binds /dev/null at that path
# so the mount can stay declared -- and falling back to $RUNTIME_DIR yields
# desktop_uid=0, so the broker stays root.  That is not merely cosmetic:
# cap_drop:ALL means container root has no CAP_DAC_OVERRIDE, and mutter's
# Xwayland creates /tmp/.X11-unix/X0 as 0775 owned by the desktop user.  Root
# is "other", "other" has no write bit, and connect(2) on a unix socket needs
# one -- so the broker was refused by PERMISSION before authorization was ever
# reached, which is why the failure never printed an auth error.
#
# MEASURED on GNOME/Xwayland 2026-09-05, same mounts each time:
#   default caps, root                   -> connects (DAC_OVERRIDE covers it)
#   cap_drop ALL, root                   -> "unable to open display :0"
#   cap_drop ALL, +DAC_OVERRIDE, root    -> connects
#   cap_drop ALL, uid 1000               -> reaches AUTH ("Authorization required")
#   cap_drop ALL, uid 1000 + xhost user  -> connects
#
# Classic Xorg makes that socket 0777, which is why a real X11 laptop worked and
# this did not.  The X socket is owned by the seat, so it answers the same
# question the Wayland socket answers: who is the desktop user.
if [ ! -S "$uid_probe" ] && [ -n "${DISPLAY:-}" ]; then
    _x_n="${DISPLAY##*:}"
    _x_n="${_x_n%%.*}"
    case "$_x_n" in
        ''|*[!0-9]*) : ;;
        *) [ -S "/tmp/.X11-unix/X$_x_n" ] && uid_probe="/tmp/.X11-unix/X$_x_n" ;;
    esac
fi
# -S, NOT -e.  An X11 host has no Wayland socket, and `make up` binds /dev/null
# at this path so the mount can stay declared (see docker-compose.yml).  /dev/null
# EXISTS and is owned by root, so -e would stat it and hand back desktop_uid=0 --
# indistinguishable from the poisoned-directory bug this probe exists to avoid.
# Only a real socket says anything about who owns the session.
[ -S "$uid_probe" ] || uid_probe="$RUNTIME_DIR"
desktop_uid="$(stat -c %u "$uid_probe")"
desktop_gid="$(stat -c %g "$uid_probe")"
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
    #
    # VALIDATE, then let the BROKER choose.  This used to resolve auto itself
    # and pass an explicit --backend, which defeated the broker's own fallback:
    # nb_session_open() tries Wayland and falls through to X11 when it does not
    # come up, but only while it is still being asked for "auto".
    #
    # That mattered because the test here is whether the socket EXISTS, not
    # whether anything answers on it.  A Wayland socket outlives its
    # compositor -- stopping GDM to run Xorg leaves one behind -- so the
    # entrypoint committed to Wayland, the connect failed, and the container
    # crash-looped on a machine with a perfectly good X server.  MEASURED
    # exactly that way while testing the X11 backend.
    #
    # So keep the fail-fast for "nothing was mounted at all", which is a
    # deployment mistake worth naming, and hand the actual choice to the code
    # that can recover from a wrong guess.
    _wl_path="$RUNTIME_DIR/${WAYLAND_DISPLAY##*/}"
    #
    # A DIRECTORY here is not the same as nothing, and saying so saves an hour.
    # Docker used to create the bind source when it was missing, so a run with
    # an empty WAYLAND_DISPLAY left a root-owned DIRECTORY at the socket path on
    # the host -- permanently.  Every later run then reported desktop_uid=0,
    # failed wl_display_connect, fell through to X11 and died on an
    # authorization error pointing at nothing relevant.  MEASURED 2026-09-05.
    # compose now sets create_host_path:false so it cannot recur, but a host
    # poisoned before that fix still needs the directory removed by hand.
    if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -d "$_wl_path" ] && [ ! -S "$_wl_path" ]; then
        warn "$_wl_path is a DIRECTORY, not a socket."
        warn "  An older compose created it because the real socket was missing"
        warn "  (usually WAYLAND_DISPLAY empty in the shell that ran compose)."
        warn "  It will keep failing until you remove it:  rmdir $_wl_path"
        warn "  Then re-run from a shell where WAYLAND_DISPLAY is set, or pass"
        warn "  NVKVM_DESKTOP_RUNTIME_DIR and WAYLAND_DISPLAY explicitly."
    fi
    if [ -n "${WAYLAND_DISPLAY:-}" ] \
       && [ -S "$_wl_path" ]; then
        log "auto: a Wayland socket is present; the broker will try it first"
    elif [ -n "${DISPLAY:-}" ] && [ -d /tmp/.X11-unix ]; then
        log "auto: no Wayland socket at $_wl_path, but DISPLAY is set and X11 is mounted"
        # Say this BEFORE the connect fails, not after. On X11 the mounted
        # cookie is usually not enough -- it is keyed by hostname and display,
        # and this container matches neither -- so the broker sends nothing and
        # the server answers "Authorization required, but no authorization
        # protocol specified". Measured on GNOME/X11 2026-09-05 with a valid
        # two-entry cookie, one of them already FamilyWild.
        log "  X11 note: if the broker cannot open the display, run this on the"
        log '  HOST, as the seat user, and retry:  xhost +si:localuser:$USER'
        log "  (the broker takes its uid from your X socket, so the SEAT user is"
        log "   the identity to authorise. Granting root does not help: cap_drop ALL"
        log "   leaves it without DAC_OVERRIDE for a 0775 socket.)"
    else
        die "no usable Wayland or X11 display socket was mounted"
    fi
fi

case "$BACKEND" in
    auto)
        #
        # AND THIS BRANCH HAS TO EXIST.  Making the block above stop resolving
        # auto was right -- only the broker can recover from a wrong guess --
        # but "auto" then reached a case statement that only knew wayland and
        # x11, so it fell to the catch-all and died with a message listing
        # "auto" as one of the values it accepts.  MEASURED: the broker
        # crash-looped on a freshly booted GNOME/Wayland session, printing its
        # own probe result and then rejecting it.
        #
        # Prepare BOTH environments and pass auto through: the broker tries
        # Wayland, then falls back to X11, and whichever it picks has what it
        # needs already exported.
        #
        # Only advertise Wayland if a SOCKET is really there.  compose always
        # sets WAYLAND_DISPLAY (it defaults to wayland-0), so its mere presence
        # proves nothing; on an X11 host the path is the /dev/null `make up`
        # bound.  Exporting it anyway sent the broker into a wl_display_connect
        # that could not succeed, and the X11 fallback it then took was logged
        # as a Wayland failure -- the wrong thing to go read about.
        if [ -n "${WAYLAND_DISPLAY:-}" ] \
           && [ -S "$RUNTIME_DIR/${WAYLAND_DISPLAY##*/}" ]; then
            export XDG_RUNTIME_DIR="$RUNTIME_DIR"
            export WAYLAND_DISPLAY="${WAYLAND_DISPLAY##*/}"
        else
            unset WAYLAND_DISPLAY
        fi
        if [ -s /run/host-xauthority ]; then
            export XAUTHORITY=/run/host-xauthority
        else
            unset XAUTHORITY
        fi
        ;;
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
# Default consent, not off: this image is only ever run against the vmm
# container, which supplies the qemu-vdagent chardev and a guest with
# spice-vdagent installed.  The broker binary itself still defaults to off,
# because a hand-rolled QEMU has no transport until you add one.
# Resolve the default ONCE into a local, and pass the LOCAL on.  The case head
# defaulted but the body passed the bare variable, so the two disagreed exactly
# when they mattered: unset aborted the script outright under `set -u` (no exec,
# no broker), and NVKVM_BROKER_CLIPBOARD= took the `consent` branch and then
# handed the broker --clipboard "".  MEASURED 2026-09-05 running this entrypoint
# outside compose, which is the only reason it stayed hidden -- compose always
# sets the variable, so nothing here was reachable through `make up` alone.
clipboard="${NVKVM_BROKER_CLIPBOARD:-consent}"
case "$clipboard" in
    off)                       ;;
    guest-to-host|consent)     extra+=(--clipboard "$clipboard") ;;
    *) die "NVKVM_BROKER_CLIPBOARD must be off, guest-to-host or consent" ;;
esac
# Which keys mean "paste".  The broker validates the list itself and refuses to
# start on a bad one, so this only has to decide whether to pass it at all.
[ -n "${NVKVM_BROKER_CLIPBOARD_TRIGGER:-}" ] \
    && extra+=(--clipboard-trigger "$NVKVM_BROKER_CLIPBOARD_TRIGGER")

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
