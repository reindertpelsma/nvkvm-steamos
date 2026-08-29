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
        # --no-create is the whole fix. Without it `config --set` HAPPILY
        # INVENTS the config, which is how nine of them appeared. With it the
        # command refuses ("Image config for X does not exist") and writes
        # nothing, while still disarming every config that genuinely exists --
        # including 'dev', which is the one that matters: MEASURED, an existing
        # dev.conf with no rootfs behind it is what `set-mode reboot-other`
        # selects in preference to the real other slot, and booting it is what
        # left a machine at a GRUB prompt. Filtering on "has a rootfs partset"
        # would skip 'dev' and leave exactly that trap armed.
        steamos-bootconf config --image "$other" --no-create --set boot-requested-at 0 >/dev/null 2>&1 \
            && log "disarmed image '$other' -- it will not be booted"
    done
}

# WE MOUNT NOTHING. Finding the slot is this script's whole job; mounting it,
# sizing its filesystem to its partition, binding /home and tearing all of that
# down again is steamos_boot.sh --image. There used to be a second
# implementation of those mounts here, and it got the same three things wrong
# three times running.
provision_other() {
    local dev=/dev/disk/by-partsets/other/rootfs
    local rc=0

    [ -e "$dev" ] || { fail "$dev does not exist -- not an A/B system?"; return 1; }
    mount_share || { fail "could not mount the nvkvm share at $SHARE_MNT"; disarm_other; return 1; }
    [ -x "$SHARE_MNT/boot/steamos_boot.sh" ] \
        || { fail "steamos_boot.sh missing from the share"; disarm_other; return 1; }

    log "handing the newly written slot ($dev) to steamos_boot.sh --image"
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
    # --image mounts, resizes, provisions and UNMOUNTS, and reports a slot it
    # could not release as a failure -- rauc is not finished with this slot and
    # a busy one fails its post-install handler. Arming is verified in there too
    # (see boot_unit_armed_test.sh); a second check here would be one more copy
    # of a guarantee that already has an owner.
    $runner "$SHARE_MNT/boot/steamos_boot.sh" --image "$dev" >>"$LOG" 2>&1 || rc=$?

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
