#!/usr/bin/env bash
# build_steamos_image.sh — turn a PRISTINE SteamOS recovery image into a
# provisioned, nvkvm-ready guest image, offline, in one command.
#
# This is the scripted form of the manual sequence in docs/manual-install.md
# (README "Start here" steps 1-2, TUTORIAL steps 4-5). It does exactly what
# that document does and nothing more: grow the disk, repair the GPT, mount the
# rootfs, stand a bind mount in for the 9p share, run
# `steamos_boot.sh --install-only --root <mnt>`, unmount cleanly, convert.
#
#   sudo ./build_steamos_image.sh --src steamdeck-repair.img --share ~/nvkvm/nvkvm-pv
#
# Output: <src>-nvkvm.img (the work image) and, unless --no-qcow2,
# <src>-nvkvm.qcow2 — the file you hand to boot/run_steamos_nvkvm.sh.
# The input image is copied first and is NEVER modified.
#
# Options
#   --src FILE         pristine SteamOS recovery .img (required)
#   --share DIR        an nvkvm-pv checkout — NOT this repo (required).
#                      It is bind-mounted at /run/nvkvm to stand in for the
#                      9p share, and steamos_boot.sh builds the guest module
#                      from <share>/src/guest.
#   --out FILE         work image path (default: <src stem>-nvkvm.img)
#   --qcow2 FILE       qcow2 path (default: <out stem>.qcow2)
#   --no-qcow2         stop after the work image; skip the conversion
# WHAT THIS PRODUCES: a directly bootable SteamOS disk, not an installer.
# Valve's "recovery" image already carries an installed layout
# (esp / efi-A / rootfs-A / var-A / home), so this modifies it in place and
# converts it to qcow2 -- there is no separate install step, you boot the
# output.
#
# WHAT IT CANNOT DO: this image has only the A slot. There is no rootfs-B /
# efi-B / var-B, so rauc's atomic A/B update semantics are absent and it
# cannot take SteamOS OTA updates the way a Deck does. The update hook that
# re-arms nvkvm after a SteamOS update is therefore untestable here and has
# never been exercised on any rig -- it needs a real installed device. See
# boot/TESTING.md. Some Valve images do ship both slots; this one does not.
#
#   --grow SIZE        disk growth, iec suffixes (default: 60G; 0 to skip).
#                      This sizes the image you will BOOT AND USE -- it is not
#                      a build scratch size, so shrinking it shrinks the disk
#                      the guest ends up living on. Generous by default
#                      precisely because it is free (see the sparse note).
#                      MEASURED: this grows the LAST partition only — SteamOS's
#                      own growfs unit expands /home into it on the guest's
#                      first boot (2G -> 62G with +60G), while the 5 GB btrfs
#                      rootfs is untouched. So it is purely a games budget and
#                      contributes nothing to provisioning: 0 is fine to just
#                      build the image, ~8-16G to boot and log into Steam,
#                      more only if you install games. It is a sparse hole, so
#                      it costs no host disk until the guest fills it.
#   --nvidia-run FILE  a local NVIDIA .run to install from, instead of letting
#                      steamos_boot.sh download it. MEASURED, and the reason
#                      this option exists: locate_or_fetch_run() only ever tries
#                      https://us.download.nvidia.com/XFree86/Linux-x86_64/<ver>/,
#                      and DATACENTER-branch drivers are not published there —
#                      570.133.20, for instance, is 404 on that path and 200 on
#                      /tesla/570.133.20/. On such a host Part 1 fails with
#                      "could not obtain the NVIDIA .run". The file's directory
#                      is bind-mounted into the image read-only and handed to
#                      steamos_boot.sh as --old-run-file, so nothing is written
#                      to your share or to the image.
#   --profile NAME     steamos (default) | compute — passed to steamos_boot.sh
#   --no-compat32      set NVKVM_NO_COMPAT32=1 (halves the space the NVIDIA
#                      userspace needs; drops the 32-bit libs Steam wants)
#   --rootfs-part N    partition number of the rootfs (default: discovered)
#   --home-part N      partition number of /home (default: discovered; "none"
#                      to skip mounting it — see MOUNTING /HOME below)
#   --boot-script FILE steamos_boot.sh to run (default: <share>/boot/steamos_boot.sh)
#   --workdir DIR      scratch + mount point (default: <out dir>/.nvkvm-image-work)
#   --force            overwrite an existing --out / --qcow2
#   --no-scratch-tmp   do not shadow the image's /tmp (see DIVERTED BULK below)
#   --no-resolv-conf   do not bind the host resolver into the image
#   -h, --help         this header
#
# Exit codes — each says which step failed, and the message says how to resume.
#   0  success                     6  --share is not an nvkvm-pv checkout
#   2  usage error                 7  loop/partition/mount setup failed
#   3  missing host tool           8  provisioning (steamos_boot.sh) failed
#   4  not enough disk space       9  sync/unmount failed — image NOT usable
#   5  image problem               10 qemu-img convert failed
#                                  11 host NVIDIA driver state unusable
#
# ── Why this runs inside a mount namespace ──────────────────────────────────
# Everything after the copy runs in `unshare -m --propagation private`. The
# bind mounts, /proc, /sys, /dev and the share mount all cease to exist when
# this process exits — including on a crash or `kill -9`, where a trap never
# runs. Without it, an interrupted run leaves a half-unmounted tree under the
# work directory that blocks every subsequent run and, worse, leaves the
# operator's real /run/nvkvm shadowed by a bind mount they did not make.
# DO NOT "simplify" this away in favour of a trap: a trap cannot survive
# SIGKILL, and this script mounts eight things deep inside someone else's
# filesystem.
#
# ── But a mount namespace does NOT isolate loop devices ─────────────────────
# `losetup` allocates from a GLOBAL kernel pool and /dev/loopN lives in the
# host's devtmpfs. A namespace does nothing for it. So there is still an
# explicit trap that runs `losetup -d`, and it detaches the device this run
# actually allocated — captured from `losetup -Pf --show` — never a hardcoded
# /dev/loop0. Getting that wrong leaves a loop device pinned to a deleted file,
# which is precisely the failure the namespace makes people assume is handled.
# (Belt and braces: the preflight also detaches any stale loop still bound to
# our own output path, so a SIGKILLed run cannot break the next one.)
#
# ── On gating, and why this script does NOT wrap steamos-update ─────────────
# 28allday/steamos-nvidia-installer — the project this whole approach is built
# on — wraps `steamos-update` and CANCELS the OS update when the driver rebuild
# fails: the new slot is marked image-invalid and the machine keeps booting the
# working one. That is a deliberate, correct design for that project, where a
# newly-booted unpatched slot means no graphics driver at all.
#
# nvkvm deliberately does the opposite, and this script must not "fix" it.
# `boot/image/nvkvm-plant-stub.path` watches /run/steamos-atomupd/reboot_for_update
# — a file Valve's own rauc hook writes — instead of sitting anywhere in rauc's
# exit path, `nvkvm-recovery.sh plant` always exits 0, and the unit declares
# SuccessExitStatus=0 1. The reason is written into those files as design note 3:
# a bug in nvkvm must NEVER be able to make SteamOS un-updatable. nvkvm can
# afford that because steamos_boot.sh is a converge script that runs at EVERY
# boot and repairs the new image by itself, with a recovery menu and
# nvkvm.skip=1 behind it — a guarantee upstream's one-shot driver install
# does not have.
#
# So: nothing this script writes into the image may gate a SteamOS update on an
# exit status. This script is host-side and offline, entirely outside the update
# path, so its OWN exit codes are meaningful and specific (see above) — which is
# the same convention steamos_boot.sh uses for the operator-facing half.
#
# ── MOUNTING /HOME ──────────────────────────────────────────────────────────
# steamos_boot.sh builds the module in a 1 GB ext4 loopback at
# /home/.nvkvm-build.img and caches the NVIDIA .run under /home/deck/... — both
# inside the target root. With only the rootfs mounted those land on the ~5 GB
# btrfs rootfs, which is exactly the partition that has no room. Mounting the
# image's own home partition puts them where they will be at runtime. The
# manual sequence in the README does not do this; see docs/manual-install.md.
#
# ── DIVERTED BULK ───────────────────────────────────────────────────────────
# install_nvidia_userspace() diverts FIRMWARE/CUDA_LIB/OPENCL_LIB (~620 MB) to
# /tmp/nvkvm-discard inside the target root, then deletes it. On a LIVE guest
# /tmp is tmpfs, so that costs no disk. Offline, against a mounted image, /tmp
# is a real directory on the 5 GB btrfs rootfs and the diversion writes every
# byte it was supposed to avoid writing. We shadow the image's /tmp with a bind
# to the work directory, so the bulk lands on the host and vanishes with the
# namespace. --no-scratch-tmp restores the literal manual behaviour.
#
# Host needs: root, losetup, sgdisk, btrfs, unshare, blkid, findmnt, chroot,
# modinfo, mkfs.ext4 (steamos_boot.sh builds its build area with it), qemu-img
# (unless --no-qcow2), and a loaded NVIDIA driver (/proc/driver/nvidia/version).

set -euo pipefail

# ── Exit codes ───────────────────────────────────────────────────────────────
E_USAGE=2 E_TOOL=3 E_SPACE=4 E_IMAGE=5 E_SHARE=6
E_SETUP=7 E_PROVISION=8 E_UNMOUNT=9 E_CONVERT=10 E_HOST=11

log()  { printf '[build] %s\n' "$*" >&2; }
warn() { printf '[build] WARNING: %s\n' "$*" >&2; }
err()  { printf '[build] ERROR: %s\n' "$*" >&2; }
die()  { local c="$1"; shift; err "$*"; exit "$c"; }
step() { STEP="$1"; log "== $1"; }

# ── Defaults ─────────────────────────────────────────────────────────────────
SRC="" SHARE="" OUT="" QCOW="" BOOT_SCRIPT="" WORKDIR=""
GROW=60G PROFILE=steamos ROOTFS_PART_NUM="" HOME_PART_NUM="" NVIDIA_RUN=""
MAKE_QCOW2=1 FORCE=0 NO_COMPAT32=0 SCRATCH_TMP=1 BIND_RESOLV=1
SHARE_MNT="${NVKVM_SHARE_MNT:-/run/nvkvm}"
STAGE2=0
STEP="startup"

while [ $# -gt 0 ]; do
    case "$1" in
        --src)           SRC="${2:?--src needs a path}"; shift 2 ;;
        --share)         SHARE="${2:?--share needs a path}"; shift 2 ;;
        --out)           OUT="${2:?--out needs a path}"; shift 2 ;;
        --qcow2)         QCOW="${2:?--qcow2 needs a path}"; shift 2 ;;
        --no-qcow2)      MAKE_QCOW2=0; shift ;;
        --grow)          GROW="${2:?--grow needs a size}"; shift 2 ;;
        --nvidia-run)    NVIDIA_RUN="${2:?--nvidia-run needs a path}"; shift 2 ;;
        --profile)       PROFILE="${2:?--profile needs a name}"; shift 2 ;;
        --no-compat32)   NO_COMPAT32=1; shift ;;
        --rootfs-part)   ROOTFS_PART_NUM="${2:?--rootfs-part needs a number}"; shift 2 ;;
        --home-part)     HOME_PART_NUM="${2:?--home-part needs a number or 'none'}"; shift 2 ;;
        --boot-script)   BOOT_SCRIPT="${2:?--boot-script needs a path}"; shift 2 ;;
        --workdir)       WORKDIR="${2:?--workdir needs a path}"; shift 2 ;;
        --force)         FORCE=1; shift ;;
        --no-scratch-tmp) SCRATCH_TMP=0; shift ;;
        --no-resolv-conf) BIND_RESOLV=0; shift ;;
        --internal-stage2) STAGE2=1; shift ;;   # re-exec marker, not for humans
        -h|--help)       awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 0 ;;
        *)               die "$E_USAGE" "unknown argument: $1 (try --help)" ;;
    esac
done

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 1 — validate everything and touch nothing, then re-exec into a mount
# namespace. Nothing below this line writes to disk.
# ═════════════════════════════════════════════════════════════════════════════
if [ "$STAGE2" -eq 0 ]; then
    step "preflight"
    [ "$(id -u)" = 0 ] || die "$E_USAGE" "must run as root (losetup, mount, chroot)"

    [ -n "$SRC" ]   || die "$E_USAGE" "--src <pristine SteamOS .img> is required"
    [ -n "$SHARE" ] || die "$E_USAGE" "--share <nvkvm-pv checkout> is required"
    case "$PROFILE" in steamos|compute) ;; *) die "$E_USAGE" "unknown profile '$PROFILE' (steamos|compute)" ;; esac

    # Tools. Fail naming everything that is missing, in one message, before
    # anything has been created — the whole point of a preflight.
    NEEDED=(losetup sgdisk btrfs unshare blkid findmnt chroot modinfo
            mkfs.ext4 mount umount cp truncate stat awk sed numfmt)
    [ "$MAKE_QCOW2" -eq 1 ] && NEEDED+=(qemu-img)
    MISSING=()
    for t in "${NEEDED[@]}"; do command -v "$t" >/dev/null 2>&1 || MISSING+=("$t"); done
    [ ${#MISSING[@]} -eq 0 ] || die "$E_TOOL" \
        "missing host tool(s): ${MISSING[*]} — install them and re-run (btrfs=btrfs-progs, sgdisk=gptfdisk, modinfo=kmod, unshare/losetup=util-linux)"

    [ -f "$SRC" ] || die "$E_IMAGE" "--src not found: $SRC"
    SRC="$(readlink -f "$SRC")"
    case "$(basename "$SRC")" in
        *-nvkvm.img) die "$E_IMAGE" "--src looks like an image this script already produced. Start from the pristine recovery image." ;;
    esac

    SHARE="$(readlink -f "$SHARE")"
    [ -d "$SHARE" ] || die "$E_SHARE" "--share not found: $SHARE"
    [ -n "$BOOT_SCRIPT" ] || BOOT_SCRIPT="$SHARE/boot/steamos_boot.sh"
    # The single most common mistake, and it fails late and confusingly if we
    # let it through: the share must be nvkvm-pv, not nvkvm-steamos. The module
    # is built from <share>/src/guest.
    [ -d "$SHARE/src/guest" ] || die "$E_SHARE" \
        "$SHARE has no src/guest — this is not an nvkvm-pv checkout. The 9p share must be nvkvm-pv (the repo whose guest module gets built), not nvkvm-steamos."
    [ -x "$BOOT_SCRIPT" ] || die "$E_SHARE" "boot script not found or not executable: $BOOT_SCRIPT"
    [ -d "$SHARE/boot/image" ] || die "$E_SHARE" \
        "$SHARE/boot/image is missing — install_stub() would skip the systemd units and the guest would never converge on its own."
    # repo_commit() runs `git -C <share> rev-parse HEAD` as root. If git refuses
    # the checkout it returns empty, the .commit stamp is written empty, and the
    # guest then rebuilds the module on EVERY boot without ever saying why.
    git -C "$SHARE" rev-parse HEAD >/dev/null 2>&1 || warn \
        "git cannot read $SHARE as root (dubious ownership?). steamos_boot.sh stamps the module with an empty commit and will rebuild it on every boot. Fix with: git config --global --add safe.directory $SHARE"
    [ -r "$SHARE/data/authorized_keys" ] || log \
        "no $SHARE/data/authorized_keys — sshd will be left disabled in the image (drop a key there and re-run to enable it)"

    # host_driver_version() reads this. If it is unreadable steamos_boot.sh only
    # WARNS and still returns rc=0 — you would get a finished image with no
    # NVIDIA userspace in it at all. Refuse here instead.
    [ -r /proc/driver/nvidia/version ] || die "$E_HOST" \
        "/proc/driver/nvidia/version is not readable — the NVIDIA driver is not loaded on this host. steamos_boot.sh would skip the NVIDIA userspace install with only a warning and still report success, producing an image with no driver in it."
    HOSTVER="$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+/) {print $i; exit}}' /proc/driver/nvidia/version)"
    [ -n "$HOSTVER" ] || die "$E_HOST" "could not parse a driver version out of /proc/driver/nvidia/version"
    log "host NVIDIA driver: $HOSTVER (the image is pinned to this version)"
    if [ -n "$NVIDIA_RUN" ]; then
        [ -r "$NVIDIA_RUN" ] || die "$E_USAGE" "--nvidia-run not readable: $NVIDIA_RUN"
        NVIDIA_RUN="$(readlink -f "$NVIDIA_RUN")"
        # locate_or_fetch_run() looks the file up BY NAME, so the name has to be
        # the one it will ask for.
        [ "$(basename "$NVIDIA_RUN")" = "NVIDIA-Linux-x86_64-${HOSTVER}.run" ] || die "$E_USAGE" \
            "--nvidia-run must be named NVIDIA-Linux-x86_64-${HOSTVER}.run to match this host's driver; got $(basename "$NVIDIA_RUN")"
        log "NVIDIA .run supplied locally: $NVIDIA_RUN"
    fi

    [ -n "$OUT" ]  || OUT="${SRC%.img}-nvkvm.img"
    OUT="$(readlink -f -m "$OUT")"
    [ "$OUT" != "$SRC" ] || die "$E_USAGE" "--out is the same file as --src"
    [ -n "$QCOW" ] || QCOW="${OUT%.img}.qcow2"
    QCOW="$(readlink -f -m "$QCOW")"
    OUTDIR="$(dirname "$OUT")"
    [ -d "$OUTDIR" ] || die "$E_USAGE" "output directory does not exist: $OUTDIR"
    [ -n "$WORKDIR" ] || WORKDIR="$OUTDIR/.nvkvm-image-work"
    WORKDIR="$(readlink -f -m "$WORKDIR")"

    for f in "$OUT" "$QCOW"; do
        [ "$f" = "$QCOW" ] && [ "$MAKE_QCOW2" -eq 0 ] && continue
        [ -e "$f" ] || continue
        [ "$FORCE" -eq 1 ] || die "$E_USAGE" "$f exists — move it aside or pass --force"
    done

    # A loop device still bound to our output from a SIGKILLed run would pin a
    # file we are about to delete and recreate. Reclaim ours, and only ours.
    while read -r stale; do
        [ -n "$stale" ] || continue
        warn "detaching stale loop device $stale left bound to $OUT"
        losetup -d "$stale" 2>/dev/null || die "$E_SETUP" \
            "could not detach $stale (still mounted somewhere?). Run: findmnt -rn -S $stale ; losetup -d $stale"
    done < <(losetup -j "$OUT" -O NAME --noheadings 2>/dev/null || true)

    # ── Space. A mid-way ENOSPC on a btrfs image is genuinely nasty to
    # diagnose: nvidia-installer dies with SIGBUS half-installed and the image
    # looks provisioned. Check before the copy, not during it.
    step "space check"
    SRC_BYTES="$(stat -c %s "$SRC")"
    if [ "$GROW" = 0 ] || [ "$GROW" = "0" ]; then GROW_BYTES=0
    else GROW_BYTES="$(numfmt --from=iec "${GROW#+}" 2>/dev/null)" || die "$E_USAGE" "--grow: not a size: $GROW"
    fi
    # The copy, plus ~2 GiB for the extracted .run payload (measured 1.4 GB) and
    # the shadowed /tmp, plus the qcow2 (bounded by the raw size).
    SCRATCH_BYTES=$((2 * 1024 * 1024 * 1024))
    NEED=$((SRC_BYTES + SCRATCH_BYTES))
    [ "$MAKE_QCOW2" -eq 1 ] && NEED=$((NEED + SRC_BYTES))
    AVAIL="$(df -PB1 "$OUTDIR" | awk 'NR==2{print $4}')"
    # If --workdir is on a different filesystem, the payload extraction and the
    # shadowed /tmp land there instead — check that one too.
    WD_PARENT="$WORKDIR"; while [ ! -d "$WD_PARENT" ] && [ "$WD_PARENT" != / ]; do WD_PARENT="$(dirname "$WD_PARENT")"; done
    if [ "$(stat -c %d "$WD_PARENT")" != "$(stat -c %d "$OUTDIR")" ]; then
        WD_AVAIL="$(df -PB1 "$WD_PARENT" | awk 'NR==2{print $4}')"
        [ "$WD_AVAIL" -ge "$SCRATCH_BYTES" ] || die "$E_SPACE" \
            "--workdir $WORKDIR has only $(numfmt --to=iec "$WD_AVAIL") free; the extracted NVIDIA payload alone is ~1.4 GB."
        NEED=$((NEED - SCRATCH_BYTES))
    fi
    log "free in $OUTDIR: $(numfmt --to=iec "$AVAIL"), need at least $(numfmt --to=iec "$NEED")"
    [ "$AVAIL" -ge "$NEED" ] || die "$E_SPACE" \
        "not enough free space in $OUTDIR: have $(numfmt --to=iec "$AVAIL"), need $(numfmt --to=iec "$NEED"). Free space, or use --workdir/--out on a bigger filesystem."
    # The +60G is a hole, so it costs nothing today — but the guest's /home
    # grows into it on first boot and the work image will fill up for real.
    if [ "$GROW_BYTES" -gt 0 ] && [ "$AVAIL" -lt $((NEED + GROW_BYTES)) ]; then
        warn "the grown image can reach $(numfmt --to=iec $((SRC_BYTES + GROW_BYTES))) as the guest uses /home, and $OUTDIR has $(numfmt --to=iec "$AVAIL") free. The build will succeed (truncate makes a sparse hole); the guest may hit ENOSPC later."
    fi

    log "input : $SRC ($(numfmt --to=iec "$SRC_BYTES"))"
    log "share : $SHARE"
    log "output: $OUT$([ "$MAKE_QCOW2" -eq 1 ] && printf ' + %s' "$QCOW")"

    # Everything validated. Hand the resolved state to stage 2 through the
    # environment (no re-quoting of user paths through another argv) and re-exec
    # inside a private mount namespace. `exec` on purpose: one process owns the
    # namespace, the loop device and the cleanup trap, so there is nothing to
    # orphan.
    export _BSI_SRC="$SRC" _BSI_SHARE="$SHARE" _BSI_OUT="$OUT" _BSI_QCOW="$QCOW"
    export _BSI_BOOT_SCRIPT="$BOOT_SCRIPT" _BSI_WORKDIR="$WORKDIR" _BSI_GROW="$GROW"
    export _BSI_PROFILE="$PROFILE" _BSI_ROOTFS_PART="$ROOTFS_PART_NUM" _BSI_HOME_PART="$HOME_PART_NUM"
    export _BSI_QCOW2="$MAKE_QCOW2" _BSI_NO_COMPAT32="$NO_COMPAT32" _BSI_NVIDIA_RUN="$NVIDIA_RUN"
    export _BSI_SCRATCH_TMP="$SCRATCH_TMP" _BSI_RESOLV="$BIND_RESOLV" _BSI_SHARE_MNT="$SHARE_MNT"
    log "entering a private mount namespace (mounts cannot leak to the host)"
    exec unshare -m --propagation private -- "$0" --internal-stage2
fi

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 2 — inside the mount namespace. From here on every mount is invisible
# to the host and dies with this process.
# ═════════════════════════════════════════════════════════════════════════════
SRC="${_BSI_SRC:?stage 2 started without stage 1 — do not call --internal-stage2 by hand}"
SHARE="$_BSI_SHARE"; OUT="$_BSI_OUT"; QCOW="$_BSI_QCOW"
BOOT_SCRIPT="$_BSI_BOOT_SCRIPT"; WORKDIR="$_BSI_WORKDIR"; GROW="$_BSI_GROW"
PROFILE="$_BSI_PROFILE"; ROOTFS_PART_NUM="$_BSI_ROOTFS_PART"; HOME_PART_NUM="$_BSI_HOME_PART"
MAKE_QCOW2="$_BSI_QCOW2"; NO_COMPAT32="$_BSI_NO_COMPAT32"; NVIDIA_RUN="$_BSI_NVIDIA_RUN"
SCRATCH_TMP="$_BSI_SCRATCH_TMP"; BIND_RESOLV="$_BSI_RESOLV"; SHARE_MNT="$_BSI_SHARE_MNT"

MNT="$WORKDIR/rootfs"
LOOPDEV=""
SUCCESS=0
SHARE_MNT_MADE=0
RESOLV_MADE=""

# ── Leftover chroot processes ────────────────────────────────────────────────
# MEASURED: `ensure_pacman_keyring` runs `pacman-key --init` INSIDE the chroot,
# which starts a gpg-agent (and dirmngr). Those daemons outlive Part 1 with
# their root and cwd inside the mounted image, so `umount -R` fails with
# "target is busy" — and that is exactly the moment someone reaches for
# `umount -l` and silently corrupts the image. Kill them first.
#
# Deliberately NOT `fuser -k`: we resolve /proc/<pid>/root and /proc/<pid>/cwd
# ourselves and only ever signal a process that is genuinely inside OUR tree.
kill_chroot_leftovers() {
    local p pid t signalled=0
    for sig in TERM KILL; do
        signalled=0
        for p in /proc/[0-9]*; do
            pid="${p#/proc/}"
            [ "$pid" = "$$" ] && continue
            t="$(readlink "$p/root" 2>/dev/null || true)"
            case "$t" in "$MNT"|"$MNT"/*) ;; *)
                t="$(readlink "$p/cwd" 2>/dev/null || true)"
                case "$t" in "$MNT"|"$MNT"/*) ;; *) continue ;; esac ;;
            esac
            log "killing leftover chroot process $pid ($(cat "$p/comm" 2>/dev/null || echo ?)) with SIG$sig"
            kill -"$sig" "$pid" 2>/dev/null || true
            signalled=1
        done
        [ "$signalled" = 1 ] || return 0
        sleep 1
    done
}

# ── Cleanup ─────────────────────────────────────────────────────────────────
# The mount namespace already guarantees the mounts go away. This trap exists
# for the two things it does NOT cover:
#   1. the loop device — global kernel state, allocated by us, ours to free;
#   2. the partial output — an image that got half-provisioned must not be left
#      lying around looking finished.
# It also unmounts explicitly so that ordinary failures still flush and release
# in a defined order rather than relying on process teardown.
# shellcheck disable=SC2317  # everything here runs from the EXIT trap
cleanup() {
    local rc=$?
    set +e
    if mountpoint -q "$MNT" 2>/dev/null; then
        kill_chroot_leftovers 2>/dev/null
        sync
        # never -l: a lazy unmount returns before writeback finishes.
        umount -R "$MNT" || err "could not unmount $MNT — leftovers: $(findmnt -rn -o TARGET | grep "^$MNT" | tr '\n' ' ')"
    fi
    mountpoint -q "$SHARE_MNT" 2>/dev/null && umount "$SHARE_MNT" 2>/dev/null
    [ "$SHARE_MNT_MADE" = 1 ] && rmdir "$SHARE_MNT" 2>/dev/null
    if [ -n "$LOOPDEV" ]; then
        # Detach the device WE allocated. Never a hardcoded /dev/loop0.
        losetup -d "$LOOPDEV" 2>/dev/null || \
            warn "could not detach $LOOPDEV — run: losetup -d $LOOPDEV"
    fi
    if [ "$SUCCESS" != 1 ]; then
        if [ -e "$OUT" ] && ! findmnt -rn -o TARGET 2>/dev/null | grep -q "^$MNT"; then
            warn "removing the partial output $OUT (the input $SRC is untouched)"
            rm -f "$OUT"
        elif [ -e "$OUT" ]; then
            err "$OUT is still mounted and was left in place — it is NOT usable. Unmount it, then delete it."
        fi
        [ "$rc" != 0 ] && err "failed during: $STEP"
    fi
    if ! findmnt -rn -o TARGET 2>/dev/null | grep -q "^$WORKDIR"; then
        rm -rf "$WORKDIR" 2>/dev/null
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$WORKDIR" "$MNT" || die "$E_SETUP" "could not create the work directory $WORKDIR"
# A mount inherited from the host at our mount point would be silently written
# through. Undo it here — private propagation means the host keeps its own.
if mountpoint -q "$MNT" 2>/dev/null; then
    warn "something was already mounted at $MNT (inherited from the host); unmounting it in our namespace"
    umount -R "$MNT" || die "$E_SETUP" "could not clear the inherited mount at $MNT"
fi

# ── 1. Copy. The input is never opened for writing, here or anywhere else. ──
step "1/9 copying $SRC -> $OUT"
rm -f "$OUT"
cp --reflink=auto --sparse=always "$SRC" "$OUT" || die "$E_IMAGE" "copy failed"

# ── 2. Grow, then relocate the backup GPT header ─────────────────────────────
# truncate moves end-of-disk; the GPT's BACKUP header is still sitting at the
# old end. Linux tolerates that (lsblk and mount work fine, which is why this
# is so easy to miss), OVMF does not — it finds no bootable device and says
# nothing about the GPT. `sgdisk -e` relocates it. It must run against a LOOP
# device: against /dev/nbd0 sgdisk fails with "Read error 5", reports zero
# partitions, and its write silently does nothing.
if [ "$GROW" != 0 ]; then
    step "2/9 growing the disk by ${GROW#+}"
    truncate -s "+${GROW#+}" "$OUT" || die "$E_IMAGE" "truncate failed"
fi

step "3/9 attaching a loop device"
LOOPDEV="$(losetup -Pf --show "$OUT")" || die "$E_SETUP" "losetup failed"
[ -n "$LOOPDEV" ] || die "$E_SETUP" "losetup printed no device name"
log "loop device: $LOOPDEV (this run's; the trap detaches exactly this one)"
settle() { command -v udevadm >/dev/null 2>&1 || return 0; udevadm settle --timeout=10 >/dev/null 2>&1 || true; }
settle
i=0; while [ ! -b "${LOOPDEV}p1" ] && [ "$i" -lt 50 ]; do i=$((i+1)); sleep 0.1; done
[ -b "${LOOPDEV}p1" ] || die "$E_SETUP" "no partitions appeared on $LOOPDEV — is $SRC a partitioned disk image?"

if [ "$GROW" != 0 ]; then
    step "4/9 relocating the backup GPT header (sgdisk -e)"
    sgdisk -e "$LOOPDEV" >/dev/null || die "$E_IMAGE" \
        "sgdisk -e failed on $LOOPDEV. Without it OVMF finds no bootable device and hangs before GRUB with no error."
    partprobe "$LOOPDEV" 2>/dev/null || true
    settle
fi

# ── 5. Discover the rootfs partition. Never hardcode it. ─────────────────────
# The repair image happens to be p3, an installed A/B system is not, and Valve
# has changed the layout before. Match on the GPT partition NAME the image
# itself carries; fall back to "the only btrfs partition"; refuse to guess.
step "5/9 discovering partitions"
ROOTPART="" HOMEPART="" ; BTRFS_PARTS=()
for p in "$LOOPDEV"p*; do
    [ -b "$p" ] || continue
    pname="$(blkid -p -s PART_ENTRY_NAME -o value "$p" 2>/dev/null || true)"
    ptype="$(blkid -s TYPE -o value "$p" 2>/dev/null || true)"
    log "  $p  name=${pname:-<none>}  fs=${ptype:-<none>}"
    [ "$ptype" = btrfs ] && BTRFS_PARTS+=("$p")
    case "$pname" in
        rootfs-A|rootfs) ROOTPART="$p" ;;
        rootfs-*)        [ -n "$ROOTPART" ] || ROOTPART="$p" ;;
        home)            HOMEPART="$p" ;;
    esac
done
if [ -n "$ROOTFS_PART_NUM" ]; then
    ROOTPART="${LOOPDEV}p${ROOTFS_PART_NUM}"
    [ -b "$ROOTPART" ] || die "$E_IMAGE" "--rootfs-part $ROOTFS_PART_NUM: $ROOTPART is not a block device"
elif [ -z "$ROOTPART" ]; then
    if [ "${#BTRFS_PARTS[@]}" -eq 1 ]; then
        ROOTPART="${BTRFS_PARTS[0]}"
        log "no partition named rootfs*; using the only btrfs partition, $ROOTPART"
    else
        die "$E_IMAGE" "could not identify the rootfs partition on $LOOPDEV (no rootfs* GPT name, ${#BTRFS_PARTS[@]} btrfs partitions). Pass --rootfs-part N."
    fi
fi
case "$HOME_PART_NUM" in
    none) HOMEPART="" ;;
    "")   ;;
    *)    HOMEPART="${LOOPDEV}p${HOME_PART_NUM}"
          [ -b "$HOMEPART" ] || die "$E_IMAGE" "--home-part $HOME_PART_NUM: $HOMEPART is not a block device" ;;
esac
log "rootfs: $ROOTPART   home: ${HOMEPART:-<not mounted>}"

# ── 6. Mount, and make the rootfs writable ───────────────────────────────────
# SteamOS ships an immutable rootfs: the btrfs subvolume carries ro=true, so
# every write fails with EROFS no matter how the block device is mounted.
# steamos_boot.sh clears it per-operation itself, but it also RESTORES whatever
# it found on entry — clearing it here first is what makes the finished image
# ship writable, which is the state the documented path produces.
step "6/9 mounting the rootfs"
mount "$ROOTPART" "$MNT" || die "$E_SETUP" "could not mount $ROOTPART at $MNT"
btrfs property set "$MNT" ro false || die "$E_SETUP" "could not clear the btrfs read-only property on $MNT"
if ! { [ -d "$MNT/usr/lib/modules" ] && [ -e "$MNT/etc/pacman.conf" ]; }; then
    die "$E_IMAGE" "$ROOTPART does not look like a SteamOS rootfs (no /usr/lib/modules or /etc/pacman.conf). Wrong partition? Pass --rootfs-part N."
fi

if [ -n "$HOMEPART" ]; then
    # Resolve /home the way the image itself does before mounting onto it.
    homedir="$MNT/home"
    if [ -L "$MNT/home" ]; then
        link="$(readlink "$MNT/home")"
        case "$link" in /*) homedir="$MNT$link" ;; *) homedir="$MNT/$link" ;; esac
        log "/home in the image is a symlink to $link"
    fi
    if mkdir -p "$homedir" 2>/dev/null && mount "$HOMEPART" "$homedir" 2>/dev/null; then
        log "mounted $HOMEPART at ${homedir#"$MNT"} (module build area + .run cache land here)"
    else
        warn "could not mount $HOMEPART — the 1 GB build area and the NVIDIA .run cache will land on the rootfs instead, which is the partition with no room"
        HOMEPART=""
    fi
fi

# ── 7. Everything the chroot needs ───────────────────────────────────────────
# steamos_boot.sh chroots into the target for pacman, curl, nvidia-installer,
# ldconfig and depmod, but it does NOT set up /proc, /sys or /dev itself — its
# other two callers (nvkvm-recovery.sh plant, build_nvkvm_steamos_image.sh)
# both do it for it, and so must we.
step "7/9 preparing the chroot and the 9p stand-in"
mkdir -p "$MNT/proc" "$MNT/sys" "$MNT/dev"   # present in any real rootfs; cheap to be sure
mount --bind /proc "$MNT/proc" || die "$E_SETUP" "bind /proc failed"
mount --bind /sys  "$MNT/sys"  || die "$E_SETUP" "bind /sys failed"
mount --rbind /dev "$MNT/dev"  || die "$E_SETUP" "bind /dev failed"

if [ "$SCRATCH_TMP" = 1 ]; then
    # See DIVERTED BULK in the header.
    mkdir -p "$WORKDIR/tmp" "$MNT/tmp"
    mount --bind "$WORKDIR/tmp" "$MNT/tmp" || die "$E_SETUP" "could not shadow the image's /tmp"
    log "image /tmp shadowed by $WORKDIR/tmp (diverted CUDA/OpenCL/firmware bulk stays off the rootfs)"
fi

if [ "$BIND_RESOLV" = 1 ]; then
    # The single most common Part 1 failure: pacman inside the chroot cannot
    # resolve Valve's mirror and the run ends rc=1. Bind rather than copy, so
    # the host's DNS config is never baked into the image.
    rt="$MNT/etc/resolv.conf"
    if [ -L "$rt" ]; then
        rl="$(readlink "$rt")"; case "$rl" in /*) rt="$MNT$rl" ;; *) rt="$MNT/etc/$rl" ;; esac
    fi
    if [ -r /etc/resolv.conf ]; then
        mkdir -p "$(dirname "$rt")"
        if [ ! -e "$rt" ]; then : > "$rt" && RESOLV_MADE="$rt"; fi
        if mount --bind /etc/resolv.conf "$rt"; then
            log "host resolver bound at ${rt#"$MNT"} for the chroot"
        else
            warn "could not bind a resolver into the image; the pacman step may fail with 'Could not resolve host'"
        fi
    fi
fi

# A locally-supplied .run: bind its directory in read-only and point
# steamos_boot.sh's cache at it. /run inside the image is empty on disk and a
# tmpfs at boot, so nothing here can end up in the finished image.
RUN_CACHE_IN_IMAGE=/run/nvkvm-runs
if [ -n "$NVIDIA_RUN" ]; then
    mkdir -p "$MNT$RUN_CACHE_IN_IMAGE"
    mount --bind "$(dirname "$NVIDIA_RUN")" "$MNT$RUN_CACHE_IN_IMAGE" \
        || die "$E_SETUP" "could not bind the .run directory into the image"
    mount -o remount,bind,ro "$MNT$RUN_CACHE_IN_IMAGE" || warn "could not make the .run bind read-only"
    log "NVIDIA .run directory bound at $RUN_CACHE_IN_IMAGE (read-only)"
fi

# The bind mount stands in for the 9p share the guest gets at runtime
# (-virtfs ... mount_tag=nvkvm,readonly=on). Mounted read-only for the same
# reason the real share is: nothing in the image build may write to the
# operator's nvkvm-pv checkout.
[ -d "$SHARE_MNT" ] || SHARE_MNT_MADE=1     # only rmdir it later if it was ours
mkdir -p "$SHARE_MNT" || die "$E_SETUP" "could not create $SHARE_MNT"
if mountpoint -q "$SHARE_MNT"; then
    umount "$SHARE_MNT" || die "$E_SETUP" "$SHARE_MNT is already a mountpoint and will not release"
fi
mount --bind "$SHARE" "$SHARE_MNT" || die "$E_SETUP" "could not bind $SHARE at $SHARE_MNT"
mount -o remount,bind,ro "$SHARE_MNT" || warn "could not make $SHARE_MNT read-only"
log "share bound at $SHARE_MNT (namespace-local; the host's $SHARE_MNT is untouched)"

# ── 8. The actual provisioning ───────────────────────────────────────────────
step "8/9 running $(basename "$BOOT_SCRIPT") --install-only --root $MNT"
BOOT_ENV=(NVKVM_SHARE_MNT="$SHARE_MNT")
[ "$NO_COMPAT32" = 1 ] && BOOT_ENV+=(NVKVM_NO_COMPAT32=1)
BOOT_ARGS=(--install-only --root "$MNT" --profile "$PROFILE")
[ -n "$NVIDIA_RUN" ] && BOOT_ARGS+=(--old-run-file "$RUN_CACHE_IN_IMAGE")
set +e
env "${BOOT_ENV[@]}" "$BOOT_SCRIPT" "${BOOT_ARGS[@]}"
prc=$?
set -e
[ "$prc" -eq 0 ] || die "$E_PROVISION" \
    "steamos_boot.sh --install-only returned $prc. Read its [nvkvm] log above — it names what failed. Common causes: no resolver in the chroot, Valve's pool no longer carries headers for this image's kernel (use a newer recovery image), or not enough room on the rootfs (try --no-compat32). Nothing was kept; re-run this script after fixing it."

# Verify the image rather than trusting rc=0. Part 1 returns 0 in states that
# are not usable — most notably it only WARNS when it cannot read the host
# driver version, and install_stub failures are swallowed with `|| true`.
step "8b/9 verifying the provisioned image"
vfail=""
kver="$(for d in "$MNT"/usr/lib/modules/*; do [ -e "$d/vmlinuz" ] && basename "$d" && break; done)"
[ -n "$kver" ] || vfail="$vfail\n  - no kernel with a vmlinuz under /usr/lib/modules"
[ -n "$kver" ] && [ -s "$MNT/usr/lib/modules/$kver/updates/nvkvm-guest.ko" ] \
    || vfail="$vfail\n  - nvkvm-guest.ko missing (or empty) for kernel ${kver:-?}"
for lib in libnvidia-glcore libnvidia-glsi libnvidia-tls libGLX_nvidia; do
    ls "$MNT"/usr/lib/"$lib".so.* >/dev/null 2>&1 || vfail="$vfail\n  - $lib missing from /usr/lib"
done
# The 0-byte-libnvidia-ml class of failure, caught on the mount rather than
# after conversion: any zero-length .so means the install did not complete.
if [ -n "$(find "$MNT/usr/lib" -maxdepth 1 -name 'libnvidia-*.so.*' -size 0 -print -quit 2>/dev/null)" ]; then
    vfail="$vfail\n  - zero-length libnvidia-*.so.* in /usr/lib (incomplete install)"
fi
# -s, not -e: install_stub()'s failures are swallowed with `|| true`, and a
# zero-length nvkvm-recovery.sh is a working-looking unit that does nothing.
for u in etc/systemd/system/nvkvm-boot.service etc/systemd/system/nvkvm-plant-stub.path \
         etc/systemd/system/nvkvm-plant-stub.service usr/local/sbin/nvkvm-recovery.sh \
         etc/modules-load.d/nvkvm.conf etc/modprobe.d/99-nvkvm.conf; do
    [ -s "$MNT/$u" ] || vfail="$vfail\n  - /$u not installed (or empty)"
done
[ -z "$vfail" ] || die "$E_PROVISION" "$(printf 'the image is NOT provisioned correctly:%b' "$vfail")"
log "verified: module for $kver, NVIDIA userspace, units and modprobe config all present"

# ── 9. Flush, unmount for real, detach, convert ──────────────────────────────
# NEVER `umount -l` here. A lazy unmount detaches the tree from the namespace
# and RETURNS IMMEDIATELY, while writeback is still in flight; the next thing
# we do reads the backing file. That was measured: the qcow2 came out with a
# 0-byte libnvidia-ml.so while the same file was 2.2 MB on the mount that had
# just been "released", and it presented as a driver bug for hours. `sync`
# first, then a real unmount, and only then touch the file.
unmount_everything() {
    kill_chroot_leftovers
    sync
    sync -f "$MNT" 2>/dev/null || true
    umount -R "$MNT" || return 1
    mountpoint -q "$SHARE_MNT" && { umount "$SHARE_MNT" || return 1; }
    sync
    return 0
}
step "9/9 syncing and unmounting"
# Undo the resolver bind and delete the placeholder we created BEFORE the
# recursive unmount — afterwards the path is gone with the mount and the
# removal would silently do nothing, leaving an empty file in the image.
if [ -n "$RESOLV_MADE" ]; then
    umount "$RESOLV_MADE" 2>/dev/null || true
    rm -f "$RESOLV_MADE"
fi
if ! unmount_everything; then
    err "something under $MNT is still busy:"
    findmnt -rn -o TARGET,SOURCE | grep "^$MNT" >&2 || true
    die "$E_UNMOUNT" "refusing to image a filesystem that is still mounted — a lazy unmount would return before writeback finished and produce a silently corrupt image. Close whatever holds it (fuser -vm $MNT), then re-run this script from the start."
fi
losetup -d "$LOOPDEV" || die "$E_UNMOUNT" "could not detach $LOOPDEV — do not use $OUT until it is released"
LOOPDEV=""

if [ "$MAKE_QCOW2" = 1 ]; then
    step "9b/9 converting to qcow2"
    rm -f "$QCOW"
    qemu-img convert -f raw -O qcow2 "$OUT" "$QCOW" || {
        rm -f "$QCOW"
        die "$E_CONVERT" "qemu-img convert failed. The work image $OUT is finished and valid — re-run just the conversion: qemu-img convert -f raw -O qcow2 $OUT $QCOW"
    }
fi

SUCCESS=1
log "done."
log "  work image : $OUT"
[ "$MAKE_QCOW2" = 1 ] && log "  qcow2      : $QCOW"
log ""
log "Boot it with:"
log "  QCOW=$([ "$MAKE_QCOW2" = 1 ] && printf '%s' "$QCOW" || printf '%s' "$OUT") \\"
log "  SHARE=$SHARE \\"
log "  QEMU=/opt/qemu-nvkvm/bin/qemu-system-x86_64 \\"
log "    boot/run_steamos_nvkvm.sh"
exit 0
