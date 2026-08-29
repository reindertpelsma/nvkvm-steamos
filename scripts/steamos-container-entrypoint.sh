#!/usr/bin/env bash
# Entrypoint for the SteamOS compose service.
#
# The durable state is split deliberately:
#   /var/lib/nvkvm-steamos  recovery image, installed qcow2, OVMF vars, SSH key
#   /data                    the read-write 9p share (public key only)
#   /run/nvkvm              host broker directory, bind-mounted as a directory
#
# QEMU is started immediately even when the broker socket is absent. The relay
# reconnects with bounded backoff and re-attaches the last frame, so waiting here
# would recreate an ordering dependency that the broker protocol removed.
set -euo pipefail

STATE_DIR="${NVKVM_STEAMOS_STATE_DIR:-/var/lib/nvkvm-steamos}"
DATA_DIR="${NVKVM_STEAMOS_DATA_DIR:-/data}"
BROKER_DIR="${NVKVM_BROKER_DIR_IN_CONTAINER:-/run/nvkvm}"
BROKER_SOCKET="${NVKVM_BROKER_SOCKET:-$BROKER_DIR/steamos.sock}"
QEMU_DISPLAY="${NVKVM_STEAMOS_QEMU_DISPLAY:-nvkvm-broker,socket=$BROKER_SOCKET}"
QCOW="${NVKVM_STEAMOS_QCOW:-$STATE_DIR/steamos.qcow2}"
# ── Artifact naming: the final name MEANS "complete and trustworthy" ─────────
# Every artifact here is written under a temporary name and renamed only once it
# is known to be complete.  The recovery .img.bz2 and the decompressed .img
# already followed that rule (curl -C - into .part, bzip2 into .part, mv on
# success).  The installed qcow2 did NOT, and that was the whole bug: cancel an
# install halfway and a large, non-empty, unbootable steamos.qcow2 was left
# behind, which `[ ! -s "$QCOW" ]` then read as "already installed" -- so the
# next start neither installed nor booted anything.
#
# The two names carry the entire contract:
#
#   $QCOW_INSTALLING  provably holds no user data, because only a COMPLETED
#                     install is ever given the other name.  Deleting it is
#                     always safe, so an interrupted install just starts over.
#   $QCOW             may hold the user's games and saves.  It is NEVER removed
#                     or overwritten automatically -- not even when it is
#                     corrupt.  Replacing that file is an operator decision.
QCOW_INSTALLING="$QCOW.installing"
# NOT an -oobe- image.  The OOBE images install VARIANT_ID=steamdeck-oobe, whose
# steam-jupiter-oobe package ships a /usr/bin/steam that runs
#     rm -rf --one-file-system "$HOME"/.steam "$HOME"/.local/share/Steam
# UNCONDITIONALLY on every launch -- "we want to always start with a fresh steam
# per boot as we lack the proper steam overlay/repair code", says its own
# comment.  On a real Deck that variant survives only until the first OTA
# graduates it to `steamdeck`; used as a daily driver it destroys the user's
# login, library index and installed games on every single Steam start.
# MEASURED 2026-08-28: caught in the act, `rm -rf` with the launcher as parent.
#
# The plain steamdeck-repair images install VARIANT_ID=steamdeck directly, with
# steam-jupiter-stable and no such wrapper.  They are an older base (3.7.7 vs
# 3.8.14) and update themselves forward, which is the normal path.
# Valve's official download button serves the -oobe- image, so that is what
# users already have and what stays current (3.8.14 vs the plain family's 3.7.7
# from May 2025, which Valve appears to have stopped republishing).  Its
# /usr/bin/steam wipes ~/.steam and ~/.local/share/Steam on EVERY launch --
# steamos_boot.sh detects that and disables it, and the fix self-retires once an
# OTA graduates the guest to VARIANT_ID=steamdeck.  Pinning the official image
# rather than a legacy artifact means we do not depend on a file Valve may
# remove.
PINNED_RECOVERY="steamdeck-oobe-repair-20260707.10-3.8.14.img.bz2"
RECOVERY_BASE="https://steamdeck-images.steamos.cloud/recovery"
PINNED=0
INSTALL_SHELL=0
QEMU_EXTRA=()

log() { printf '[steamos-container] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --pinned)       PINNED=1; shift ;;
        --latest)       PINNED=0; shift ;;
        --setup-shell)  INSTALL_SHELL=1; shift ;;
        --)             shift; QEMU_EXTRA+=("$@"); break ;;
        *)              QEMU_EXTRA+=("$1"); shift ;;
    esac
done

require_mount() {
    mountpoint -q "$1" || die "$1 is not a mount point. Refusing to put durable VM state in the container layer."
}

# Keep the private key off the guest-visible share. Only its public half crosses
# 9p; nvkvm-steamos-ssh reads the private half from the state volume. The same
# key is installed for both the interactive user and root: anyone controlling
# this container can already read and alter the VM disk and running QEMU state.
ensure_ssh_key() {
    local private="$STATE_DIR/ssh/id_ed25519" public_tmp="$DATA_DIR/.authorized_keys.tmp"
    local root_tmp="$DATA_DIR/.root_authorized_keys.tmp"
    if [ -s "$DATA_DIR/authorized_keys" ]; then
        log "SSH: using existing /data/authorized_keys"
        if [ ! -s "$DATA_DIR/root_authorized_keys" ]; then
            cp -f "$DATA_DIR/authorized_keys" "$root_tmp"
            chmod 0644 "$root_tmp"
            mv -f "$root_tmp" "$DATA_DIR/root_authorized_keys"
            log "SSH: mirrored the public key for direct root access"
        fi
        return 0
    fi
    if [ ! -s "$private" ]; then
        log "SSH: generating a persistent Ed25519 key in the state volume"
        ssh-keygen -q -t ed25519 -N '' -C nvkvm-steamos -f "$private"
    fi
    ssh-keygen -y -f "$private" > "$public_tmp"
    chmod 0644 "$public_tmp"
    mv -f "$public_tmp" "$DATA_DIR/authorized_keys"
    cp -f "$DATA_DIR/authorized_keys" "$root_tmp"
    chmod 0644 "$root_tmp"
    mv -f "$root_tmp" "$DATA_DIR/root_authorized_keys"
    log "SSH: public key written for the interactive user and root; password login remains disabled"
}

# Valve publishes a STABLE ALIAS that 302s to the current image, so we do not
# parse their directory listing.  Scraping HTML made every fresh install depend
# on the page's shape; this depends only on a URL Valve's own download page uses.
#
# Note the alias is spelled `steamdeck-repair-latest` with no `-oobe-`, yet it
# resolves to the -oobe- image (verified 2026-08-28:
#   steamdeck-repair-latest.img.bz2 -> steamdeck-oobe-repair-20260707.10-3.8.14.img.bz2
#   steamdeck-oobe-repair-latest.img.bz2 -> 404
# ).  That is independent confirmation that the OOBE image simply IS the current
# official one, not a variant we picked by mistake.
LATEST_ALIAS="steamdeck-repair-latest.img.bz2"

latest_recovery_url() {
    local resolved
    # -I: headers only, so resolving costs nothing.  We want the FINAL url, both
    # to name the cache file after the real version and so the log records which
    # image an install actually used.
    resolved="$(curl -fsIL -o /dev/null -w '%{url_effective}' \
                     "$RECOVERY_BASE/$LATEST_ALIAS" 2>/dev/null)" || resolved=""
    case "$resolved" in
        *-repair-*.img.bz2) printf '%s\n' "$resolved" ;;
        *)  # The alias is the one thing we depend on; if it moves, fall back to
            # the pin rather than failing an install.  The pin is a known-good
            # floor, not the intended version.
            warn "latest-image alias did not resolve to an .img.bz2 (got '${resolved:-nothing}')"
            warn "  falling back to the pinned image: $PINNED_RECOVERY"
            printf '%s/%s\n' "$RECOVERY_BASE" "$PINNED_RECOVERY" ;;
    esac
}

# WHAT THIS CHECKSUM IS, AND WHAT IT IS NOT.
#
# Valve publishes NO checksum next to the recovery images -- probed 2026-08-29,
# both .sha256 and .sha256sum next to steamdeck-oobe-repair-20260707.10-3.8.14.img.bz2
# return 404, while the image itself is 200. There is therefore nothing upstream
# to verify against, and the recorded hash below is trust-on-first-use: it is
# OUR hash of OUR first download.
#
# So it detects a torn or truncated cache and local tampering after the fact,
# and it detects NOTHING about whether the image Valve served was the right one.
# Naming that here matters more than the code does: the function used to be read
# as "the recovery image is verified", and a reader who believes that stops
# asking where the anchor is.
#
# NVKVM_STEAMOS_RECOVERY_SHA256 is the anchor for anyone who wants one. Set it
# to a digest obtained out of band and this fails closed against that instead of
# against its own memory. It is checked BEFORE the recorded hash, so a pinned
# digest cannot be satisfied by a cache poisoned earlier.
record_or_verify_checksum() {
    local archive="$1" dir base sumfile got
    dir="$(dirname "$archive")"; base="$(basename "$archive")"; sumfile="$archive.sha256"

    if [ -n "${NVKVM_STEAMOS_RECOVERY_SHA256:-}" ]; then
        got="$(sha256sum "$archive" | cut -d' ' -f1)"
        [ "$got" = "$NVKVM_STEAMOS_RECOVERY_SHA256" ] \
            || die "recovery image digest does not match NVKVM_STEAMOS_RECOVERY_SHA256: got $got"
        log "recovery image matches the pinned digest"
        printf '%s  %s\n' "$got" "$base" > "$sumfile"
        return 0
    fi

    if [ -s "$sumfile" ]; then
        # prepare_recovery is used in a command substitution. sha256sum -c
        # normally prints "<archive>: OK" on stdout; suppress that diagnostic
        # so the substitution contains exactly the raw image path on both the
        # first run and every restart.
        (cd "$dir" && sha256sum -c "$(basename "$sumfile")" >/dev/null) \
            || die "checksum mismatch for $archive; it was not re-fetched automatically"
    else
        (cd "$dir" && sha256sum "$base" > "$(basename "$sumfile").tmp")
        mv -f "$sumfile.tmp" "$sumfile"
        log "recorded SHA-256 in $sumfile (trust-on-first-use: Valve publishes none;"
        log "  set NVKVM_STEAMOS_RECOVERY_SHA256 to verify against a digest you trust)"
    fi
}

prepare_recovery() {
    local url filename archive raw
    # LATEST BY DEFAULT.  A pin rots, and the rot is fatal rather than cosmetic:
    # SteamOS 3.7.7 (May 2025) installs fine but provisioning cannot build the
    # guest module on it, because pacman keyring init fails and its kernel's
    # headers are no longer served.  MEASURED 2026-08-28 -- fourteen identical
    # failures.  A pinned image left alone becomes that in about a year.
    if [ -n "${NVKVM_STEAMOS_RECOVERY_URL:-}" ]; then
        url="$NVKVM_STEAMOS_RECOVERY_URL"
        log "using recovery URL from the environment: ${url##*/}"
    elif [ "$PINNED" = 1 ] || [ "${NVKVM_STEAMOS_PINNED:-0}" = 1 ]; then
        url="$RECOVERY_BASE/$PINNED_RECOVERY"
        log "using pinned recovery: ${url##*/}"
    else
        url="$(latest_recovery_url)"
        log "latest recovery image: ${url##*/}"
    fi
    filename="${url##*/}"; filename="${filename%%\?*}"
    case "$filename" in *.img.bz2) ;; *) die "recovery URL must name an .img.bz2: $url" ;; esac
    archive="$STATE_DIR/recovery/$filename"
    raw="${archive%.bz2}"

    if [ ! -s "$archive" ]; then
        log "downloading SteamOS recovery (large, resumable): $url"
        curl -fL --retry 3 --retry-all-errors -C - -o "$archive.part" "$url" \
            || die "recovery download failed; the .part file was kept for resume"
        mv -f "$archive.part" "$archive"
    fi
    record_or_verify_checksum "$archive"

    if [ ! -s "$raw" ]; then
        log "decompressing $(basename "$archive")"
        bzip2 -dc "$archive" > "$raw.part" \
            || die "recovery decompression failed"
        mv -f "$raw.part" "$raw"
    fi
    printf '%s\n' "$raw"
}

container_driver_version() {
    awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+/) {print $i; exit}}' \
        /proc/driver/nvidia/version 2>/dev/null
}

# Tests source the functions above without requiring KVM or mounted Compose
# volumes. Production execution never sets this variable.
if [ "${NVKVM_STEAMOS_ENTRYPOINT_SOURCE_ONLY:-0}" = 1 ]; then
    return 0 2>/dev/null || exit 0
fi

[ -c /dev/kvm ] || die "/dev/kvm is absent (Compose must grant the device)."
[ -r /dev/kvm ] && [ -w /dev/kvm ] \
    || die "/dev/kvm is not usable. Set NVKVM_KVM_GID to: stat -c %g /dev/kvm"

# The guest's DRM node is a PROXY. nvkvm_drm_open() forwards to the host's DRM
# render node and returns its errno verbatim, so if this container cannot see
# /dev/dri the guest gets -ENOENT from open("/dev/dri/card0") -- while stat(2),
# /proc/devices, /sys/class/drm and the module's own probe all look perfect.
#
# MEASURED on a vast.ai KVM box: every compositor died on
#     kwin_core: Failed to open /dev/dri/card0 device (No such file or directory)
# with the node plainly present at 226:0, and a module reload reproduced it on
# fresh nodes. The host had /dev/dri and nvidia_drm modeset=Y; only the
# container lacked it. Diagnosing that from inside the guest costs hours,
# because nothing in the guest is wrong.
#
# Compose already requests the `graphics` and `display` capabilities, which is
# supposed to make the NVIDIA container runtime inject these nodes. It does not
# on every toolkit/CDI configuration, so say so plainly instead of letting the
# failure surface three layers away. Not fatal: the VM still boots and is
# reachable over ssh, which is exactly how you would go fix it.
if [ ! -e /dev/dri/renderD128 ] && [ ! -e /dev/dri/card0 ]; then
    log "WARNING: no /dev/dri in this container. The guest's DRM node is a proxy"
    log "WARNING: for the host's, so EVERY open of /dev/dri/card0 in the guest will"
    log "WARNING: fail with ENOENT and no compositor can start -- even though the"
    log "WARNING: guest module probes fine and the node looks correct."
    log "WARNING: The NVIDIA container runtime is meant to inject it from the"
    log "WARNING: graphics/display capabilities; it did not here. Remedy:"
    log "WARNING:   docker compose -f docker-compose.yml -f override-dri.yml up -d"
    log "WARNING: (or add '- /dev/dri:/dev/dri' to the vmm service's devices)."
fi
require_mount "$STATE_DIR"
require_mount "$DATA_DIR"
require_mount "$BROKER_DIR"
mkdir -p "$STATE_DIR/recovery" "$STATE_DIR/alpine" "$STATE_DIR/ssh"
chmod 0700 "$STATE_DIR/ssh"
# $DATA_DIR's mode is LEFT ALONE. This used to be `chmod 0777`, and nothing
# needed it: the only writer inside this container is QEMU, which runs as uid 0
# here, and the 9p export is security_model=mapped-xattr, so guest ownership
# lives in xattrs and never depends on the host directory being world-writable.
# What 0777 did do is widen a directory that is DOCUMENTED as a host path --
# `NVKVM_STEAMOS_DATA=/absolute/host/path` in docker-compose.yml -- to
# world-writable on the host, and that directory holds the SSH authorized_keys
# for the guest's interactive user and for root. Any local user could then
# replace them. A bind mount already arrives with the mode its owner chose,
# which is the mode they meant.
[ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"

ensure_ssh_key
export PATH="/opt/qemu-nvkvm/bin:$PATH"

if [ "$INSTALL_SHELL" = 1 ]; then
    RECOVERY_IMG="$(prepare_recovery)"
    exec /opt/nvkvm/install_steamos_vm.sh \
        --repair "$RECOVERY_IMG" --out "$QCOW_INSTALLING" \
        --alpine-dir "$STATE_DIR/alpine" --share /opt/nvkvm --shell
fi

# A zero-length final name is the fingerprint of the pre-.installing crash this
# scheme exists to prevent.  It provably holds nothing, so removing it is the
# same argument that makes $QCOW_INSTALLING safe -- and it spares the operator a
# manual step for a file that cannot contain anything of theirs.  A NON-empty
# but corrupt image is the opposite case and is left strictly alone below.
if [ -e "$QCOW" ] && [ ! -s "$QCOW" ]; then
    log "removing a zero-length $(basename "$QCOW") -- it can hold no data -- and installing"
    rm -f "$QCOW"
fi

# ── Disk size: games live on /home, so 64G is a games budget, not a disk ─────
# Valve's installer needs ~11 GiB and expands /home into everything left, so
# this number IS the games partition.  qcow2 is sparse: a larger virtual size
# costs nothing until it is written, and the cost of getting it wrong is
# asymmetric -- too big is free, too small means reinstalling to grow it, since
# /home sits last on the disk behind two fixed 5 GiB rootfs slots.
#
# Unset means "fit the host": take a share of what is actually free where the
# qcow2 lives, clamped so a small host still gets a usable machine and a huge
# one does not get a number nobody can honour.  Set NVKVM_STEAMOS_DISK_SIZE to
# pin it.
#
# NOT a host share for /home, which is the obvious alternative: SteamOS creates
# /home as ext4 with the `casefold` feature and Proton depends on it for
# case-insensitive Windows paths.  No 9p or virtiofs export can provide
# casefold, so games would break in ways that look like game bugs.
default_disk_size() {
    local free_g
    free_g="$(df -PBG "$STATE_DIR" 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}')"
    case "$free_g" in ''|*[!0-9]*) printf '128G\n'; return ;; esac
    local want=$(( free_g * 60 / 100 ))
    [ "$want" -lt 64 ]  && want=64
    [ "$want" -gt 1024 ] && want=1024
    printf '%sG\n' "$want"
}
DISK_SIZE="${NVKVM_STEAMOS_DISK_SIZE:-$(default_disk_size)}"

if [ ! -e "$QCOW" ]; then
    if [ -e "$QCOW_INSTALLING" ]; then
        log "a previous install was interrupted; restarting it from the beginning"
        log "(only a completed install is given the final name, so nothing is lost)"
        rm -f "$QCOW_INSTALLING"
    fi
    # Resumable, and a completed .img.bz2/.img is reused rather than re-fetched.
    RECOVERY_IMG="$(prepare_recovery)"
    DRIVER_VERSION="$(container_driver_version)"
    [[ "$DRIVER_VERSION" =~ ^[0-9]+([.][0-9]+)+$ ]] \
        || die "could not determine the NVIDIA driver version exposed to this container"
    log "first run: installing a dual-slot SteamOS image with Valve's installer"
    log "disk: $DISK_SIZE (sparse; ~11 GiB is the OS, the rest becomes /home for games)"
    log "provisioning NVIDIA userspace for dynamically detected driver $DRIVER_VERSION"
    /opt/nvkvm/install_steamos_vm.sh \
        --repair "$RECOVERY_IMG" \
        --out "$QCOW_INSTALLING" \
        --size "$DISK_SIZE" \
        --alpine-dir "$STATE_DIR/alpine" \
        --stages "${NVKVM_STEAMOS_INSTALL_STAGES:-repair,provision}" \
        --share /opt/nvkvm \
        --profile "${NVKVM_STEAMOS_PROFILE:-steamos}" \
        --driver-version "$DRIVER_VERSION" \
        --memory "${NVKVM_INSTALL_MEMORY_MB:-4096}" \
        --cpus "${NVKVM_INSTALL_CPUS:-4}" \
        --log "$STATE_DIR/install.log"

    # Promote only what qemu-img is willing to read back as a qcow2.  The
    # installer's exit status says the run finished; this says the artifact
    # survived it.  Cheap (a header read), unlike a full `qemu-img check`.
    qemu-img info --output=json "$QCOW_INSTALLING" >/dev/null 2>&1 \
        || die "the installer finished but $QCOW_INSTALLING is not a readable qcow2; not promoting it"
    sync
    mv -f "$QCOW_INSTALLING" "$QCOW"
    sync
    # A NEW DISK MEANS A NEW HOST KEY.  Whatever sshd identity the old image
    # had is gone, so a leftover known_hosts entry makes every
    # `nvkvm-steamos-ssh` fail with "Host key verification failed" -- which
    # reads as a compromised host rather than the reinstall it actually is.
    # Drop the entry here, where we know the disk was just replaced, instead of
    # weakening the check at connect time.
    if [ -f "$STATE_DIR/ssh/known_hosts" ]; then
        ssh-keygen -f "$STATE_DIR/ssh/known_hosts" \
                   -R "[127.0.0.1]:${NVKVM_STEAMOS_SSH_PORT:-15022}" >/dev/null 2>&1 || true
    fi
    log "install complete -- promoted to $(basename "$QCOW")"
fi

OVMF_CODE="${NVKVM_OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_TEMPLATE="${NVKVM_OVMF_VARS_TEMPLATE:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
OVMF_VARS="$STATE_DIR/OVMF_VARS.fd"
[ -f "$OVMF_CODE" ] || die "OVMF code not found at $OVMF_CODE"
if [ ! -f "$OVMF_VARS" ]; then
    install -m 0600 "$OVMF_TEMPLATE" "$OVMF_VARS"
fi

# ── Serial console: one chardev, three consumers ────────────────────────────
# It used to be `-serial file:`, which is write-only.  That is why `docker
# compose up -d` streamed nothing and why there was no way to type at the guest
# outside SSH -- precisely when you most need one, i.e. when SSH is what is
# broken.
#
# A socket chardev with logfile= serves all three needs from one device:
#   serial.sock  interactive, both directions   -> nvkvm-steamos-serial (socat)
#   serial.log   durable, survives the VM       -> post-mortem
#   stdout       live                           -> docker logs / compose up
# The last one is the `tail -F` below: this script exec()s QEMU, so it cannot
# also copy the log, and a background reader started first is the simplest
# thing that keeps `docker logs` working.  -F (not -f) so it does not matter
# that the file does not exist yet.
# ── Clipboard transport is OPTIONAL and must never block the boot ────────────
# The qemu-vdagent chardev only exists when QEMU was built against
# spice-protocol.  A build without it used to be fatal here -- QEMU exited with
# "'qemu-vdagent' is not a valid char driver name" and the VM never started, so
# an optional convenience took the whole guest down with it.  Probe instead, and
# say plainly which of the two states we are in.
VDAGENT_ARGS=()
if /opt/qemu-nvkvm/bin/qemu-system-x86_64 -chardev help 2>&1 | grep -qw qemu-vdagent; then
    VDAGENT_ARGS=(
        # mouse=off on purpose: pointer input already has a path through the
        # broker, and a second injector is how you get two cursors.
        -device "virtio-serial-pci,id=nvkvm-vser"
        -chardev "qemu-vdagent,id=nvkvm-vdagent,name=vdagent,clipboard=on,mouse=off"
        -device "virtserialport,bus=nvkvm-vser.0,chardev=nvkvm-vdagent,name=com.redhat.spice.0"
    )
    log "clipboard: vdagent transport present (guest still needs spice-vdagent)"
else
    log "clipboard: this QEMU has no qemu-vdagent chardev (built without spice-protocol)"
    log "clipboard: booting WITHOUT clipboard support; nothing else is affected"
fi

# ── audio: write into the broker's fifo, and nothing else ───────────────────
# The only audio privilege the untrusted VMM gets is a file descriptor it can
# WRITE.  No host audio socket is mounted here and none is needed: the trusted
# broker container owns the connection to the host and plays what arrives.
#
# `wav` is a stock QEMU audiodev and needs no extra library in the build --
# QEMU's own audio backends (pipewire, pulse, alsa) are not compiled in, and
# adding one would mean handing this container a host audio socket anyway,
# which is the thing being avoided.  A fifo cannot be read from this side, so
# the direction is a property of the plumbing rather than of a policy.
AUDIO_ARGS=()
# In a subdirectory because fs.protected_fifos refuses O_WRONLY on a fifo this
# container does not own inside the sticky world-writable volume root.
AUDIO_FIFO="${NVKVM_AUDIO_FIFO:-$BROKER_DIR/audio/pcm}"
if [ "${NVKVM_AUDIO:-1}" = 1 ] && [ -p "$AUDIO_FIFO" ]; then
    AUDIO_ARGS=(
        -audiodev "wav,id=nvkvmsnd,path=$AUDIO_FIFO,out.frequency=${NVKVM_AUDIO_RATE:-48000},out.channels=${NVKVM_AUDIO_CHANNELS:-2},out.format=${NVKVM_AUDIO_QEMU_FORMAT:-s16}"
        # ich9-intel-hda, not virtio-sound.  MEASURED: with virtio-sound the
        # guest saw the card and then timed out on every stream ("Stream
        # error: Timeout"), and NOTHING was ever written to the fifo -- the
        # device never completed a period against this backend.  HDA is the
        # path QEMU has shipped for a decade and every guest already has a
        # driver for.
        -device "ich9-intel-hda,id=nvkvmhda"
        -device "hda-output,bus=nvkvmhda.0,audiodev=nvkvmsnd"
    )
    log "audio: intel-hda -> $AUDIO_FIFO (playback only; the broker plays it)"
else
    log "audio: none ($AUDIO_FIFO is not a fifo, or NVKVM_AUDIO=0)"
fi

SERIAL_SOCK="$STATE_DIR/serial.sock"
SERIAL_LOG="$STATE_DIR/serial.log"
rm -f "$STATE_DIR/qmp.sock" "$SERIAL_SOCK"
: > "$SERIAL_LOG.new" && mv -f "$SERIAL_LOG.new" "$SERIAL_LOG" 2>/dev/null || true
tail -n +1 -F "$SERIAL_LOG" 2>/dev/null &
log "serial: live on stdout, logged to $SERIAL_LOG, interactive on $SERIAL_SOCK"
log "serial: attach with  docker compose exec ${NVKVM_COMPOSE_SERVICE:-vmm} nvkvm-steamos-serial"
log "booting SteamOS now; broker presence is not an ordering requirement"
log "display socket: $BROKER_SOCKET"
log "QEMU display backend: $QEMU_DISPLAY"
log "SSH after provisioning: docker compose exec vmm nvkvm-steamos-ssh"

# ── Shutdown: the guest must be powered down, not shot ───────────────────────
# This used to exec() QEMU, so `docker stop` -- and therefore every
# `compose stop`, `restart` and `up --force-recreate` -- delivered SIGTERM
# straight to QEMU, which exits on the spot.  The guest was never once shut
# down cleanly, and ext4's delayed allocation then discarded whatever it had
# not yet flushed.  MEASURED here three times, each looking like a different
# bug: systemd units planted as 0 bytes (which systemd reports as "masked"),
# a 0-byte log, and finally an entire pacman-installed package -- binaries and
# all -- left as 0-byte files with their metadata intact.
#
# So: run QEMU as a child, and on SIGTERM ask the guest to power down over QMP
# and WAIT for it.  Compose already allows this (stop_grace_period: 2m); only
# the exec() stood in the way.
SHUTDOWN_WAIT="${NVKVM_STEAMOS_SHUTDOWN_WAIT:-90}"
QEMU_PID=""
wait_for_qemu() {   # <seconds>
    local n=0
    while kill -0 "$QEMU_PID" 2>/dev/null && [ "$n" -lt "$1" ]; do
        sleep 1; n=$((n + 1))
    done
    kill -0 "$QEMU_PID" 2>/dev/null && return 1 || return 0
}

on_term() {
    [ -n "$QEMU_PID" ] || exit 0

    # SSH FIRST, ACPI SECOND.  MEASURED: `system_powerdown` alone sat for the
    # full 90 s and the guest never went down -- on a SteamOS desktop the power
    # button is grabbed by the session (KDE puts up a dialog nobody is there to
    # answer), so the ACPI event politely asks a human.  `systemctl poweroff`
    # asks the init system instead, which is the thing that actually unmounts.
    # ACPI stays as the fallback for a guest that has no SSH yet -- an install,
    # an initramfs, a boot that did not get that far.
    local key="$STATE_DIR/ssh/id_ed25519"
    if [ -r "$key" ]; then
        log "shutdown: asking the guest to power down over SSH"
        timeout 15 ssh -i "$key" -p "${NVKVM_STEAMOS_SSH_PORT:-15022}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 -o BatchMode=yes \
            "${NVKVM_STEAMOS_SSH_USER:-root}@127.0.0.1" \
            'systemctl poweroff' >/dev/null 2>&1 || true
        if wait_for_qemu "$SHUTDOWN_WAIT"; then
            log "shutdown: guest powered down cleanly"
            return
        fi
    fi

    log "shutdown: falling back to ACPI power button"
    printf '{"execute":"qmp_capabilities"}\n{"execute":"system_powerdown"}\n' \
        | timeout 5 socat - "unix-connect:$STATE_DIR/qmp.sock" >/dev/null 2>&1 \
        || log "shutdown: QMP unreachable"
    if wait_for_qemu 20; then
        log "shutdown: guest powered down cleanly"
        return
    fi
    log "shutdown: guest did not stop -- terminating QEMU (writes may be lost)"
    kill -TERM "$QEMU_PID" 2>/dev/null || true
}
trap on_term TERM INT

# Per-second present statistics: OFF unless asked for.  This prints one line
# every second for the life of the VM, straight into `docker compose` output,
# which buries everything else in a long run.  Set NVKVM_PRESENT_TIMING=1 to
# get it back while debugging the present path.
# NOT `[ -n ... ] && export`: this script runs under `set -e`, so a bare test
# that is false IS a failing command and would abort the entrypoint on the
# common path -- the one where the variable is unset.
if [ -n "${NVKVM_PRESENT_TIMING:-}" ]; then
    export NVKVM_PRESENT_TIMING
fi
# Frame accounting across the relay: produced at the ingress vs forwarded to the
# broker, one line per N guest frames.  OFF unless asked for, and for the same
# reason -- it logs at the guest's flip rate.  Same `if` rather than `[ ] &&`,
# under `set -e`.
if [ -n "${NVKVM_RELAY_FRAME_STATS:-}" ]; then
    export NVKVM_RELAY_FRAME_STATS
fi
# The $DATA_DIR share below is mapped-xattr, NOT passthrough.  passthrough writes
# the guest's uid/gid and MODE straight through to the host, and this QEMU runs as
# uid 0.  With the documented NVKVM_STEAMOS_DATA=/absolute/host/path the share is a
# user directory, so a guest that drops a `-rwsr-xr-x root` binary there leaves a
# host escalation waiting for whoever runs it.  CAP_MKNOD is dropped so device
# nodes are unreachable, but setting a setuid bit on a file you own needs no
# capability.  mapped-xattr keeps guest ownership and mode in xattrs, so nothing
# host-visible is really setuid.
#
# NVKVM_QEMU_NICE=N -- run QEMU at a lower CPU priority. UNSET by default, so
# the default behaviour is unchanged.
#
# A VM doing something heavy saturates the host: a SteamOS OTA runs `desync`
# with 112 download threads, which twice made an 8-core laptop unusable while
# the guest was merely updating. `nice -n 10` keeps the host desktop
# interactive at no meaningful cost to a download.
#
# BUT IT RENICES THE vCPU THREADS TOO, not just I/O, so it perturbs present
# latency. Leave it unset when measuring anything about frame timing, or the
# nice level is part of what is being measured.
#
# Deliberately not defaulted on: "the VM is slow" is a much harder thing to
# debug than "my browser stutters during an install".
# Exported, not just set: install_steamos_vm.sh is a CHILD of this script and
# runs the heaviest QEMU of all, so it has to see the same setting.
export NVKVM_QEMU_NICE="${NVKVM_QEMU_NICE:-}"
_nice=()
if [ -n "$NVKVM_QEMU_NICE" ]; then
    if command -v nice >/dev/null 2>&1; then
        _nice=(nice -n "$NVKVM_QEMU_NICE")
        log "running QEMU at nice +$NVKVM_QEMU_NICE (host stays responsive; vCPUs are niced too)"
    else
        warn "NVKVM_QEMU_NICE=$NVKVM_QEMU_NICE but nice(1) is not installed; ignoring"
    fi
fi

# Keep comments OUT of the continued argument list below.  A `\`-continued line
# followed by a `#` line ENDS the command there, and every later argument --
# -display included -- is silently dropped: QEMU still starts, so nothing fails
# loudly.  That is exactly what happened when this rationale lived inline.
# Enforced by tests/no_comment_in_continuation.sh.
"${_nice[@]}" /opt/qemu-nvkvm/bin/qemu-system-x86_64 \
    -name nvkvm-steamos \
    -machine q35,accel=kvm -cpu host \
    -m "${VM_MEM:-12G}" -smp "${VM_SMP:-8}" \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,unit=1,file=$OVMF_VARS" \
    -drive "file=$QCOW,format=qcow2,if=none,id=nvm0" \
    -device nvme,drive=nvm0,serial=nvkvmsteamos \
    -netdev "user,id=net0,hostfwd=tcp::${NVKVM_STEAMOS_SSH_PORT:-15022}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -vga none \
    -device virtio-nvgpu-pci-non-transitional,id=nvkvm0 \
    -device nvkvm-gpu,addr=7 \
    -virtfs local,path=/opt/nvkvm,mount_tag=nvkvm,security_model=none,readonly=on \
    -virtfs "local,path=$DATA_DIR,mount_tag=data,security_model=mapped-xattr" \
    -fw_cfg opt/ovmf/X-PciMmio64Mb,string=262144 \
    -device virtio-keyboard-pci -device virtio-tablet-pci -device virtio-mouse-pci \
    "${VDAGENT_ARGS[@]}" \
    "${AUDIO_ARGS[@]}" \
    -qmp "unix:$STATE_DIR/qmp.sock,server=on,wait=off" \
    -chardev "socket,id=nvkvm-serial,path=$SERIAL_SOCK,server=on,wait=off,logfile=$SERIAL_LOG,logappend=on" \
    -serial chardev:nvkvm-serial \
    -monitor none \
    -display "$QEMU_DISPLAY" \
    "${QEMU_EXTRA[@]}" &
QEMU_PID=$!
# `wait` returns as soon as a trapped signal arrives, with QEMU still running,
# so keep waiting until the child is genuinely gone.
rc=0
while kill -0 "$QEMU_PID" 2>/dev/null; do
    wait "$QEMU_PID"; rc=$?
done
log "QEMU exited with status $rc"
exit "$rc"
