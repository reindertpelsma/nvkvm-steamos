#!/bin/bash
# chroot_ownership_test.sh — the chroot a target image needs is built by
# steamos_boot.sh, once, for every entry point.
#
# There are three entry points that hand boot.sh an image root: the Alpine
# installer, the OTA hook, and a repair at boot. Each needs /proc, /sys, /dev
# and a resolver inside that root. When each provided its own, the second
# implementation got the same three things wrong three times running -- missing
# binds, a resolver copied onto a read-only tree with the error suppressed, and
# a lazy unmount that left the slot busy for rauc. Every one reached the user as
# "Unable to download the required update".
#
# The rule: boot.sh provides the EXECUTION ENVIRONMENT (kernel filesystems,
# DNS). The caller provides the IMAGE'S OWN filesystems (its root, its /home),
# because only the caller knows which partitions those are.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
OTA="$DIR/boot/image/nvkvm-ota.sh"
rc=0

grep -q '^chroot_setup()' "$BOOT" && grep -q '^chroot_teardown()' "$BOOT" \
    && echo "ok: boot.sh owns chroot setup and teardown" \
    || { echo "FAIL: boot.sh has no chroot_setup/chroot_teardown"; rc=1; }

# ROOT=/ is the live system: it must touch nothing
sed -n '/^chroot_setup()/,/^}/p' "$BOOT" | grep -q '\[ "\$ROOT" = "/" \] && return 0' \
    && echo "ok: converging the live system sets up nothing" \
    || { echo "FAIL: chroot_setup does not short-circuit on ROOT=/"; rc=1; }

# idempotent: a caller that already provided a mount keeps it
sed -n '/^chroot_setup()/,/^}/p' "$BOOT" | grep -q 'mountpoint -q "\$t" && continue' \
    && echo "ok: an already-mounted path is left to its owner" \
    || { echo "FAIL: chroot_setup would double-mount what a caller provided"; rc=1; }

# we unmount only what we mounted
sed -n '/^chroot_teardown()/,/^}/p' "$BOOT" | grep -q 'for m in \$CHROOT_MOUNTS' \
    && echo "ok: teardown walks only our own mounts" \
    || { echo "FAIL: teardown does not track what it mounted"; rc=1; }

# teardown must actually be wired to the exit path, or a failure leaks a mount
# and the NEXT OS update cannot mount the slot rauc just wrote
grep -q "trap 'chroot_teardown; restore_ro_state' EXIT" "$BOOT" \
    && echo "ok: teardown runs on exit, including on failure" \
    || { echo "FAIL: chroot_teardown is not on the EXIT trap"; rc=1; }

# a lazy unmount keeps the filesystem alive; it must never be silent
sed -n '/^chroot_teardown()/,/^}/p' "$BOOT" | grep -q 'LAZILY' \
    && echo "ok: a lazy unmount is reported, not treated as success" \
    || { echo "FAIL: lazy unmount is silent -- it leaves the slot busy"; rc=1; }

# and the duplication must be GONE from the OTA hook
grep -q 'for d in proc sys dev' "$OTA" \
    && { echo "FAIL: the OTA hook still binds kernel filesystems itself"; rc=1; } \
    || echo "ok: the OTA hook no longer duplicates the chroot setup"
grep -q 'resolv\.conf' "$OTA" \
    && { echo "FAIL: the OTA hook still installs its own resolver"; rc=1; } \
    || echo "ok: the OTA hook no longer duplicates the resolver"

# the caller still owns the image's own filesystems
grep -q 'ota_mount -o bind /home' "$OTA" \
    && echo "ok: the caller still provides the image's /home" \
    || { echo "FAIL: nobody mounts /home for the build area"; rc=1; }

[ $rc -eq 0 ] && echo "PASS: one chroot implementation, owned by boot.sh"
exit $rc
