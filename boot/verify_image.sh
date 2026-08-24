#!/usr/bin/env bash
# verify_image.sh — is this mounted SteamOS rootfs actually provisioned for nvkvm?
#
#   boot/verify_image.sh <mounted-rootfs> <nvkvm-pv checkout the image was built from>
#
# Read-only. Needs no loop device, no chroot and no root beyond whatever it takes
# to read the mount. Exit 0 = provisioned; 1 = not, and every reason is printed.
#
# DELIBERATELY STANDALONE, and deliberately not part of any one image builder.
# It is the gate a builder applies just before it unmounts and converts, and it
# is the same thing an operator runs by hand on an image that already exists. Any
# builder — the loop-device/chroot one, a VM-based one, a hand-typed sequence out
# of docs/manual-install.md — can call it with two paths and nothing else, so the
# check outlives whichever builder is current.
#
# WHY IT COMPARES BYTES AND NOT JUST SIZES
#
# Four of the files in a provisioned image are copies of files on the share, made
# by install_stub() in steamos_boot.sh with install(1). install(1) opens the
# destination O_CREAT|O_TRUNC BEFORE it has written a byte, and chmods it LAST.
# So any failure mid-copy — ENOSPC on the ~5 GB SteamOS rootfs, a short read off
# the 9p share, a zero-length source — leaves a destination that exists, has
# exactly the right name, and is empty, truncated, or the wrong mode.
#
# MEASURED, on a deliberately-full ext2 image with /usr/local/sbin present:
#
#     $ install -m 0755 src dst
#     install: cannot install 'src' to 'dst': No space left on device
#     $ ls -l dst
#     -rw------- 1 root root 0 ... dst
#
# A zero-length /usr/local/sbin/nvkvm-recovery.sh is the worst artifact this
# project can ship: execve() on an empty file returns ENOEXEC, so
# nvkvm-boot.service fails 203/EXEC on EVERY boot, and every `ls` and `test -e`
# in the world says the file is installed. `test -s` is not enough either — it
# passes a short read. Compare the bytes.

set -uo pipefail

log()  { printf '[verify] %s\n' "$*" >&2; }
err()  { printf '[verify] ERROR: %s\n' "$*" >&2; }

# The four files planted verbatim from <share>/boot/image/. Format is
# path-inside-the-image:name-on-the-share.
PLANTED="usr/local/sbin/nvkvm-recovery.sh:nvkvm-recovery.sh
etc/systemd/system/nvkvm-boot.service:nvkvm-boot.service
etc/systemd/system/nvkvm-plant-stub.path:nvkvm-plant-stub.path
etc/systemd/system/nvkvm-plant-stub.service:nvkvm-plant-stub.service"

# Files the provisioning GENERATES rather than copies: there is no source to
# compare against, so non-empty is all that can be asserted.
GENERATED="etc/modules-load.d/nvkvm.conf
etc/modprobe.d/99-nvkvm.conf"

verify_provisioned_image() {   # <mounted-rootfs> <share>   -> 0 ok / 1 not
    local mnt="$1" share="$2"
    local vfail="" kver lib u planted srcf ssz dsz d

    [ -d "$mnt" ]   || { err "not a directory: $mnt"; return 1; }
    [ -d "$share" ] || { err "not a directory: $share"; return 1; }

    kver=""
    for d in "$mnt"/usr/lib/modules/*; do
        [ -e "$d/vmlinuz" ] && { kver="$(basename "$d")"; break; }
    done
    [ -n "$kver" ] || vfail="$vfail\n  - no kernel with a vmlinuz under /usr/lib/modules"
    if [ -n "$kver" ] && [ ! -s "$mnt/usr/lib/modules/$kver/updates/nvkvm-guest.ko" ]; then
        vfail="$vfail\n  - nvkvm-guest.ko missing (or empty) for kernel $kver"
    fi

    for lib in libnvidia-glcore libnvidia-glsi libnvidia-tls libGLX_nvidia; do
        ls "$mnt"/usr/lib/"$lib".so.* >/dev/null 2>&1 \
            || vfail="$vfail\n  - $lib missing from /usr/lib"
    done
    # The 0-byte-libnvidia-ml class of failure, caught on the mount rather than
    # after conversion: any zero-length .so means the install did not complete.
    if [ -n "$(find "$mnt/usr/lib" -maxdepth 1 -name 'libnvidia-*.so.*' -size 0 -print -quit 2>/dev/null)" ]; then
        vfail="$vfail\n  - zero-length libnvidia-*.so.* in /usr/lib (incomplete install)"
    fi

    while IFS= read -r u; do
        [ -n "$u" ] || continue
        [ -s "$mnt/$u" ] || vfail="$vfail\n  - /$u not written (or empty)"
    done <<EOF
$GENERATED
EOF

    while IFS= read -r u; do
        [ -n "$u" ] || continue
        planted="$mnt/${u%%:*}"; srcf="$share/boot/image/${u##*:}"
        ssz="$(wc -c <"$srcf" 2>/dev/null || true)";    ssz="${ssz:-?}"
        dsz="$(wc -c <"$planted" 2>/dev/null || true)"; dsz="${dsz:-?}"
        if [ ! -r "$srcf" ]; then
            vfail="$vfail\n  - cannot verify /${u%%:*}: its source $srcf is missing from the share"
        elif [ ! -e "$planted" ]; then
            vfail="$vfail\n  - /${u%%:*} was never installed"
        elif [ ! -s "$planted" ]; then
            vfail="$vfail\n  - /${u%%:*} is ZERO-LENGTH (the source on the share is $ssz bytes). systemd fails a zero-length ExecStart with 203/EXEC, on every boot."
        elif ! cmp -s "$srcf" "$planted"; then
            vfail="$vfail\n  - /${u%%:*} does not match $srcf ($dsz bytes planted, $ssz expected) — the copy was truncated or corrupted"
        fi
    done <<EOF
$PLANTED
EOF

    # This one is executed, not merely read — and install(1) chmods last, so a
    # copy that died mid-write also has the wrong mode.
    [ -x "$mnt/usr/local/sbin/nvkvm-recovery.sh" ] \
        || vfail="$vfail\n  - /usr/local/sbin/nvkvm-recovery.sh is not executable — nvkvm-boot.service could not run it"

    if [ -n "$vfail" ]; then
        printf '[verify] the image is NOT provisioned correctly:%b\n' "$vfail" >&2
        return 1
    fi
    log "OK: module for $kver, NVIDIA userspace present, and the four planted files match the share byte-for-byte"
    return 0
}

# Only run the CLI when executed, so a builder can `source` this file and call
# the function directly if it prefers.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ $# -ne 2 ]; then
        sed -n '2,10p' "$0" >&2
        exit 2
    fi
    verify_provisioned_image "$1" "$2" || exit 1
    exit 0
fi
