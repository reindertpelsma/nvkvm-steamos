#!/bin/bash
# nvidia_userspace_completeness_test.sh — a version match is not proof of a
# finished NVIDIA userspace install.
#
# MEASURED 2026-08-29 on a real A/B slot: the .run extraction was OOM-killed
# part-way through. The payload installs libnvidia-glcore EARLY, so
# installed_userspace_version() still reported the correct version, the
# convergence logged "NVIDIA userspace matches host" and SKIPPED the install --
# forever. The half-written tree was never repaired on any subsequent boot.
#
# The missing tail was display-fatal: /usr/lib/gbm/nvidia-drm_gbm.so and the EGL
# external-platform configs. gbm selects its backend by DRM driver name, so
# without that one symlink KWin fell through to Mesa's dri_gbm.so on our
# NVIDIA-identity device -- the atomic test buffer was rejected, the output
# stayed connected-but-disabled, nothing was ever presented, and forcing the
# legacy path segfaulted kwin_wayland inside libgallium every two seconds.
#
# Guard both halves: the predicate must actually detect a truncated tree, and
# the convergence must still be wired to consult it.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
rc=0
VER=580.173.02

# Run the REAL function out of the shipped script rather than a restatement of
# it, so this test fails if the sentinel list silently loses an entry.
eval "$(awk '/^nvidia_userspace_complete\(\) \{/,/^\}/' "$BOOT")"
if ! declare -F nvidia_userspace_complete >/dev/null; then
    echo "FAIL: could not extract nvidia_userspace_complete from $BOOT"; exit 1
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
rp() { printf '%s' "$ROOTDIR$1"; }   # the script's root-prefix helper

# A COMPLETE tree: everything the display path needs.
complete_tree() {
    local r="$1"
    mkdir -p "$r/usr/lib/gbm" "$r/usr/share/glvnd/egl_vendor.d" \
             "$r/usr/share/egl/egl_external_platform.d"
    touch "$r/usr/lib/libEGL_nvidia.so.0" \
          "$r/usr/lib/libGLX_nvidia.so.0" \
          "$r/usr/lib/libnvidia-eglcore.so.$VER" \
          "$r/usr/lib/libnvidia-glcore.so.$VER" \
          "$r/usr/lib/libnvidia-allocator.so.1" \
          "$r/usr/lib/libnvidia-egl-gbm.so.1" \
          "$r/usr/lib/gbm/nvidia-drm_gbm.so" \
          "$r/usr/share/glvnd/egl_vendor.d/10_nvidia.json" \
          "$r/usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json"
}

ROOTDIR="$work/good"; complete_tree "$ROOTDIR"
if nvidia_userspace_complete "$VER"; then
    echo "ok: a complete tree is accepted"
else
    echo "FAIL: complete tree rejected, missing:$NVIDIA_MISSING"; rc=1
fi

# The exact real-world truncation: correct version, missing display tail.
ROOTDIR="$work/truncated"; complete_tree "$ROOTDIR"
rm -f "$ROOTDIR/usr/lib/gbm/nvidia-drm_gbm.so" \
      "$ROOTDIR/usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json"
if nvidia_userspace_complete "$VER"; then
    echo "FAIL: an OOM-truncated tree was accepted as complete"; rc=1
else
    case "$NVIDIA_MISSING" in
        *nvidia-drm_gbm.so*15_nvidia_gbm.json*)
            echo "ok: truncated tree detected, and it names both missing files" ;;
        *)  echo "FAIL: detected but reported the wrong files:$NVIDIA_MISSING"; rc=1 ;;
    esac
fi

# Every sentinel must matter: dropping any single one must be caught.
for f in usr/lib/libEGL_nvidia.so.0 usr/lib/gbm/nvidia-drm_gbm.so \
         usr/lib/libnvidia-egl-gbm.so.1 usr/lib/libnvidia-allocator.so.1 \
         usr/share/glvnd/egl_vendor.d/10_nvidia.json \
         usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json; do
    ROOTDIR="$work/one"; rm -rf "$ROOTDIR"; complete_tree "$ROOTDIR"
    rm -f "$ROOTDIR/$f"
    if nvidia_userspace_complete "$VER"; then
        echo "FAIL: removing $f was not detected"; rc=1
    fi
done
[ $rc -eq 0 ] && echo "ok: every sentinel is load-bearing"

# The predicate is useless if the convergence stops consulting it. CUDA/OpenCL
# are discarded on purpose by --profile steamos and must never be sentinels.
if grep -q 'nvidia_userspace_complete "\$iv"' "$BOOT"; then
    echo "ok: convergence consults the completeness check"
else
    echo "FAIL: convergence no longer calls nvidia_userspace_complete"; rc=1
fi
if awk '/^nvidia_userspace_complete\(\) \{/,/^\}/' "$BOOT" \
     | grep -v '^[[:space:]]*#' \
     | grep -qE 'libcuda|libnvidia-opencl|firmware'; then
    echo "FAIL: a sentinel names a file --profile steamos deliberately discards"; rc=1
fi

exit $rc
