#!/bin/bash
# nvkvm-ota.sh — re-provision the OTHER slot after a SteamOS A/B update.
#
# WHY THIS EXISTS.  nvkvm's guest module is out-of-tree and lives in the rootfs.
# An A/B update writes a whole new rootfs into the inactive slot, so everything
# nvkvm installed is absent from it: no module, no in-image stub, and -- the
# part that makes the failure silent -- no
# /etc/systemd/system/multi-user.target.wants/nvkvm-boot.service, because that
# directory belongs to the rootfs the update replaced.  The unit FILE survives
# (it is in /etc), which makes it look installed while nothing runs.
#
# MEASURED on 2026-08-28: after an OTA the guest booted the new slot with no
# nvkvm module, no /dev/dri, and ZERO nvkvm lines in that boot's journal.
# Nothing failed -- nothing was attempted.
#
# THE PROCEDURE IS NOT A SPECIAL CASE.  Provisioning a fresh install and
# provisioning a freshly written slot are the same operation on a different
# directory, so both run the SAME entry point:
#
#     steamos_boot.sh --install-only --root <target>
#
# The Alpine installer already calls exactly that (vm/guest-init.sh, provision
# stage).  This runs it against the slot the updater just wrote.  Anything that
# has to happen to a target image belongs in steamos_boot.sh, not here -- this
# script's whole job is to find the slot, mount it, and hand over.
#
# FAILURE POLICY: if provisioning fails we make the machine NOT boot that slot.
# Losing the GPU silently after an update is worse than staying where we are.
set -uo pipefail

LOG=/var/log/nvkvm-ota.log
SHARE_MNT="${NVKVM_SHARE_MNT:-/run/nvkvm}"
SHARE_TAG="${NVKVM_SHARE_TAG:-nvkvm}"

# Timestamped: this log is appended across boots, and without a clock there is
# no way to tell a failure from this boot from one three reboots ago. That cost
# real time on 2026-08-28.
log()  { printf '[nvkvm-ota] %s %s\n' "$(date -Is 2>/dev/null)" "$*" | tee -a "$LOG" >&2; }
fail() { log "ERROR: $*"; }

# The share carries steamos_boot.sh; the image deliberately holds no copy, so
# updating the logic never means touching an image.
mount_share() {
    mkdir -p "$SHARE_MNT"
    mountpoint -q "$SHARE_MNT" && return 0
    mount -t 9p -o trans=virtio,version=9p2000.L,ro "$SHARE_TAG" "$SHARE_MNT" 2>/dev/null
}

# Refuse to boot a slot we could not provision.  `boot-requested-at: 0` is how
# SteamOS's own chainloader is told an image is not a candidate.
disarm_other() {
    local this other
    this="$(steamos-bootconf this-image 2>/dev/null)" || return 0
    for other in $(steamos-bootconf list-images 2>/dev/null); do
        [ "$other" = "$this" ] && continue
        steamos-bootconf config --image "$other" --set boot-requested-at 0 >/dev/null 2>&1 \
            && log "disarmed image '$other' -- it will not be booted"
    done
}

# Everything we mount into the target, unmounted in reverse on the way out.
# A LEFTOVER MOUNT IS NOT A COSMETIC LEAK: rauc's own post-install handler
# mounts the other slot to sync the var partitions, and if we still hold it the
# whole update fails with
#     mount: /var/mnt: /dev/nvme0n1pN already mounted or mount point busy
#     Post-install handler error: Child process exited with code 32
# which is reported to the user as "Unable to download the required update",
# naming the one thing that was not wrong. OBSERVED 2026-08-28.
OTA_MOUNTS=""

ota_mount() {   # <mount args...> <target>
    local target="${@: -1}"          # the mount point is always the last arg
    if mount "$@"; then
        OTA_MOUNTS="$target $OTA_MOUNTS"   # prepend, so we unmount in reverse
        return 0
    fi
    return 1
}

ota_umount_all() {
    local m rc=0
    for m in $OTA_MOUNTS; do
        mountpoint -q "$m" || continue
        umount "$m" 2>/dev/null && continue
        # A lazy unmount detaches the tree but keeps the filesystem ALIVE until
        # every reference drops, so btrfs goes on holding the device and the
        # NEXT update cannot mount the slot rauc just rewrote. Use it only as a
        # last resort, and never quietly.
        umount -l "$m" 2>/dev/null && {
            fail "had to LAZILY unmount $m -- the slot may stay busy until reboot"
            continue
        }
        fail "could not unmount $m -- the next OS update may fail on a busy slot"
        rc=1
    done
    OTA_MOUNTS=""
    return "$rc"
}

provision_other() {
    local dev=/dev/disk/by-partsets/other/rootfs
    local mnt rc=0

    [ -e "$dev" ] || { fail "$dev does not exist -- not an A/B system?"; return 1; }
    mount_share || { fail "could not mount the nvkvm share at $SHARE_MNT"; disarm_other; return 1; }
    [ -x "$SHARE_MNT/boot/steamos_boot.sh" ] \
        || { fail "steamos_boot.sh missing from the share"; disarm_other; return 1; }

    mnt="$(mktemp -d /tmp/nvkvm-ota.XXXXXX)" || return 1
    trap 'ota_umount_all; rmdir "$mnt" 2>/dev/null' EXIT

    # subvolid=5 / subvol=/ on this platform, so the device mounts as the rootfs
    # directly and there is no subvolume to select.
    if ! ota_mount "$dev" "$mnt"; then
        fail "could not mount the other slot ($dev)"
        rmdir "$mnt"; disarm_other; return 1
    fi

    #
    # THE TARGET NEEDS A REAL SYSTEM UNDERNEATH IT.
    #
    # steamos_boot.sh chroots in to run pacman, curl and the module build. The
    # Alpine installer bind-mounts these before doing the same thing
    # (vm/guest-init.sh); omitting them here is what made the first real OTA
    # fail, with pacman reporting
    #     error: could not determine filesystem mount points
    # and the whole update then reported as a download failure.
    #
    # /home matters as much as /proc: it holds the module build area and the
    # driver cache, and a 5 GiB rootfs has room for neither.
    #
    for d in proc sys dev; do
        ota_mount -o bind "/$d" "$mnt/$d" \
            || fail "could not bind /$d into the target (the build may fail)"
    done
    mountpoint -q /home && { ota_mount -o bind /home "$mnt/home" \
        || fail "could not bind /home -- the build area falls back to the 5 GiB rootfs"; }
    #
    # A RESOLVER, OR PACMAN CANNOT REACH VALVE'S MIRRORS.
    #
    # This was `cp -f /etc/resolv.conf ... 2>/dev/null` and failed twice over:
    # the target slot is READ-ONLY at this point so the copy could not happen,
    # and the error was discarded. The visible result was provisioning dying on
    #     Could not resolve host: steamdeck-packages.steamos.cloud
    # which reads like a network fault on a machine whose network is fine.
    #
    # Copying /etc/resolv.conf would have been wrong even if it had worked: on
    # this guest it is systemd-resolved's stub (nameserver 127.0.0.53), which
    # needs a resolved that the chroot has no reason to be talking to. The REAL
    # upstream is in /run/systemd/resolve/resolv.conf -- here, QEMU's slirp
    # forwarder at 10.0.2.3.
    #
    # Bind a tmpfs file over it instead: a bind mount is a VFS operation and
    # works on a read-only filesystem, which is the same trick vm/guest-init.sh
    # uses for exactly this reason.
    #
    local resolv=/run/nvkvm-ota-resolv.conf
    if grep -h '^nameserver' /run/systemd/resolve/resolv.conf 2>/dev/null > "$resolv" \
       && [ -s "$resolv" ]; then
        :
    elif resolvectl dns 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
            | sed 's/^/nameserver /' > "$resolv" && [ -s "$resolv" ]; then
        :
    else
        # QEMU user-mode networking always forwards DNS here; see guest-init.sh.
        printf 'nameserver 10.0.2.3\n' > "$resolv"
    fi
    log "resolver for the chroot: $(tr '\n' ' ' < "$resolv")"
    ota_mount -o bind "$resolv" "$mnt/etc/resolv.conf" \
        || fail "no resolver in the target -- pacman will not reach the mirrors"

    log "provisioning the newly written slot at $mnt"
    # --install-only --root is the SAME call the Alpine installer makes. It owns
    # the read-only handling, the module build and arming the boot unit.
    "$SHARE_MNT/boot/steamos_boot.sh" --install-only --root "$mnt" >>"$LOG" 2>&1 || rc=$?

    # Belt and braces: --install-only verifies this itself and fails loudly, but
    # this is the property the whole exercise exists to guarantee, so check it
    # here too rather than trust an exit code across a chroot boundary.
    if [ ! -e "$mnt/etc/systemd/system/multi-user.target.wants/nvkvm-boot.service" ]; then
        fail "the new slot is NOT armed -- nvkvm-boot.service has no wants symlink"
        rc=1
    fi

    # UNMOUNT BEFORE RETURNING, ALWAYS. rauc is not finished with this slot.
    ota_umount_all || rc=1
    trap - EXIT
    rmdir "$mnt" 2>/dev/null

    if [ "$rc" != 0 ]; then
        fail "provisioning the new slot FAILED (rc=$rc)"
        disarm_other
        return "$rc"
    fi
    log "the new slot is provisioned and armed; it is safe to reboot into it"
    return 0
}

case "${1:-}" in
    provision-other) provision_other ;;
    *) echo "usage: $0 provision-other" >&2; exit 2 ;;
esac
