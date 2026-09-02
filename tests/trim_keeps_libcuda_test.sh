#!/bin/bash
# trim_keeps_libcuda_test.sh — the steamos profile must trim CUDA *tooling*
# while KEEPING libcuda itself.
#
# libcuda used to be trimmed along with everything else CUDA-shaped, on the
# premise that a gaming profile has no use for it. MEASURED 2026-09-02, that is
# false: the NVIDIA Vulkan ICD dlopen()s libcuda.so.1 inside its own init path
# for every ray-tracing device extension, so without it vkCreateDevice returns
# VK_ERROR_INITIALIZATION_FAILED, vkd3d-proton cannot expose DXR, and D3D12
# titles die at ERR_GFX_INIT. DXVK titles never noticed.
#
# The sentinel-list test next door proves libcuda is CHECKED for. This one
# proves the trim does not DELETE it -- a different mechanism, and the one that
# actually regressed. Runs the real functions out of the shipped script.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
rc=0
V=580.173.02

eval "$(grep -E "^TRIM_RE=" "$BOOT")"
[ -n "${TRIM_RE:-}" ] || { echo "FAIL: could not extract TRIM_RE from $BOOT"; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
ROOT="$work/root"
rp() { printf '%s' "${ROOT%/}$1"; }
log() { :; }
# Exported, not plain-assigned: trim_cuda_files is eval'd out of the shipped
# script below and reads $PROFILE, which shellcheck cannot see through the
# eval (SC2034).
export PROFILE=steamos
eval "$(awk '/^trim_cuda_files\(\) \{/,/^\}/' "$BOOT")"
declare -F trim_cuda_files >/dev/null || { echo "FAIL: could not extract trim_cuda_files"; exit 1; }

mkdir -p "$ROOT/usr/lib" "$ROOT/usr/lib32" "$ROOT/etc/OpenCL"
# KEEP these
touch "$ROOT/usr/lib/libcuda.so.$V" "$ROOT/usr/lib/libcuda.so.1" \
      "$ROOT/usr/lib32/libcuda.so.$V" \
      "$ROOT/usr/lib/libGLX_nvidia.so.$V" \
      "$ROOT/usr/lib/libnvidia-glcore.so.$V" \
      "$ROOT/usr/lib/libnvidia-ngx.so.$V"
# TRIM these
touch "$ROOT/usr/lib/libcudadebugger.so.$V" \
      "$ROOT/usr/lib/libnvidia-nvvm.so.$V" \
      "$ROOT/usr/lib/libnvidia-opencl.so.$V" \
      "$ROOT/usr/lib/libnvoptix.so.$V"

trim_cuda_files >/dev/null 2>&1

must_keep="usr/lib/libcuda.so.$V usr/lib/libcuda.so.1 usr/lib32/libcuda.so.$V
           usr/lib/libGLX_nvidia.so.$V usr/lib/libnvidia-glcore.so.$V usr/lib/libnvidia-ngx.so.$V"
must_go="usr/lib/libcudadebugger.so.$V usr/lib/libnvidia-nvvm.so.$V
         usr/lib/libnvidia-opencl.so.$V usr/lib/libnvoptix.so.$V"

for f in $must_keep; do
    if [ -e "$ROOT/$f" ]; then echo "ok: kept $f"
    else echo "FAIL: the trim DELETED $f"; rc=1; fi
done
for f in $must_go; do
    if [ -e "$ROOT/$f" ]; then echo "FAIL: the trim kept $f, which it should discard"; rc=1
    else echo "ok: trimmed $f"; fi
done

# The regression in one line: a TRIM_RE that matches plain libcuda is the bug.
if printf 'libcuda.so.1\n' | grep -qE "$TRIM_RE"; then
    echo "FAIL: TRIM_RE matches libcuda.so.1 -- this is the RDR2 ERR_GFX_INIT regression"; rc=1
else
    echo "ok: TRIM_RE does not match libcuda.so.1"
fi
if printf 'libcudadebugger.so.1\n' | grep -qE "$TRIM_RE"; then
    echo "ok: TRIM_RE still matches libcudadebugger"
else
    echo "FAIL: libcudadebugger is no longer trimmed"; rc=1
fi

# ── The other half: the trim not deleting libcuda is useless if nothing
# INSTALLS it. nvidia-installer runs with CUDA_LIB/OPENCL_LIB diverted, and
# restore_diverted_keepers() puts back exactly what TRIM_RE does not match --
# so that function, driven by the .run's own .manifest, is what actually lands
# libcuda on disk. Test it against a fixture payload.
ROOT="$work/root2"; mkdir -p "$ROOT/usr/lib" "$ROOT/usr/lib32"
payload="$work/payload"; mkdir -p "$payload/32"
printf 'x' > "$payload/libcuda.so.$V"
printf 'x' > "$payload/libcudadebugger.so.$V"
printf 'x' > "$payload/libnvidia-opencl.so.$V"
printf 'x' > "$payload/32/libcuda.so.$V"
cat > "$payload/.manifest" <<MAN
libcuda.so.$V 0644 CUDA_LIB
libcudadebugger.so.$V 0644 CUDA_LIB
libnvidia-opencl.so.$V 0644 OPENCL_LIB
./32/libcuda.so.$V 0644 CUDA_LIB
MAN
warn() { :; }
eval "$(awk '/^restore_diverted_keepers\(\) \{/,/^\}/' "$BOOT")"
if declare -F restore_diverted_keepers >/dev/null; then
    restore_diverted_keepers "$payload" >/dev/null 2>&1
    if [ -e "$ROOT/usr/lib/libcuda.so.$V" ]; then
        echo "ok: restore_diverted_keepers installed libcuda into /usr/lib"
    else
        echo "FAIL: libcuda was never installed -- not trimming it is not enough"; rc=1
    fi
    if [ -e "$ROOT/usr/lib32/libcuda.so.$V" ]; then
        echo "ok: restore_diverted_keepers installed the lib32 libcuda"
    else
        echo "FAIL: lib32 libcuda was never installed"; rc=1
    fi
    if [ -e "$ROOT/usr/lib/libcudadebugger.so.$V" ]; then
        echo "FAIL: libcudadebugger was restored; TRIM_RE should exclude it"; rc=1
    else
        echo "ok: libcudadebugger was not restored"
    fi
    if [ -e "$ROOT/usr/lib/libnvidia-opencl.so.$V" ]; then
        echo "FAIL: libnvidia-opencl was restored; TRIM_RE should exclude it"; rc=1
    else
        echo "ok: libnvidia-opencl was not restored"
    fi
else
    echo "FAIL: could not extract restore_diverted_keepers"; rc=1
fi

exit $rc
