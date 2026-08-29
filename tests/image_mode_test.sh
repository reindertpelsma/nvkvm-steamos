#!/bin/bash
# image_mode_test.sh — --image is the layer that turns a BLOCK DEVICE into a
# provisioned slot, and the OTA hook must own none of it.
#
# The resize is the part that is easy to get silently wrong. Valve's installer
# dd's a 5 GiB filesystem into each rootfs partition and never resizes it; every
# OTA writes the slot the same way. Enlarging the partition therefore buys
# nothing on its own -- the space is on the disk and invisible to the
# filesystem, and provisioning runs out of room exactly as it did before.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
HOOK="$DIR/boot/image/nvkvm-ota.sh"
rc=0

# ── static: the layering must actually be wired up ──────────────────────────
grep -qE '^ *image\).*do_image ;;' "$BOOT" \
    && echo "ok: --image is dispatched" \
    || { echo "FAIL: no image dispatch"; rc=1; }

# Every writing mode takes the converge lock. --image is the one an OTA hook
# runs unattended, so it is the one most likely to collide with a hand-run
# converge over the shared /home build area.
for m in install image boot; do
    grep -qE "^ *$m\).*converge_lock" "$BOOT" \
        && echo "ok: --$m takes the converge lock" \
        || { echo "FAIL: $m dispatch does not take the converge lock"; rc=1; }
done

grep -q '\-\-image)        CMD=image; IMAGE_DEV="\$2"' "$BOOT" \
    && echo "ok: --image takes a device" \
    || { echo "FAIL: --image does not parse a device"; rc=1; }

grep -q '\-\-boot)         CMD=boot' "$BOOT" \
    && echo "ok: --boot is explicit" \
    || { echo "FAIL: --boot is not accepted"; rc=1; }

# --image chooses the root; combining it with --root is a contradiction, and a
# silently ignored --root would provision the wrong tree.
awk '/^do_image\(\) \{/,/^\}/' "$BOOT" | grep -q 'mutually exclusive' \
    && echo "ok: --image rejects --root" \
    || { echo "FAIL: --image does not reject --root"; rc=1; }

# do_install's EXIT trap must also drop image mounts, in that order: the chroot
# binds live INSIDE the image mount, so releasing them first is the only order
# that can succeed.
grep -q "trap 'chroot_teardown; restore_ro_state; image_umount_all' EXIT" "$BOOT" \
    && echo "ok: cleanup releases chroot binds before the image mount" \
    || { echo "FAIL: EXIT trap does not release image mounts in order"; rc=1; }

# ── static: the hook must be a finder, not a mounter ────────────────────────
if grep -qE 'ota_mount|ota_umount_all|OTA_MOUNTS|mktemp -d /tmp/nvkvm-ota' "$HOOK"; then
    echo "FAIL: the hook still carries its own mount logic"; rc=1
else
    echo "ok: the hook holds no mount logic"
fi
grep -q 'steamos_boot.sh" --image "\$dev"' "$HOOK" \
    && echo "ok: the hook hands the slot over as a device" \
    || { echo "FAIL: the hook does not call --image"; rc=1; }

# ── functional: the resize actually grows a short filesystem ────────────────
# Skip where loop devices or btrfs are unavailable (some CI runners).
if ! command -v losetup >/dev/null || ! command -v mkfs.btrfs >/dev/null \
   || [ "$(id -u)" != 0 ] || ! losetup -f >/dev/null 2>&1; then
    echo "SKIP: no loop device / btrfs / root available for the resize test"
    exit $rc
fi

work="$(mktemp -d)"; L=""; MNT="$work/mnt"
cleanup() { umount "$MNT" 2>/dev/null; [ -n "$L" ] && losetup -d "$L" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$MNT"

# A 300M "partition" holding a 200M filesystem: exactly what dd'ing a smaller
# image into a larger slot leaves behind.
truncate -s 300M "$work/slot.img"
L="$(losetup --find --show "$work/slot.img" 2>/dev/null)" || { echo "SKIP: losetup failed"; exit $rc; }
mkfs.btrfs -q -f --byte-count 200M "$L" >/dev/null 2>&1 || { echo "SKIP: mkfs.btrfs failed"; exit $rc; }
mount "$L" "$MNT" 2>/dev/null || { echo "SKIP: mount failed"; exit $rc; }

LOGGED=""
log()  { LOGGED="$LOGGED$*"$'\n'; }
warn() { LOGGED="$LOGGED$*"$'\n'; }
err()  { LOGGED="$LOGGED$*"$'\n'; }
eval "$(awk '/^image_resize_to_partition\(\) \{/,/^\}/' "$BOOT")"
declare -F image_resize_to_partition >/dev/null \
    || { echo "FAIL: could not extract image_resize_to_partition"; exit 1; }

before=$(df -Pk "$MNT" | awk 'NR==2{print $2}')
image_resize_to_partition "$MNT"
after=$(df -Pk "$MNT" | awk 'NR==2{print $2}')

if [ "$after" -gt "$before" ] && [ "$after" -gt 280000 ]; then
    echo "ok: grew the filesystem to its partition ($((before/1024))M -> $((after/1024))M)"
else
    echo "FAIL: did not grow ($((before/1024))M -> $((after/1024))M)"; rc=1
fi
case "$LOGGED" in
    *"grown to fill its partition"*) echo "ok: says so in the log" ;;
    *) echo "FAIL: grew without reporting it"; rc=1 ;;
esac

# Idempotent: a converge that runs on every boot must not report work it did not do.
LOGGED=""
image_resize_to_partition "$MNT"
case "$LOGGED" in
    *"already fills its partition"*) echo "ok: idempotent on an already-grown slot" ;;
    *) echo "FAIL: not idempotent: $LOGGED"; rc=1 ;;
esac

exit $rc
