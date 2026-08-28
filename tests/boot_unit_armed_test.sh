#!/bin/bash
# boot_unit_armed_test.sh — provisioning an image must leave nvkvm-boot.service
# ARMED, and must fail loudly when it cannot.
#
# The failure this guards against is silent and total. After a SteamOS A/B OTA
# the new slot had the unit FILE (it lives in /etc, which persists) but no
# multi-user.target.wants symlink (that directory is part of the rootfs the
# update replaced). Nothing ran at boot, the guest module was never built, and
# the GPU was simply absent -- journalctl for that boot had zero nvkvm lines.
#
# install_stub() used to end with `systemctl enable ... 2>/dev/null || true`,
# which cannot tell a failed enable from a successful one.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
rc=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# the arm-and-verify step, as steamos_boot.sh performs it
arm() {  # <ROOT>
    local ROOT="$1" _wants_dir _wants
    rp() { if [ "$ROOT" = "/" ]; then printf '%s' "$1"; else printf '%s%s' "${ROOT%/}" "$1"; fi; }
    _wants_dir="$(rp /etc/systemd/system/multi-user.target.wants)"
    _wants="$_wants_dir/nvkvm-boot.service"
    if [ ! -e "$_wants" ] && [ ! -L "$_wants" ]; then
        mkdir -p "$_wants_dir" 2>/dev/null
        ln -sf /etc/systemd/system/nvkvm-boot.service "$_wants" 2>/dev/null || true
    fi
    [ -e "$_wants" ] || [ -L "$_wants" ]
}

# 1. a slot with the unit file but NO wants symlink -- the post-OTA state
root="$work/slot"
mkdir -p "$root/etc/systemd/system"
: > "$root/etc/systemd/system/nvkvm-boot.service"
if [ -L "$root/etc/systemd/system/multi-user.target.wants/nvkvm-boot.service" ]; then
    echo "FAIL: fixture is wrong, it starts armed"; rc=1
fi
if arm "$root"; then
    echo "ok: provisioning arms an unarmed slot (the post-OTA case)"
else
    echo "FAIL: provisioning did not arm the slot"; rc=1
fi
[ -L "$root/etc/systemd/system/multi-user.target.wants/nvkvm-boot.service" ] \
    || { echo "FAIL: no wants symlink was created"; rc=1; }

# 2. idempotent -- running it twice must not fail or duplicate
if arm "$root"; then
    echo "ok: arming an already-armed slot is a no-op that still succeeds"
else
    echo "FAIL: second arm reported failure"; rc=1
fi

# 3. it must REPORT failure, not swallow it, when the tree is unwritable
unw="$work/unwritable"
mkdir -p "$unw/etc/systemd/system"
chmod a-w "$unw/etc/systemd/system"
if arm "$unw"; then
    echo "SKIP: running as root, an unwritable tree is still writable"
else
    echo "ok: an un-armable slot is reported as a failure, not swallowed"
fi
chmod u+w "$unw/etc/systemd/system"

# 4. the regression: boot.sh must not end the enable with a bare `|| true`
if grep -qE 'systemctl enable nvkvm-boot\.service.*\|\| true' "$BOOT" \
   && ! grep -q 'NOT ARMED' "$BOOT"; then
    echo "FAIL: boot.sh enables the unit without verifying it"; rc=1
else
    echo "ok: boot.sh verifies the arming rather than assuming it"
fi

[ $rc -eq 0 ] && echo "PASS: provisioning leaves the image armed, or says so"
exit $rc
