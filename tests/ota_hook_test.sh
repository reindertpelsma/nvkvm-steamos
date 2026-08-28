#!/bin/bash
# ota_hook_test.sh — the steamos-update hook must survive being installed twice,
# must not provision on a mere `check`, and must not alter the updater's status.
#
# A SteamOS A/B update replaces the rootfs, so nvkvm is absent from every new
# slot. The hook provisions that slot before the reboot prompt. Two things about
# it are genuinely dangerous:
#
#   * moving Valve's /usr/bin/steamos-update aside TWICE would overwrite
#     steamos-update.orig with our own wrapper -- destroying the real updater
#     and leaving a wrapper that chains to itself forever;
#   * `steamos-update check` exits 0 to mean "an update is AVAILABLE", nothing
#     written. The Steam client polls it. Provisioning there would rebuild the
#     module against the OLD image, repeatedly, for nothing.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$DIR/boot/image/nvkvm-steamos-update"
rc=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

VALVE_MARK="I am Valve's real updater"

# --- the move-aside, as steamos_boot.sh performs it -------------------------
install_once() {  # <root>
    local root="$1" upd="$1/usr/bin/steamos-update" orig="$1/usr/bin/steamos-update.orig"
    if ! grep -q '^# NVKVM_OTA_WRAPPER' "$upd" 2>/dev/null; then
        if [ -f "$orig" ]; then :; else mv -f "$upd" "$orig" || return 1; fi
    fi
    cp -f "$WRAPPER" "$upd"; chmod 0755 "$upd"
}

root="$work/slot"; mkdir -p "$root/usr/bin"
printf '#!/bin/sh\necho "%s"\n' "$VALVE_MARK" > "$root/usr/bin/steamos-update"
chmod +x "$root/usr/bin/steamos-update"

install_once "$root" || { echo "FAIL: first install failed"; rc=1; }
install_once "$root" || { echo "FAIL: second install failed"; rc=1; }
install_once "$root" || { echo "FAIL: third install failed"; rc=1; }

if grep -q "$VALVE_MARK" "$root/usr/bin/steamos-update.orig"; then
    echo "ok: Valve's updater survives repeated installs"
else
    echo "FAIL: steamos-update.orig is no longer Valve's updater -- the real one is LOST"; rc=1
fi
if grep -q '^# NVKVM_OTA_WRAPPER' "$root/usr/bin/steamos-update"; then
    echo "ok: the wrapper is in place"
else
    echo "FAIL: the wrapper is not installed"; rc=1
fi

# --- the wrapper's own behaviour --------------------------------------------
# Point it at fixtures instead of the real paths, without editing the shipped file.
mk_wrapper() {  # <real-exit-code>
    sed -e "s|^REAL=.*|REAL=$work/real|" -e "s|^OTA=.*|OTA=$work/ota|" "$WRAPPER" > "$work/w"
    chmod +x "$work/w"
    printf '#!/bin/sh\necho ran-real "$@" >> %s/reallog\nexit %s\n' "$work" "$1" > "$work/real"
    chmod +x "$work/real"
    printf '#!/bin/sh\necho provisioned >> %s/otalog\n' "$work" > "$work/ota"
    chmod +x "$work/ota"
    rm -f "$work/otalog" "$work/reallog"
}

mk_wrapper 0; "$work/w" check >/dev/null 2>&1; st=$?
[ -f "$work/otalog" ] && { echo "FAIL: 'check' provisioned the other slot"; rc=1; } \
                      || echo "ok: 'check' does not provision"
[ "$st" = 0 ] || { echo "FAIL: check-mode exit $st, expected 0"; rc=1; }

mk_wrapper 0; "$work/w" >/dev/null 2>&1; st=$?
[ -f "$work/otalog" ] && echo "ok: an applied update provisions the new slot" \
                      || { echo "FAIL: an applied update did NOT provision"; rc=1; }
[ "$st" = 0 ] || { echo "FAIL: exit $st, expected 0"; rc=1; }

mk_wrapper 7; "$work/w" >/dev/null 2>&1; st=$?
[ -f "$work/otalog" ] && { echo "FAIL: provisioned despite 'no update available'"; rc=1; } \
                      || echo "ok: no provisioning when there was no update"
[ "$st" = 7 ] || { echo "FAIL: exit $st, expected 7 preserved"; rc=1; }

mk_wrapper 1; "$work/w" >/dev/null 2>&1; st=$?
[ "$st" = 1 ] || { echo "FAIL: exit $st, expected 1 preserved"; rc=1; }
[ -f "$work/otalog" ] && { echo "FAIL: provisioned after a FAILED update"; rc=1; } \
                      || echo "ok: a failed update does not provision"

# --- what the hook still owns -------------------------------------------
# The chroot the target needs (/proc, /sys, /dev, a resolver) is NOT here: it
# belongs to steamos_boot.sh, which builds it for every entry point that hands
# it an image root. See tests/chroot_ownership_test.sh. What the hook owns is
# the image's OWN filesystems, which only the caller can identify.
OTA="$DIR/boot/image/nvkvm-ota.sh"
grep -q 'ota_mount -o bind /home' "$OTA" \
    && echo "ok: the hook provides the image's /home (the build area)" \
    || { echo "FAIL: nobody mounts /home for the build area"; rc=1; }

# A LEFTOVER MOUNT BREAKS THE UPDATE ITSELF: rauc's post-install handler mounts
# the other slot to sync var, and fails with "already mounted or mount point
# busy" -> "Child process exited with code 32" if we still hold it.
grep -q 'ota_umount_all || rc=1' "$OTA" \
    && echo "ok: everything is unmounted before returning to the updater" \
    || { echo "FAIL: the hook can return while still holding the slot"; rc=1; }
grep -q "trap 'ota_umount_all" "$OTA" \
    && echo "ok: a trap unmounts even on an unexpected exit" \
    || { echo "FAIL: no cleanup trap -- an early return leaks the mount"; rc=1; }

# inner mounts must come off before the slot they live in
mounts="$(bash -c '
OTA_MOUNTS=""
mount() { return 0; }
ota_mount() { local target="${@: -1}"; if mount "$@"; then OTA_MOUNTS="$target $OTA_MOUNTS"; return 0; fi; return 1; }
ota_mount /dev/x /mnt/root
ota_mount -o bind /proc /mnt/root/proc
echo "$OTA_MOUNTS"')"
case "$mounts" in
    "/mnt/root/proc /mnt/root "*|"/mnt/root/proc /mnt/root") echo "ok: unmount order is inner-before-outer" ;;
    *) echo "FAIL: unmount order is '$mounts' -- outer first would fail as busy"; rc=1 ;;
esac

[ $rc -eq 0 ] && echo "PASS: the OTA hook is idempotent, status-preserving and leaves no mounts"
exit $rc
