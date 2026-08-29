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
        # `list-images` is NOT a list of bootable slots.  MEASURED on a real
        # OTA (2026-08-29): it returned
        #     B dev Desktop Documents Downloads Music Pictures Public Templates Videos A
        # -- the XDG directories of /home/deck, straight through.  `--set` does
        # not validate the name either, so the loop happily wrote
        # /esp/SteamOS/conf/Desktop.conf and friends, MANUFACTURING nine bogus
        # images that then appear in every later `list-images`.  That is not
        # cosmetic: SteamOS's own chainloader picks from those entries, and it
        # is why `steamos-bootconf set-mode reboot-other` once selected an image
        # called 'dev' and left the machine unbootable.
        #
        # A real slot is one with a rootfs partset. Nothing else may be touched,
        # least of all created.
        [ -e "/dev/disk/by-partsets/$other/rootfs" ] || {
            log "skipping '$other' -- not a boot slot (no rootfs partset)"
            continue
        }
        steamos-bootconf config --image "$other" --set boot-requested-at 0 >/dev/null 2>&1 \
            && log "disarmed image '$other' -- it will not be booted"
    done
}

# What WE mount is only the image's own filesystems: the slot itself, and the
# /home it shares. The execution environment inside that root -- /proc, /sys,
# /dev, a resolver -- is steamos_boot.sh's job, because every entry point needs
# it and a second implementation of it got the same three things wrong three
# times in a row. See chroot_setup() there.
#
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
        # Try hard before resorting to lazy: -R takes submounts, and a short
        # retry covers a process on its way out. A lazy unmount here is what
        # breaks rauc's post-install handler and therefore the whole update.
        _i=0
        while [ "$_i" -lt 5 ]; do
            mountpoint -q "$m" || break
            umount -R "$m" 2>/dev/null && break
            umount "$m" 2>/dev/null && break
            _i=$((_i + 1)); sleep 1
        done
        mountpoint -q "$m" || continue
        # A lazy unmount detaches the tree but keeps the filesystem ALIVE until
        # every reference drops, so btrfs goes on holding the device and the
        # NEXT update cannot mount the slot rauc just rewrote. Last resort, and
        # never quietly.
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
    # /home is shared between the slots and holds the module build area and the
    # driver cache; a 5 GiB rootfs has room for neither.
    mountpoint -q /home && { ota_mount -o bind /home "$mnt/home" \
        || fail "could not bind /home -- the build area falls back to the rootfs"; }

    log "provisioning the newly written slot at $mnt"
    #
    # RUN IT IN A PRIVATE MOUNT NAMESPACE.
    #
    # steamos_boot.sh binds /proc, /sys, /dev and a resolver into the target and
    # unmounts them on its EXIT trap. That teardown is not reliable: something
    # holds an open fd under the target's /dev -- the NVIDIA installer and
    # modprobe both run in there -- so the umount fails, the fallback is a LAZY
    # unmount, and a lazy unmount keeps the filesystem alive. btrfs then goes on
    # holding the slot and rauc's post-install handler fails with code 32,
    # reported to the user as "Unable to download the required update".
    #
    # MEASURED 2026-08-28: retrying the unmount five times with `umount -R`
    # fixed it when nothing else touched the slot, and did NOT fix it during a
    # real OTA. Retries treat the symptom.
    #
    # In a private namespace the kernel drops every mount the process made when
    # it exits, whether or not anything held them. The leak stops being
    # something to get right and becomes something that cannot happen.
    # --propagation private so the binds cannot escape back to us.
    #
    local runner=""
    if command -v unshare >/dev/null 2>&1 \
       && unshare -m --propagation private true 2>/dev/null; then
        runner="unshare -m --propagation private"
    else
        fail "no usable unshare(1): provisioning mounts will rely on teardown"
    fi
    $runner "$SHARE_MNT/boot/steamos_boot.sh" --install-only --root "$mnt" >>"$LOG" 2>&1 || rc=$?

    # Belt and braces: --install-only verifies this itself and fails loudly, but
    # it is the property the whole exercise exists to guarantee.
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
        # DISARM, deliberately. Better to stay on the working old slot than to
        # boot an updated one whose GPU support is unknown: a system that
        # silently lost its GPU is a worse outcome than an update that visibly
        # did not apply. The owner's call, 2026-08-29.
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
