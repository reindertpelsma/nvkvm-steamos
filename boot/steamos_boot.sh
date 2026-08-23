#!/usr/bin/env bash
# steamos_boot.sh — single self-repairing nvkvm provisioning + boot script for
# SteamOS guests running under nvkvm-pv.
#
# One mechanism, run at every boot, that converges the system to a KNOWN state.
# There is no "fresh install" path and no "update" path: every step is
# check-then-act and is safe to re-run. It lives on the read-only 9p share, so
# changing this logic never means touching the SteamOS image.
#
# Modes
#   --install-only [--root DIR]   Part 1. Filesystem + network + NVIDIA probing.
#                                 Touches NO running-kernel state, so it is safe
#                                 inside a chroot of a DIFFERENT image -- which is
#                                 exactly what the update hook does. Give it the
#                                 new image's root and it provisions that image.
#   boot                          Part 2. Part 1, then load nvkvm, validate, hand
#                                 over to the desktop.
#   validate                      Health check only.
#
# Options
#   --root DIR              operate on this root instead of /
#   --profile steamos|compute   see PROFILES below
#   --old-run-file DIR      bind-mounted cache DIRECTORY of NVIDIA .run files
#
# PROFILES (deterministic, never chosen automatically)
#   steamos  (default)  Trims CUDA/OpenCL/NVVM/OptiX. Gaming stack only.
#                       Casualty: GPU PhysX. Vulkan, GL, DXVK, VKD3D, gamescope
#                       and DLSS (libnvidia-ngx) are UNAFFECTED.
#   compute             Installs everything. Nothing is trimmed.
# The profile is NEVER switched on the basis of free disk space. If the disk is
# too small the script fails and tells you to pick a profile, exactly like
# upstream's `Rerun with --trim-cuda`. Otherwise two machines running the same
# script would end up with different capabilities depending on how full they
# happened to be, and nobody could explain why.

set -uo pipefail   # deliberately NOT -e: this script repairs and reports.

# ── Constants ────────────────────────────────────────────────────────────────
NVKVM_SHARE_TAG="${NVKVM_SHARE_TAG:-nvkvm}"
# Mount point is /run/nvkvm, NOT /mnt/nvkvm. MEASURED: in SteamOS /mnt is a symlink
# to var/mnt, and /var is a rauc-managed partition that post-install.sh REFORMATS on
# every update. /run is tmpfs, always writable, exists before any partition is
# mounted, and never survives a boot -- exactly what a mount point should be.
NVKVM_SHARE_MNT="${NVKVM_SHARE_MNT:-/run/nvkvm}"
MODULE_NAME=nvkvm-guest
MODULE_MOD=nvkvm_guest

# Upstream steamos-nvidia-installer's tested trim set, reused verbatim
# (steamos-nvidia-installer.sh:479). libnvidia-ngx is deliberately NOT here --
# that is DLSS and it must survive.
TRIM_RE='libcuda|libcudadebugger|libnvidia-nvvm|libnvidia-opencl|libnvoptix|nvidia-cuda-mps|OpenCL'

PROFILE="${NVKVM_PROFILE:-steamos}"
RUN_CACHE_DIR=""          # set by --old-run-file, else derived below
RUN_CACHE_KEEP=2
ROOT=/
MODULE_REBUILT=0          # set when this run actually rebuilt the .ko

# All diagnostics go to STDERR. `log` used to write to stdout, and helpers return
# their result via stdout -- so `run="$(locate_or_fetch_run ...)"` captured the log
# line along with the path and every extraction failed with a confusing error.
log()  { printf '[nvkvm] %s\n' "$*" >&2; }
warn() { printf '[nvkvm] WARNING: %s\n' "$*" >&2; }
err()  { printf '[nvkvm] ERROR: %s\n' "$*" >&2; }

in_target() { if [ "$ROOT" = "/" ]; then "$@"; else chroot "$ROOT" "$@"; fi; }
rp() { if [ "$ROOT" = "/" ]; then printf '%s' "$1"; else printf '%s%s' "${ROOT%/}" "$1"; fi; }

# ── Read-only state: observe it, then restore whatever we observed ───────────
# Restoring only on the happy path leaves the filesystem writable after any
# mid-script failure, which is a worse state than the one we started in.
RO_PRIOR=unknown
capture_ro_state() {
    if [ "$ROOT" = "/" ]; then
        if steamos-readonly status >/dev/null 2>&1; then RO_PRIOR=ro; else RO_PRIOR=rw; fi
    else
        case "$(btrfs property get "$ROOT" ro 2>/dev/null)" in
            *true) RO_PRIOR=ro ;; *) RO_PRIOR=rw ;;
        esac
    fi
    log "rootfs was ${RO_PRIOR} on entry"
}
steamos_unlock() {
    if [ "$ROOT" = "/" ]; then
        steamos-readonly disable 2>/dev/null || {
            mount -o remount,rw / 2>/dev/null
            btrfs property set / ro false 2>/dev/null
        }
    else
        btrfs property set "$ROOT" ro false 2>/dev/null
    fi
}
steamos_lock() {
    if [ "$ROOT" = "/" ]; then
        steamos-readonly enable 2>/dev/null || btrfs property set / ro true 2>/dev/null
    else
        btrfs property set "$ROOT" ro true 2>/dev/null
    fi
}
restore_ro_state() {
    [ "$RO_PRIOR" = ro ] && steamos_lock
    return 0
}

# ── 9p share ─────────────────────────────────────────────────────────────────
mount_9p_share() {
    if mountpoint -q "$NVKVM_SHARE_MNT" 2>/dev/null; then return 0; fi
    mkdir -p "$NVKVM_SHARE_MNT"
    modprobe 9pnet_virtio 2>/dev/null || true
    mount -t 9p -o trans=virtio,version=9p2000.L,ro,msize=512000 \
          "$NVKVM_SHARE_TAG" "$NVKVM_SHARE_MNT" 2>/dev/null
}
repo_commit() { git -C "$NVKVM_SHARE_MNT" rev-parse HEAD 2>/dev/null; }

# The record of which commit the module was built from lives NEXT TO the .ko, so
# the two cannot drift apart: delete the module and the record goes with it.
ko_path()        { printf '%s' "/usr/lib/modules/$1/updates/${MODULE_NAME}.ko"; }
ko_commit_path() { printf '%s' "$(ko_path "$1").commit"; }
built_commit()   { cat "$(rp "$(ko_commit_path "$1")")" 2>/dev/null; }

# ── Packages: query, never record ────────────────────────────────────────────
# What we installed is derived by diffing the installed set before and after,
# not by writing a list to disk. That means cleanup works correctly even on a
# root this script has never seen before.
pkgs_snapshot() { in_target sh -c 'pacman -Qq 2>/dev/null' | sort; }
PKGS_BEFORE=""

remove_added_packages() {
    local after added
    after="$(pkgs_snapshot)"
    added="$(comm -13 <(printf '%s\n' "$PKGS_BEFORE") <(printf '%s\n' "$after") 2>/dev/null)"
    [ -n "${added//[[:space:]]/}" ] || { log "no packages to remove"; return 0; }
    log "removing packages this run added: $(printf '%s' "$added" | tr '\n' ' ')"
    steamos_unlock
    in_target sh -c "pacman -Rns --noconfirm $(printf '%s' "$added" | tr '\n' ' ')" >/dev/null 2>&1 \
        || warn "could not fully remove the packages this run added"
}

ensure_pacman_keyring() {
    in_target sh -c 'pacman-key --list-keys >/dev/null 2>&1' && return 0
    log "initialising pacman keyring in the target root"
    in_target pacman-key --init >/dev/null 2>&1 || true
    local kr
    for kr in archlinux holo; do
        in_target sh -c "ls /usr/share/pacman/keyrings/${kr}.gpg >/dev/null 2>&1" \
            && in_target pacman-key --populate "$kr" >/dev/null 2>&1
    done
    in_target sh -c 'pacman-key --list-keys >/dev/null 2>&1' \
        || { err "pacman keyring could not be initialised"; return 1; }
}

# Minimum only -- deliberately NOT base-devel, which is a meta-package whose
# ~500 MB is mostly irrelevant to an out-of-tree module build on a 5 GB rootfs.
# Anything else is added reactively from real build failures.
ensure_build_deps() {
    local missing=()
    in_target sh -c 'command -v gcc  >/dev/null 2>&1' || missing+=(gcc)
    in_target sh -c 'command -v make >/dev/null 2>&1' || missing+=(make)
    [ ${#missing[@]} -eq 0 ] && { log "core build tools present"; return 0; }
    steamos_unlock; ensure_pacman_keyring || return 1
    log "installing core build tools: ${missing[*]}"
    in_target pacman -S --noconfirm --needed "${missing[@]}" \
        || { err "could not install core build tools"; return 1; }
}

pkg_for_build_failure() {
    local f="$1"
    grep -qE "flex: (command )?not found|Cannot find flex"  "$f" && { echo flex;   return 0; }
    grep -qE "bison: (command )?not found|Cannot find bison" "$f" && { echo bison;  return 0; }
    grep -qE "\bbc: (command )?not found"                    "$f" && { echo bc;     return 0; }
    grep -qE "pahole: (command )?not found|BTF: .*pahole"    "$f" && { echo pahole; return 0; }
    grep -qE "libelf|elfutils|gelf\.h"                       "$f" && { echo libelf; return 0; }
    grep -qE "openssl/|libssl|opensslconf\.h"                "$f" && { echo openssl;return 0; }
    return 1
}

# ── Kernel + module ──────────────────────────────────────────────────────────
target_kver() {
    local d
    # The kernel the image BOOTS, identified by vmlinuz. Do NOT pick "the one with
    # a build tree": installing headers creates a SECOND module directory for
    # whatever point release the repo currently ships, which has a build tree but
    # no vmlinuz, and building against it yields a module that loads nowhere.
    for d in "$(rp /usr/lib/modules)"/*; do
        [ -d "$d" ] && [ -e "$d/vmlinuz" ] && { basename "$d"; return 0; }
    done
    for d in "$(rp /usr/lib/modules)"/*; do
        [ -d "$d" ] && [ -e "$d/modules.dep" ] && { basename "$d"; return 0; }
    done
    return 1
}
target_dbpath() {
    # SteamOS sets DBPath = /usr/lib/holo/pacmandb/ , not /var/lib/pacman.
    local d; d="$(sed -n 's/^ *DBPath *= *//p' "$(rp /etc/pacman.conf)" 2>/dev/null | head -1)"
    printf '%s' "${d:-/var/lib/pacman/}"
}
kernel_pkg_nv() {
    local kver="$1" dbp d b
    dbp="$(rp "$(target_dbpath)")/local"; [ -d "$dbp" ] || return 1
    for d in "$dbp"/*/; do
        b="$(basename "$d")"
        case "$b" in *-headers-*|*firmware*|*rtw*) continue ;; esac
        grep -qs "usr/lib/modules/${kver%%-neptune*}" "$d/files" 2>/dev/null || continue
        printf '%s %s' "$(printf '%s' "$b" | sed -E 's/-[^-]+-[^-]+$//')" \
                       "$(printf '%s' "$b" | sed -E 's/^.*-([^-]+-[^-]+)$/\1/')"
        return 0
    done
    return 1
}

ensure_kernel_headers() {
    local kver="$1"
    [ -e "$(rp "/usr/lib/modules/$kver/build")" ] && { log "headers present for $kver"; return 0; }
    steamos_unlock; ensure_pacman_keyring || return 1

    # NEVER `pacman -S`. That resolves through the repo DATABASE, which indexes only
    # the newest build: asking for the image's exact version gives "target not
    # found" while the mirror POOL still serves that file with HTTP 200. Name the
    # file and fetch it, the way upstream does.
    local nv name verrel repo mirror url
    nv="$(kernel_pkg_nv "$kver")" || { err "kernel package for $kver not found in $(target_dbpath)"; return 1; }
    name="${nv%% *}"; verrel="${nv##* }"
    repo="$(awk -F'[][]' '/^\[jupiter-/{print $2; exit}' "$(rp /etc/pacman.conf)" 2>/dev/null)"
    mirror="$(awk '/^Server/{print $3; exit}' "$(rp /etc/pacman.d/mirrorlist)" 2>/dev/null)"
    [ -n "$repo" ] && [ -n "$mirror" ] || { err "could not read repo/mirror from the image"; return 1; }
    url="${mirror/\$repo/$repo}"; url="${url/\$arch/x86_64}/${name}-headers-${verrel}-x86_64.pkg.tar.zst"

    log "exact-match headers: $url"
    if ! in_target curl -sfIL --max-time 60 "$url" -o /dev/null; then
        err "Exact-match headers not in Valve's pool for kernel $kver (${name}-${verrel})."
        err "SteamOS must update to a kernel whose headers are still pooled. This"
        err "script runs at every boot and will build the module automatically once"
        err "that happens -- no manual step is needed."
        return 1
    fi
    in_target curl -sfL --max-time 600 "$url" -o /tmp/nvkvm-headers.pkg.tar.zst \
        || { err "could not download the headers package"; return 1; }
    in_target pacman -U --noconfirm --needed /tmp/nvkvm-headers.pkg.tar.zst \
        || { err "pacman -U failed for the exact-match headers"; return 1; }
    rm -f "$(rp /tmp/nvkvm-headers.pkg.tar.zst)"
    [ -e "$(rp "/usr/lib/modules/$kver/build")" ] \
        || { err "headers installed but $kver still has no build tree"; return 1; }
}

# The build area must not be a plain directory on /home: /home carries the ext4
# `casefold` feature and a casefolded directory breaks kernel builds. An ext4
# loopback image on /home gives us the space without the hazard.
BUILD_IMG_REL=/home/.nvkvm-build.img
BUILD_MNT_REL=/home/.nvkvm-build
BUILD_IMG_MB=1024
build_area_up() {
    local img mnt; img="$(rp "$BUILD_IMG_REL")"; mnt="$(rp "$BUILD_MNT_REL")"
    mkdir -p "$mnt" || return 1
    mountpoint -q "$mnt" && return 0
    rm -f "$img"
    dd if=/dev/zero of="$img" bs=1M count=0 seek="$BUILD_IMG_MB" status=none 2>/dev/null || return 1
    mkfs.ext4 -q -F "$img" >/dev/null 2>&1 || { err "mkfs on the build image failed"; return 1; }
    mount -o loop "$img" "$mnt" || { err "could not mount the build image"; return 1; }
    log "build area ready: $BUILD_MNT_REL (ext4 loopback, casefold-free)"
}
build_area_down() {
    local img mnt; img="$(rp "$BUILD_IMG_REL")"; mnt="$(rp "$BUILD_MNT_REL")"
    mountpoint -q "$mnt" && umount "$mnt" 2>/dev/null
    rm -f "$img"; rmdir "$mnt" 2>/dev/null || true
}

build_and_install_module() {
    local kver kdir src
    kver="$(target_kver)" || { err "no kernel under $(rp /usr/lib/modules)"; return 1; }
    ensure_kernel_headers "$kver" || return 1
    kdir="/usr/lib/modules/$kver/build"
    src="$NVKVM_SHARE_MNT/src"
    [ -d "$src/guest" ] || { err "nvkvm guest source not found at $src/guest"; return 1; }

    log "building $MODULE_NAME against $kver (KDIR=$kdir)"
    steamos_unlock
    build_area_up || return 1
    local scratch_rel="$BUILD_MNT_REL" scratch; scratch="$(rp "$scratch_rel")"
    # Stage the whole src/ tree: the guest sources include siblings by relative
    # path ("../../src/common/..."), so a flat copy of src/guest does not compile.
    cp -a "$src" "$scratch/src" 2>/dev/null || { err "could not stage source"; build_area_down; return 1; }
    local build_rel="$scratch_rel/src/guest" logf; logf="$(rp "$scratch_rel/build.log")"

    local attempt rc=1 need
    local t0; t0="$(date +%s)"
    for attempt in 1 2 3 4; do
        if in_target sh -c "make -C '$kdir' M='$build_rel' modules" >"$logf" 2>&1; then rc=0; break; fi
        if need="$(pkg_for_build_failure "$logf")"; then
            log "build needs '$need' -- installing and retrying"
            in_target pacman -S --noconfirm --needed "$need" \
                || { err "could not install $need"; build_area_down; return 1; }
        else
            err "build failed against $kver, cause is not a known missing tool:"
            tail -20 "$logf" >&2; build_area_down; return 1
        fi
    done
    [ $rc -eq 0 ] || { err "build still failing after reactive installs"; build_area_down; return 1; }
    log "module compile took $(( $(date +%s) - t0 ))s"

    local vm
    vm="$(modinfo -F vermagic "$scratch/src/guest/${MODULE_NAME}.ko" 2>/dev/null | awk '{print $1}')"
    if [ -n "$vm" ] && [ "$vm" != "$kver" ]; then
        err "built vermagic ($vm) != image kernel ($kver) -- refusing to install"
        build_area_down; return 1
    fi

    mkdir -p "$(rp "$(dirname "$(ko_path "$kver")")")"
    cp -f "$scratch/src/guest/${MODULE_NAME}.ko" "$(rp "$(ko_path "$kver")")" \
        || { build_area_down; return 1; }
    repo_commit > "$(rp "$(ko_commit_path "$kver")")" 2>/dev/null
    in_target depmod "$kver" || warn "depmod failed for $kver"
    build_area_down
    MODULE_REBUILT=1
    log "module built and installed for $kver"
}

# ── NVIDIA userspace ─────────────────────────────────────────────────────────
host_driver_version() {
    # Read from the RUNNING system on purpose: this is the HOST driver as nvkvm
    # exposes it, and it is what the new image must match too.
    awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+/) {print $i; exit}}' \
        /proc/driver/nvidia/version 2>/dev/null
}
installed_userspace_version() {
    in_target sh -c 'ls /usr/lib/libnvidia-glcore.so.* 2>/dev/null | head -1' \
        | sed 's/.*libnvidia-glcore\.so\.//'
}
run_cache() { printf '%s' "${RUN_CACHE_DIR:-/home/deck/.local/share/nvkvm/nvidia-runs}"; }

locate_or_fetch_run() {
    local ver="$1"
    local fname="NVIDIA-Linux-x86_64-${ver}.run"
    local candidate cached
    for candidate in "$NVKVM_SHARE_MNT/nvidia/$fname" "$NVKVM_SHARE_MNT/$fname"; do
        [ -r "$candidate" ] && { log "using .run from the 9p share"; printf '%s' "$candidate"; return 0; }
    done
    mkdir -p "$(rp "$(run_cache)")" 2>/dev/null
    cached="$(rp "$(run_cache)/$fname")"
    if [ -r "$cached" ] && sh "$cached" --check >/dev/null 2>&1; then
        log "using cached .run"; printf '%s' "$cached"; return 0
    fi
    log "downloading NVIDIA $ver"
    if in_target curl -fL --no-progress-meter --retry 3 \
         -o "$(run_cache)/$fname" \
         "https://us.download.nvidia.com/XFree86/Linux-x86_64/${ver}/${fname}"; then
        if sh "$cached" --check >/dev/null 2>&1; then
            prune_run_cache; printf '%s' "$cached"; return 0
        fi
        err ".run failed its own integrity check"; rm -f "$cached"
    fi
    return 1
}
prune_run_cache() {
    local dir; dir="$(rp "$(run_cache)")"
    ls -1t "$dir"/NVIDIA-Linux-x86_64-*.run 2>/dev/null | tail -n +$((RUN_CACHE_KEEP+1)) \
        | while read -r f; do log "pruning old .run: $f"; rm -f "$f"; done
}

trim_cuda_files() {
    # Deterministic, profile-driven. Never triggered by free space.
    log "profile '$PROFILE': trimming CUDA/OpenCL/NVVM/OptiX (GPU PhysX is the casualty;"
    log "Vulkan, GL, DXVK, VKD3D, gamescope and DLSS/libnvidia-ngx are unaffected)"
    local d f n=0
    for d in /usr/lib /usr/lib32 /usr/bin /usr/share/vulkan/icd.d /etc/OpenCL; do
        [ -d "$(rp "$d")" ] || continue
        while IFS= read -r f; do
            case "$(basename "$f")" in libnvidia-ngx*) continue ;; esac
            rm -rf "$f" && n=$((n+1))
        done < <(find "$(rp "$d")" -maxdepth 2 \( -type f -o -type l -o -type d \) \
                   | grep -E "$TRIM_RE" 2>/dev/null)
    done
    log "trimmed $n CUDA/OpenCL paths"
}

drop_gsp_firmware() {
    # VERIFIED unused, not assumed: the guest has no nvidia.ko at all, and
    # `modinfo -F firmware nvkvm-guest.ko` is empty -- nothing in the guest can
    # request GSP firmware. nvkvm supplies the kernel side from the host.
    local d; d="$(rp /usr/lib/firmware/nvidia)"
    [ -d "$d" ] || return 0
    log "removing GSP firmware ($(du -sh "$d" 2>/dev/null | cut -f1)) -- no guest module requests it"
    rm -rf "$d"
}

# Re-install the files that a diverted TYPE contains but the trim LIST keeps.
# Driven by the .run's own .manifest so it stays correct across driver versions.
restore_diverted_keepers() {
    local payload="$1"
    [ -r "$payload/.manifest" ] || { warn "no .manifest in payload; cannot restore keepers"; return 0; }
    local n=0 f base dest
    while IFS= read -r f; do
        base="$(basename "$f")"
        # keep exactly what upstream's tested trim regex does NOT match
        printf '%s' "$base" | grep -qE "$TRIM_RE" && continue
        case "$f" in
            ./32/*) dest=/usr/lib32 ;;
            *)      dest=/usr/lib ;;
        esac
        [ -d "$(rp "$dest")" ] || continue
        if cp -f "$payload/$f" "$(rp "$dest/$base")" 2>/dev/null; then
            n=$((n+1))
        fi
    done < <(awk '$3=="CUDA_LIB" || $3=="OPENCL_LIB" {print $1}' "$payload/.manifest")
    log "restored $n library file(s) that the diverted types contain but the trim list keeps"
    # ldconfig recreates the SONAME symlinks (e.g. libnvidia-ml.so.1), which is
    # what nvidia-smi actually dlopens -- the bare .so dev symlink is not needed.
    in_target ldconfig
}

install_nvidia_userspace() {
    local run="$1"
    steamos_unlock
    local scratch
    if [ "$ROOT" = "/" ]; then scratch=/tmp/nvkvm-nvidia-extract
    else scratch="$(dirname "$(readlink -f "$ROOT")")/nvkvm-nvidia-extract"; fi
    rm -rf "$scratch"; mkdir -p "$scratch" || { err "could not create $scratch"; return 1; }

    # `-x` unpacks into ./NVIDIA-Linux-x86_64-<ver>/ in CWD. Do NOT pass --target:
    # the archive forwards it to nvidia-installer and the extraction silently fails.
    local runabs; runabs="$(readlink -f "$run")"
    ( cd "$scratch" && sh "$runabs" -x ) >/dev/null 2>&1
    local payload; payload="$(find "$scratch" -maxdepth 1 -type d -name 'NVIDIA-Linux-x86_64-*' | head -1)"
    [ -n "$payload" ] || { err "no payload directory after extraction"; rm -rf "$scratch"; return 1; }

    # Divert the bulk we do not want so it is never WRITTEN to the rootfs, rather
    # than installing it and deleting it afterwards. Deleting afterwards still
    # needs the peak space, which is what actually fails on a 5 GB rootfs.
    # --override-file-type-destination is keyed on the installer's own .manifest
    # file types and its documentation says it takes precedence over everything else.
    local divert; divert="$(rp /tmp/nvkvm-discard)"
    rm -rf "$divert"; mkdir -p "$divert"
    local ovr=""
    # FIRMWARE: VERIFIED unused -- the guest has no nvidia.ko at all and
    # `modinfo -F firmware nvkvm-guest.ko` is empty, so nothing can request GSP
    # firmware. ~100 MB, diverted on every profile.
    ovr="--override-file-type-destination=FIRMWARE:/tmp/nvkvm-discard"
    if [ "$PROFILE" = steamos ]; then
        # ~520 MB of CUDA/OpenCL that the gaming profile does not use.
        ovr="$ovr --override-file-type-destination=CUDA_LIB:/tmp/nvkvm-discard"
        ovr="$ovr --override-file-type-destination=OPENCL_LIB:/tmp/nvkvm-discard"
    fi

    local need_kb=1310720
    [ "$PROFILE" = steamos ] && need_kb=786432
    [ "${NVKVM_NO_COMPAT32:-0}" = "1" ] && need_kb=$((need_kb/2))
    local free_kb; free_kb="$(df -Pk "$(rp /usr)" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "$free_kb" ] && [ "$free_kb" -lt "$need_kb" ]; then
        err "not enough space for the NVIDIA userspace: free=$((free_kb/1024))M needed=$((need_kb/1024))M"
        err "Pick a smaller profile (--profile steamos trims CUDA/OpenCL), set"
        err "NVKVM_NO_COMPAT32=1, or grow the rootfs. The profile is NOT downgraded"
        err "automatically -- that would make two identical machines differ."
        rm -rf "$scratch"; return 1
    fi

    local inner=/tmp/nvidia-install
    mkdir -p "$(rp "$inner")"
    mount --bind "$payload" "$(rp "$inner")" \
        || { err "could not bind-mount the payload"; rm -rf "$scratch"; return 1; }

    log "running nvidia-installer (userspace only, profile=$PROFILE)"
    local extra=""
    [ "${NVKVM_NO_COMPAT32:-0}" = "1" ] && extra="--no-install-compat32-libs"
    local rc=0
    # Never hand-pick library files: a hand-picked list silently under-installs
    # libnvidia-glsi/tls/glcore/gpucomp and yields a Vulkan loader that enumerates
    # zero devices with no error until you strace it.
    in_target "$inner/nvidia-installer" \
        --silent --no-kernel-modules --no-kernel-module-source \
        --no-nouveau-check --no-x-check --no-rpms $extra $ovr \
        || { err "nvidia-installer failed"; rc=1; }
    if [ $rc -eq 0 ]; then
        # CRITICAL, and this MUST happen while the payload still exists: the
        # manifest's type granularity is COARSER than upstream's filename trim
        # list. `CUDA_LIB` contains libnvidia-ml (NVML), libnvidia-ptxjitcompiler
        # and libnvidia-sandboxutils -- none in the trim regex, all required.
        # MEASURED: diverting the whole CUDA_LIB type removed NVML and nvidia-smi
        # then failed with "NVIDIA-SMI couldn't find libnvidia-ml.so library in
        # your system" (exit 12), while Vulkan and gamescope kept working because
        # neither uses NVML. Divert the type for the space win, then restore the
        # keepers from the extracted payload, which is authoritative for content.
        restore_diverted_keepers "$payload"
    fi

    umount "$(rp "$inner")" 2>/dev/null
    rm -rf "$scratch" "$divert"
    [ $rc -eq 0 ] || return 1

    drop_gsp_firmware
    [ "$PROFILE" = steamos ] && trim_cuda_files

    in_target ldconfig
    local lib
    for lib in libnvidia-glsi libnvidia-tls libnvidia-glcore; do
        in_target sh -c "ls /usr/lib/${lib}.so.* >/dev/null 2>&1" \
            || { err "$lib missing after install"; rc=1; }
    done
    return $rc
}

# ── Optional SSH access, gated by the presence of a key file ─────────────────
# The OPERATOR drops an authorized_keys into the repo's data/ folder on the HOST;
# that file's presence IS the switch. No flag, no default to pick:
#   absent  -> sshd is not started at all
#   present -> the key is installed and sshd is enabled
# There is deliberately no state in which sshd runs with credentials nobody chose.
#
# PasswordAuthentication is forced OFF. Do NOT rely on "the deck user has no
# password": SteamOS actively prompts users to set one when enabling developer
# mode or sudo, which is exactly this audience -- the moment that password exists,
# password auth over ssh would go live and the safety property would silently
# stop holding. Turning it off makes the guarantee independent of that.
#
# Reachability: the guest is behind slirp NAT, so it is reachable ONLY once the
# operator also adds a QEMU hostfwd, e.g.
#   -netdev user,id=net0,hostfwd=tcp::15022-:22
configure_ssh() {
    local keysrc="$NVKVM_SHARE_MNT/data/authorized_keys"
    local rootkeysrc="$NVKVM_SHARE_MNT/data/root_authorized_keys"

    if [ ! -r "$keysrc" ] && [ ! -r "$rootkeysrc" ]; then
        log "ssh: no data/authorized_keys on the share -- sshd left disabled"
        in_target systemctl disable sshd.service 2>/dev/null || true
        return 0
    fi

    steamos_unlock
    if ! in_target sh -c 'command -v sshd >/dev/null 2>&1'; then
        log "ssh: installing openssh"
        ensure_pacman_keyring || return 1
        in_target pacman -S --noconfirm --needed openssh \
            || { err "ssh: could not install openssh"; return 1; }
    else
        log "ssh: openssh already present in the image"
    fi

    # Host keys, generated once and only if missing, so the guest does not present
    # a different host key on every boot (which would warn on every connection).
    if ! in_target sh -c 'ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1'; then
        log "ssh: generating host keys"
        in_target ssh-keygen -A >/dev/null 2>&1 || warn "ssh: ssh-keygen -A failed"
    else
        log "ssh: host keys already present, keeping them"
    fi

    mkdir -p "$(rp /etc/ssh/sshd_config.d)"
    cat > "$(rp /etc/ssh/sshd_config.d/10-nvkvm.conf)" <<'SSHCONF'
# Written by nvkvm's steamos_boot.sh.
# Key-based access only. PasswordAuthentication defaults to YES, and SteamOS
# prompts users to set a deck password (developer mode / sudo), so leaving it at
# the default would silently open password login the moment that happens.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSHCONF

    _install_authkeys() {   # <user> <source file>
        local u="$1" src="$2" home uid gid
        [ -r "$src" ] || return 0
        home="$(awk -F: -v u="$u" '$1==u{print $6}' "$(rp /etc/passwd)")"
        uid="$(awk -F: -v u="$u" '$1==u{print $3}' "$(rp /etc/passwd)")"
        gid="$(awk -F: -v u="$u" '$1==u{print $4}' "$(rp /etc/passwd)")"
        [ -n "$home" ] && [ -n "$uid" ] || { warn "ssh: no such user '$u'"; return 0; }
        local h; h="$(rp "$home")"
        [ -d "$h" ] || { warn "ssh: home '$home' for $u does not exist"; return 0; }
        mkdir -p "$h/.ssh"
        cp -f "$src" "$h/.ssh/authorized_keys"
        # sshd SILENTLY ignores keys with loose permissions -- a running sshd that
        # rejects a perfectly good key, with nothing useful client-side. Set these
        # explicitly; files copied off a 9p mount will not have them by default.
        chmod 700 "$h/.ssh"
        chmod 600 "$h/.ssh/authorized_keys"
        chown -R "$uid:$gid" "$h/.ssh"
        chmod go-w "$h"          # sshd also refuses a group/other-writable home
        log "ssh: installed authorized_keys for '$u' ($(wc -l < "$src") key line(s))"
    }

    # Interactive user, not root. SteamOS uses `deck`; fall back to `user`.
    local iu=""
    for cand in deck user; do
        awk -F: -v u="$cand" '$1==u{f=1} END{exit !f}' "$(rp /etc/passwd)" && { iu="$cand"; break; }
    done
    [ -n "$iu" ] && _install_authkeys "$iu" "$keysrc"
    # Root access is a separate, explicit decision via a differently-named file.
    _install_authkeys root "$rootkeysrc"

    in_target systemctl enable sshd.service 2>/dev/null || warn "ssh: could not enable sshd.service"
    log "ssh: enabled. Reachable only once QEMU also has a hostfwd, e.g."
    log "ssh:   -netdev user,id=net0,hostfwd=tcp::15022-:22"
}

# ── Desktop config + in-image stub ───────────────────────────────────────────
write_desktop_config() {
    steamos_unlock
    mkdir -p "$(rp /etc/modules-load.d)" "$(rp /etc/modprobe.d)" "$(rp /etc/systemd/system)" "$(rp /etc/environment.d)"
    echo "$MODULE_NAME" > "$(rp /etc/modules-load.d/nvkvm.conf)"
    printf 'options nvkvm_guest privileged_modeset=0\n' > "$(rp /etc/modprobe.d/99-nvkvm.conf)"
    # Resolve the nvkvm DRM node by DRIVER NAME, never by index. environment.d is
    # the mechanism that actually reaches kwin_wayland (pam_systemd imports it at
    # login, before plasma-kwin_wayland.service starts); it cannot run a shell, so
    # a boot-time generator writes the value.
    cat > "$(rp /etc/systemd/system/nvkvm-drm-env.service)" <<'UNIT'
[Unit]
Description=Resolve the nvkvm DRM node and publish it to user sessions
DefaultDependencies=no
# MUST run after the module is loaded. MEASURED: ordering this only after
# udev-settle made it run BEFORE nvkvm-guest was loaded, so no card had driver
# "nvidia" yet, the loop matched nothing, and it exited 0 having written no file.
# The unit then showed "active" while /etc/environment.d was empty and KWin
# opened BOTH DRM nodes -- which is the EGL-init failure, presenting as success.
After=systemd-udev-settle.service nvkvm-boot.service systemd-modules-load.service
Wants=nvkvm-boot.service
Before=display-manager.service sddm.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Poll briefly: modprobe and the DRM node's appearance are not instantaneous.
ExecStart=/bin/sh -c 'for i in $(seq 1 30); do for c in /sys/class/drm/card[0-9]*; do [ -e "$c/device/driver" ] || continue; case "$(basename "$(readlink -f "$c/device/driver")")" in nvidia) mkdir -p /etc/environment.d; echo "KWIN_DRM_DEVICES=/dev/dri/$(basename "$c")" > /etc/environment.d/90-nvkvm.conf; echo "nvkvm: selected /dev/dri/$(basename "$c")"; exit 0;; esac; done; sleep 1; done; echo "nvkvm: WARNING no DRM node with driver nvidia after 30s" >&2; exit 0'

[Install]
WantedBy=multi-user.target
UNIT
    # Cursor latency. MEASURED on SteamOS/Plasma (KWin Wayland) on a real RTX 4070:
    # pointer motion produced 621 GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT errors per 15s
    # (idle: 0), and the present rate did NOT rise -- so cursor updates were failing in
    # GL and never reaching the screen. That is the "mouse lags, keyboard is instant"
    # report, and it is Wayland-compositor-specific (the Mint/X11 guest never shows it).
    #
    # Cause is in nvkvm, not here: nvkvm's virtual KMS is a drm_simple_display_pipe, so
    # it exposes ONE primary plane and NO cursor plane (GETPLANERESOURCES returns 0).
    # With no cursor plane KWin drives the cursor through a GL path, and nvkvm_kms.c's
    # own comment records why that path cannot work -- "NVIDIA cannot use a LINEAR
    # dma-buf as an EGLImage render target" -- while the accept callback still lets
    # LINEAR through for cursors. Forcing KWin's software cursor keeps the cursor on the
    # normal, working block-linear scene path. A/B on the same guest, same session,
    # variable confirmed in kwin_wayland's /proc/<pid>/environ: 621 -> 0.
    #
    # This is a WORKAROUND for a real nvkvm KMS gap; the durable fix is a cursor plane.
    printf 'KWIN_FORCE_SW_CURSOR=1\n' > "$(rp /etc/environment.d/91-nvkvm-cursor.conf)"

    in_target systemctl enable nvkvm-drm-env.service 2>/dev/null || true
    log "desktop configuration written"
}

install_stub() {
    local img_dir="$NVKVM_SHARE_MNT/boot/image"
    [ -d "$img_dir" ] || { warn "in-image sources not found at $img_dir"; return 1; }
    steamos_unlock
    install -D -m 0755 "$img_dir/nvkvm-recovery.sh"      "$(rp /usr/local/sbin/nvkvm-recovery.sh)"
    install -D -m 0644 "$img_dir/nvkvm-boot.service"      "$(rp /etc/systemd/system/nvkvm-boot.service)"
    install -D -m 0644 "$img_dir/nvkvm-plant-stub.path"   "$(rp /etc/systemd/system/nvkvm-plant-stub.path)"
    install -D -m 0644 "$img_dir/nvkvm-plant-stub.service" "$(rp /etc/systemd/system/nvkvm-plant-stub.service)"
    in_target systemctl enable nvkvm-boot.service nvkvm-plant-stub.path 2>/dev/null || true
    log "in-image stub + recovery installed"
}

# ── Part 1 ───────────────────────────────────────────────────────────────────
do_install() {
    local rc=0
    log "=== Part 1: converge (ROOT=$ROOT, profile=$PROFILE) ==="
    capture_ro_state
    trap restore_ro_state EXIT

    PKGS_BEFORE="$(pkgs_snapshot)"

    if ! mount_9p_share; then
        err "9p share '$NVKVM_SHARE_TAG' could not be mounted at $NVKVM_SHARE_MNT."
        err "Start QEMU with: -virtfs local,path=<nvkvm-pv>,mount_tag=$NVKVM_SHARE_TAG,security_model=none,readonly=on"
        return 1
    fi
    local kver want have
    kver="$(target_kver)"
    want="$(repo_commit)"; have="$(built_commit "${kver:-none}")"
    if [ -z "$have" ] || [ "$have" != "$want" ]; then
        log "module out of date (built=${have:-none} repo=$want) -- rebuilding"
        # Toolchain is fetched ONLY when a build is actually needed. MEASURED: run
        # unconditionally it installs gcc+make (55 MB down / 215 MB on a rootfs with
        # ~500 MB free) on EVERY boot and then removes them again, and on a root with
        # no resolver it fails and pins Part 1's exit status at 1 forever -- so a
        # perfectly converged system permanently reports failure.
        ensure_build_deps || rc=1
        build_and_install_module || rc=1
    else
        log "module up to date at $want"
    fi

    # Free the toolchain before the driver install -- they do not both fit.
    remove_added_packages

    local hv iv
    hv="$(host_driver_version)"; iv="$(installed_userspace_version)"
    if [ -z "$hv" ]; then
        warn "could not read the host driver version from /proc/driver/nvidia/version"
    elif [ "$hv" != "$iv" ]; then
        log "NVIDIA userspace mismatch (host=$hv guest=${iv:-none}) -- installing"
        local run
        if run="$(locate_or_fetch_run "$hv")"; then
            install_nvidia_userspace "$run" || rc=1
        else
            err "could not obtain the NVIDIA .run for $hv"; rc=1
        fi
    else
        log "NVIDIA userspace matches host ($hv)"
    fi

    # Every converge, not just after an install. MEASURED on a real SteamOS A/B
    # install: the offline chroot's ldconfig did not persist, so /etc/ld.so.cache
    # still had no nvidia entries on first boot. Everything WORKED anyway (the libs
    # sit in /usr/lib, a default search dir, and the SONAME symlinks resolve), but
    # validate()'s `ldconfig -p | grep libGLX_nvidia` then reported CLASS 4 and
    # printed "The desktop will start on the emulated VGA" while the desktop was in
    # fact running on nvkvm. A green system reporting a hard failure is as bad as
    # the reverse, and this is the cheap, idempotent fix for it.
    in_target ldconfig 2>/dev/null || warn "ldconfig failed in the target root"

    write_desktop_config || rc=1
    configure_ssh || rc=1
    install_stub || true
    prune_run_cache
    log "=== Part 1 finished (rc=$rc) ==="
    return $rc
}

# ── Validation: three distinct failure classes ───────────────────────────────
# 0 ok | 2 protocol mismatch | 3 module will not load | 4 userspace broken
validate() {
    local dmesgtxt; dmesgtxt="$(dmesg 2>/dev/null | tail -400)"
    if printf '%s' "$dmesgtxt" | grep -q 'protocol version mismatch'; then
        err "CLASS 2: nvkvm PROTOCOL VERSION MISMATCH."
        printf '%s' "$dmesgtxt" | grep 'protocol version mismatch' | tail -2 >&2
        err "The guest module and the host QEMU were built from different commits."
        err "Rebuild BOTH from the same nvkvm-pv checkout (the 9p share is that checkout)."
        return 2
    fi
    if ! grep -qw "$MODULE_MOD" /proc/modules 2>/dev/null; then
        err "CLASS 3: $MODULE_NAME is NOT LOADED."
        printf '%s' "$dmesgtxt" | grep -i nvkvm | tail -3 >&2
        err "Built, but the kernel refused it. Usually a vermagic/kernel mismatch"
        err "(check 'modinfo -F vermagic' against 'uname -r'), or nvkvm's virtio"
        err "device is absent from the QEMU command line."
        return 3
    fi
    [ -e /dev/nvidiactl ] || { err "CLASS 4: module loaded but /dev/nvidiactl is missing"; return 4; }
    # Profile-aware. A trimmed profile HAS no libcuda, so checking for it would
    # report a healthy system as broken.
    if [ "$PROFILE" = compute ]; then
        ldconfig -p 2>/dev/null | grep -q libcuda \
            || { err "CLASS 4: profile=compute but libcuda is not in the linker cache"; return 4; }
        nvidia-smi -L >/dev/null 2>&1 \
            || { err "CLASS 4: nvidia-smi cannot enumerate a GPU"; return 4; }
    else
        ldconfig -p 2>/dev/null | grep -q libGLX_nvidia \
            || { err "CLASS 4: libGLX_nvidia missing (Vulkan/GL stack incomplete)"; return 4; }
        # The loader searches BOTH /etc/vulkan/icd.d and /usr/share/vulkan/icd.d,
        # and nvidia-installer writes to /etc. MEASURED -- checking only
        # /usr/share reports a perfectly healthy install as broken.
        [ -e /etc/vulkan/icd.d/nvidia_icd.json ] || [ -e /usr/share/vulkan/icd.d/nvidia_icd.json ] \
            || { err "CLASS 4: NVIDIA Vulkan ICD manifest missing from both loader paths"; return 4; }
    fi
    return 0
}

# ── Part 2 ───────────────────────────────────────────────────────────────────
do_boot() {
    log "=== Part 2: boot ==="
    if grep -qw 'nvkvm.skip=1' /proc/cmdline 2>/dev/null; then
        log "nvkvm.skip=1 -- skipping nvkvm entirely"; return 0
    fi
    do_install || warn "converge reported problems; continuing to validation"

    # If this run rebuilt the module, a stale copy may already be resident from an
    # earlier boot; force it out so the new one is what actually loads.
    if [ "$MODULE_REBUILT" = 1 ] && grep -qw "$MODULE_MOD" /proc/modules 2>/dev/null; then
        log "module was rebuilt this run -- unloading the resident copy first"
        rmmod "$MODULE_NAME" 2>/dev/null || warn "could not unload the running module; a reboot may be needed"
    fi
    modprobe "$MODULE_NAME" 2>/dev/null || warn "modprobe $MODULE_NAME failed"

    validate && { log "validation OK -- handing over to the desktop"; return 0; }

    err "nvkvm validation FAILED (class above). The desktop will start on the emulated VGA."
    err "Run 'nvkvm-recovery.sh menu', or boot with nvkvm.skip=1 to skip this entirely."
    local i
    for i in $(seq 30 -1 1); do printf '\r[nvkvm] continuing in %2ds ' "$i" >&2; sleep 1; done
    printf '\n' >&2
    return 0
}

# ── Entry point ──────────────────────────────────────────────────────────────
CMD=boot
while [ $# -gt 0 ]; do
    case "$1" in
        --install-only) CMD=install; shift ;;
        boot)           CMD=boot; shift ;;
        validate)       CMD=validate; shift ;;
        --root)         ROOT="$2"; shift 2 ;;
        --profile)      PROFILE="$2"; shift 2 ;;
        --old-run-file) RUN_CACHE_DIR="$2"; shift 2 ;;
        *) err "unknown argument: $1"; exit 2 ;;
    esac
done
case "$PROFILE" in steamos|compute) ;; *) err "unknown profile '$PROFILE'"; exit 2 ;; esac

case "$CMD" in
    install)  do_install ;;
    boot)     do_boot ;;
    validate) validate ;;
esac
