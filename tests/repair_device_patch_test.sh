#!/bin/bash
# repair_device_patch_test.sh — the ONE change we make to Valve's installer must
# apply exactly, or stop the install.
#
# Partition sizes are decided once, at install, and cannot be changed afterwards
# on a machine that is already installed. So a patch that silently misses is far
# worse than one that fails: it produces a differently-sized disk that nobody
# notices until the first OTA runs out of room.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
GI="$DIR/vm/guest-init.sh"
PATCHFILE="$DIR/boot/patches/0002-repair-device-rootfs-size.patch"
rc=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

[ -f "$PATCHFILE" ] || { echo "FAIL: $PATCHFILE missing"; exit 1; }

# Valve's real block, verbatim from the 20260707.10 recovery image.
make_target() {
    mkdir -p "$work/chroot/home/deck/tools"
    cat > "$work/chroot/home/deck/tools/repair_device.sh" <<'ORIG'
# Partition table, sfdisk format, %%DISKPART%% filled in
#
PART_SIZE_ESP="256"
PART_SIZE_EFI="64"
PART_SIZE_ROOT="5120" # This should match the size from the input disk build
PART_SIZE_VAR="256"
PART_SIZE_HOME="100" # For the stub .img file we're making this can be tiny, OS expands to fill physical disk on first
  %%DISKPART%%4: name="rootfs-A", size=         ${PART_SIZE_ROOT}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
  %%DISKPART%%5: name="rootfs-B", size=         ${PART_SIZE_ROOT}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
ORIG
}

# Run the REAL function out of guest-init.sh.
eval "$(awk '/^patch_repair_device\(\) \{/,/^\}/' "$GI")"
declare -F patch_repair_device >/dev/null || { echo "FAIL: could not extract patch_repair_device"; exit 1; }
LOGGED=""
log() { LOGGED="$LOGGED$*"$'\n'; }
# Consumed by the extracted patch_repair_device, not by this script directly.
# shellcheck disable=SC2034
CHROOT="$work/chroot"
SHARE_MNT="$work/share"
mkdir -p "$SHARE_MNT/boot/patches"
cp "$PATCHFILE" "$SHARE_MNT/boot/patches/"

T="$work/chroot/home/deck/tools/repair_device.sh"

# 1. it applies, and to BOTH slots (they share the variable)
make_target; LOGGED=""
if patch_repair_device && grep -q '^PART_SIZE_ROOT="8192"' "$T"; then
    echo "ok: applies to Valve's real block"
else
    echo "FAIL: did not apply"; echo "$LOGGED" | sed 's/^/    /'; rc=1
fi
grep -q 'rootfs-A".*PART_SIZE_ROOT' "$T" && grep -q 'rootfs-B".*PART_SIZE_ROOT' "$T" \
    && echo "ok: both slots still sized from the variable" \
    || { echo "FAIL: the sfdisk table lost its reference"; rc=1; }

# 2. idempotent -- re-running a stage must not be a failure
LOGGED=""
if patch_repair_device; then echo "ok: idempotent on an already-patched image"
else echo "FAIL: not idempotent"; rc=1; fi

# 3. upstream changed the line -> must FAIL, not guess
make_target
sed -i 's/^PART_SIZE_ROOT="5120".*/PART_SIZE_ROOT="6144" # upstream grew it/' "$T"
LOGGED=""
if patch_repair_device; then
    echo "FAIL: applied to an image whose block Valve changed"; rc=1
else
    case "$LOGGED" in
        *"does not apply"*) echo "ok: refuses when upstream changed the line, and says so" ;;
        *) echo "FAIL: refused but without a usable reason"; rc=1 ;;
    esac
fi
grep -q '6144' "$T" && echo "ok: left the image untouched on refusal" \
    || { echo "FAIL: modified the image despite refusing"; rc=1; }

# 4. missing patch file -> must FAIL rather than install 5 GiB slots silently
make_target; rm -f "$SHARE_MNT/boot/patches/"*.patch
LOGGED=""
if patch_repair_device; then echo "FAIL: proceeded with no patch file"; rc=1
else echo "ok: refuses when the patch is absent"; fi
cp "$PATCHFILE" "$SHARE_MNT/boot/patches/"

# 5. ambiguous target (two matching lines) -> refuse
make_target
printf 'PART_SIZE_ROOT="5120" # This should match the size from the input disk build\n' >> "$T"
LOGGED=""
if patch_repair_device; then echo "FAIL: applied with two candidate lines"; rc=1
else echo "ok: refuses an ambiguous match"; fi

# 6. the patch must not have drifted from what the applier expects
grep -q '^+PART_SIZE_ROOT="8192"' "$PATCHFILE" \
    && echo "ok: patch still sets 8192" \
    || { echo "FAIL: patch no longer sets 8192"; rc=1; }

exit $rc
