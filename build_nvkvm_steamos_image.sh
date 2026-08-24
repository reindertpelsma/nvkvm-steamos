#!/usr/bin/env bash
# build_nvkvm_steamos_image.sh — build an nvkvm-ready SteamOS guest qcow2 from
# a pristine SteamOS repair image, offline (no boot required for the build
# itself).
#
# This mechanizes the exact recipe proven by hand in the 2026-08-22/23
# session recorded in NOTES.md ("Rebuilt the guest image from scratch"
# section) — read that section for the measured evidence that each step
# here is necessary and sufficient. Two things this script does NOT do,
# both called out where they matter below:
#   1. It does not build nvkvm-guest.ko from source. Pass an already-built
#      .ko (matching the target image's exact kernel, vermagic-checked
#      below) via --ko. Building it is a separate, previously-solved step
#      (see NOTES.md's M1 GATE section) -- headers come from Valve's package
#      mirror for the neptune kernel, plain kbuild, no chroot needed.
#   2. It hardcodes KWIN_DRM_DEVICES=/dev/dri/card0. This was observed
#      stable across every boot this session (nvkvm's PCI slot is fixed by
#      -device nvkvm-gpu,addr=7 in the run script, and it consistently
#      enumerates as card0 ahead of the emulated VGA's card1) -- but it is
#      an *observed* fact about this one launch configuration, not a
#      structural guarantee. The project's own docs
#      (docs/internal/mint-guest-desktop.md) explicitly warn against
#      selecting DRM nodes by index for exactly this reason. If the QEMU
#      command line ever changes GPU ordering, this needs to become a
#      boot-time lookup (walk /sys/class/drm/card[0-9]*/device/driver for
#      "nvidia", the way run-session.sh already does for weston) instead of
#      a static environment.d value written offline. Flagging, not fixing --
#      doing it properly needs a systemd unit that runs *inside* the guest
#      at login time, which is out of scope for an offline chroot build.
#
# Usage:
#   build_nvkvm_steamos_image.sh \
#     --src /home/ubuntu/Downloads/steamdeck-oobe-repair-*.img \
#     --out /root/steamos-nvkvm/steamos-nvkvm.qcow2 \
#     --ko /root/steamos-nvkvm/nvkvm-guest-neptune616.ko \
#     --nvidia-run-extracted /root/steamos-nvkvm/nvidia-run/extracted \
#     [--driver-version 595.84]   # default: auto-detect from the HOST via nvidia-smi
#     [--grow +60G]               # default: +60G
#     [--kwin-drm-device /dev/dri/card0]   # default: card0, see caveat #2 above
#
# Must be run as root (nbd, chroot, mount). Requires: qemu-img, qemu-nbd,
# the `nbd` kernel module (modprobe nbd), btrfs-progs, depmod.

set -euo pipefail

log() { echo "[build] $*" >&2; }
die() { echo "[build] ERROR: $*" >&2; exit 1; }

# ---- defaults ----
GROW="+60G"
KWIN_DRM_DEVICE="/dev/dri/card0"
DRIVER_VERSION=""
NBD_DEV="/dev/nbd0"

# ---- args ----
SRC="" OUT="" KO="" RUNDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --ko) KO="$2"; shift 2 ;;
    --nvidia-run-extracted) RUNDIR="$2"; shift 2 ;;
    --driver-version) DRIVER_VERSION="$2"; shift 2 ;;
    --grow) GROW="$2"; shift 2 ;;
    --kwin-drm-device) KWIN_DRM_DEVICE="$2"; shift 2 ;;
    --nbd-dev) NBD_DEV="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "must run as root (nbd/chroot/mount)"
[ -n "$SRC" ] || die "--src <pristine repair .img> is required"
[ -f "$SRC" ] || die "--src file not found: $SRC"
[ -n "$OUT" ] || die "--out <output .qcow2 path> is required"
[ -n "$KO" ] || die "--ko <built nvkvm-guest.ko> is required (this script does not build it)"
[ -f "$KO" ] || die "--ko file not found: $KO"
[ -n "$RUNDIR" ] || die "--nvidia-run-extracted <dir> is required"
[ -d "$RUNDIR" ] || die "--nvidia-run-extracted dir not found: $RUNDIR"
[ -x "$RUNDIR/nvidia-installer" ] || die "nvidia-installer not found/executable under $RUNDIR (expected the extracted .run payload)"

if [ -z "$DRIVER_VERSION" ]; then
  DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
  [ -n "$DRIVER_VERSION" ] || die "could not auto-detect driver version from host nvidia-smi; pass --driver-version explicitly"
  log "auto-detected host driver version: $DRIVER_VERSION"
fi

modprobe nbd 2>/dev/null || true
[ -e "$NBD_DEV" ] || die "$NBD_DEV not present after modprobe nbd"

WORK="$(mktemp -d /tmp/nvkvm-build.XXXXXX)"
ROOTFS_MNT="$WORK/rootfs"
HOME_MNT="$WORK/home"
mkdir -p "$ROOTFS_MNT" "$HOME_MNT"

cleanup() {
  set +e
  umount "$ROOTFS_MNT/tmp/nvidia-install" 2>/dev/null
  umount "$ROOTFS_MNT/proc" "$ROOTFS_MNT/sys" "$ROOTFS_MNT/dev" 2>/dev/null
  umount "$HOME_MNT" 2>/dev/null
  umount "$ROOTFS_MNT" 2>/dev/null
  qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null
  rmdir "$ROOTFS_MNT" "$HOME_MNT" "$WORK" 2>/dev/null
}
trap cleanup EXIT

log "1/9: converting pristine image to qcow2: $OUT"
[ -e "$OUT" ] && die "refusing to overwrite existing $OUT (move it aside first)"
qemu-img convert -f raw -O qcow2 "$SRC" "$OUT"

log "2/9: connecting via nbd and probing partitions"
qemu-nbd --connect="$NBD_DEV" "$OUT"
sleep 1
partprobe "$NBD_DEV" 2>/dev/null || true
# This partition layout (1=esp 2=efi 3=rootfs-btrfs 4=var-ext4 5=home-ext4) is
# specific to the steamdeck-oobe-repair image family this was built against
# -- verified against `steamdeck-oobe-repair-20260707.10-3.8.14.img`. If the
# source image's layout differs, this will mount the wrong thing; check
# `lsblk` output below before trusting the rest of the run.
lsblk "$NBD_DEV" >&2
ROOTFS_PART="${NBD_DEV}p3"
HOME_PART="${NBD_DEV}p5"
[ -b "$ROOTFS_PART" ] || die "expected rootfs partition $ROOTFS_PART not found -- partition layout differs from what this script assumes, see comment above"
[ -b "$HOME_PART" ] || die "expected home partition $HOME_PART not found -- partition layout differs from what this script assumes, see comment above"

log "3/9: mounting rootfs read-write"
mount "$ROOTFS_PART" "$ROOTFS_MNT"
btrfs property set "$ROOTFS_MNT" ro false

KVER="$(ls "$ROOTFS_MNT/usr/lib/modules/" | head -1)"
[ -n "$KVER" ] || die "could not determine guest kernel version from $ROOTFS_MNT/usr/lib/modules/"
log "guest kernel version: $KVER"

KO_VERMAGIC="$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')"
if [ -n "$KO_VERMAGIC" ] && [ "$KO_VERMAGIC" != "$KVER" ]; then
  die "--ko vermagic ($KO_VERMAGIC) does not match the image's kernel ($KVER) -- rebuild nvkvm-guest.ko against this image's headers first"
fi

log "4/9: installing nvkvm-guest.ko + boot-time defaults"
mkdir -p "$ROOTFS_MNT/usr/lib/modules/$KVER/updates"
cp -f "$KO" "$ROOTFS_MNT/usr/lib/modules/$KVER/updates/nvkvm-guest.ko"
depmod -b "$ROOTFS_MNT" "$KVER"
grep -q nvkvm-guest.ko "$ROOTFS_MNT/usr/lib/modules/$KVER/modules.dep" \
  || die "nvkvm-guest.ko missing from modules.dep after depmod -- module install failed"

mkdir -p "$ROOTFS_MNT/etc/modules-load.d"
echo nvkvm-guest > "$ROOTFS_MNT/etc/modules-load.d/nvkvm.conf"

mkdir -p "$ROOTFS_MNT/etc/modprobe.d"
cat > "$ROOTFS_MNT/etc/modprobe.d/99-nvkvm.conf" <<EOF
# Baked in by build_nvkvm_steamos_image.sh.
# Default OFF so unprivileged compositors (KWin, gamescope) can open the
# primary DRM node without CAP_SYS_ADMIN. MEASURED (2026-08-22/23 session,
# NOTES.md): with this =1 (the module's own compiled-in default), an
# unprivileged deck-user open() of /dev/dri/card0 gets EACCES; =0 lets it
# succeed with no other change. This is nvkvm's own gate
# (src/guest/nvkvm_main.c, param added upstream commit 4257500) -- not an
# nvidia driver setting and not a SteamOS setting.
options nvkvm_guest privileged_modeset=0
EOF

log "5/9: running nvidia-installer (userspace only, driver $DRIVER_VERSION) in chroot"
mount --bind /proc "$ROOTFS_MNT/proc"
mount --bind /sys  "$ROOTFS_MNT/sys"
mount --bind /dev  "$ROOTFS_MNT/dev"
mkdir -p "$ROOTFS_MNT/tmp/nvidia-install"
mount --bind "$RUNDIR" "$ROOTFS_MNT/tmp/nvidia-install"

# CRITICAL (see NOTES.md M4/"ICD packaging root cause"): do NOT hand-pick
# library files here. The installer's own dependency resolution is what
# pulls in libnvidia-glsi/tls/glcore/gpucomp, the 32-bit compat tree, and
# the EGL/Vulkan/OpenCL vendor manifests correctly; a hand-picked file list
# silently under-installs and produces a Vulkan loader that enumerates zero
# devices with no error until you strace it.
chroot "$ROOTFS_MNT" /tmp/nvidia-install/nvidia-installer \
    --silent --no-kernel-modules --no-kernel-module-source \
    --no-nouveau-check --no-x-check --no-rpms

umount "$ROOTFS_MNT/tmp/nvidia-install"
umount "$ROOTFS_MNT/proc" "$ROOTFS_MNT/sys" "$ROOTFS_MNT/dev"
chroot "$ROOTFS_MNT" ldconfig

log "6/9: verifying the previously-missing libs actually landed"
for lib in libnvidia-glsi libnvidia-tls libnvidia-glcore; do
  ls "$ROOTFS_MNT"/usr/lib/"$lib".so.* >/dev/null 2>&1 \
    || die "$lib missing after nvidia-installer -- installer run did not complete as expected"
done

log "7/9: mounting home, writing KWIN_DRM_DEVICES=$KWIN_DRM_DEVICE for deck"
mount "$HOME_PART" "$HOME_MNT"
DECK_UID="$(awk -F: '$1=="deck"{print $3}' "$ROOTFS_MNT/etc/passwd")"
DECK_GID="$(awk -F: '$1=="deck"{print $4}' "$ROOTFS_MNT/etc/passwd")"
[ -n "$DECK_UID" ] || die "no 'deck' user found in $ROOTFS_MNT/etc/passwd"
[ -d "$HOME_MNT/deck" ] || die "no deck home directory found on $HOME_PART"
mkdir -p "$HOME_MNT/deck/.config/environment.d"
echo "KWIN_DRM_DEVICES=$KWIN_DRM_DEVICE" > "$HOME_MNT/deck/.config/environment.d/nvkvm.conf"
chown "$DECK_UID:$DECK_GID" "$HOME_MNT/deck/.config/environment.d" "$HOME_MNT/deck/.config/environment.d/nvkvm.conf"

log "8/9: unmounting"
umount "$HOME_MNT"
btrfs property set "$ROOTFS_MNT" ro true
umount "$ROOTFS_MNT"
qemu-nbd --disconnect "$NBD_DEV"
trap - EXIT
rmdir "$ROOTFS_MNT" "$HOME_MNT" "$WORK" 2>/dev/null || true

log "9/9: growing the disk by $GROW (offline resize -- see NOTES.md for why not live)"
qemu-img resize "$OUT" "$GROW"
qemu-img check "$OUT" >&2

log "done: $OUT"
log "boot it, then re-inject agent.py (see inject_agent.sh) to go measure the result --"
log "expect: privileged_modeset=N with no manual toggle, kwin/gamescope opening"
log "only $KWIN_DRM_DEVICE, and nvidia-smi inside the guest showing real GPU procs."
