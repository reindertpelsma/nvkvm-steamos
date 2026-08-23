#!/bin/bash
# install_nvkvm_userspace.sh — bake nvkvm-guest.ko + host-matched (595.84)
# NVIDIA userspace directly into an offline-mounted SteamOS rootfs.
# Substitution of steamos-nvidia-installer's driver-install step: same
# offline-mount / no-live-write approach, but installs nvkvm's guest module
# + host-driver-matched userspace instead of pacman's nvidia-open-dkms.
set -euo pipefail

R="${1:?usage: install_nvkvm_userspace.sh <mounted-rootfs> <run-extract-dir> <ko-file> <kver>}"
RUNDIR="${2:?}"
KO="${3:?}"
KVER="${4:?}"

log() { echo "[install] $*"; }

# ---- 1. kernel module ----
log "Installing nvkvm-guest.ko for $KVER"
mkdir -p "$R/usr/lib/modules/$KVER/updates"
cp -f "$KO" "$R/usr/lib/modules/$KVER/updates/nvkvm-guest.ko"
depmod -b "$R" "$KVER"
grep -q nvkvm-guest.ko "$R/usr/lib/modules/$KVER/modules.dep" \
  && log "modules.dep OK" || { echo "modules.dep missing nvkvm_guest" >&2; exit 1; }

# ---- 2. userspace libs, host-driver-version-matched ----
REQUIRED="libcuda libnvidia-ml libnvidia-ptxjitcompiler libnvidia-nvvm"
OPTIONAL="libnvidia-glcore libnvidia-eglcore libnvidia-glsi libnvidia-tls \
          libnvidia-rtcore libnvidia-gpucomp libnvidia-allocator \
          libnvidia-encode libnvcuvid libnvidia-glvkspirv libnvidia-opencl \
          libEGL_nvidia libGLX_nvidia libGLESv2_nvidia libGLESv1_CM_nvidia \
          libnvidia-cfg"
V=595.84
n=0
for lib in $REQUIRED $OPTIONAL; do
  f="$RUNDIR/$lib.so.$V"
  if [ -f "$f" ]; then
    cp -f "$f" "$R/usr/lib/"
    soname="$(readelf -d "$f" 2>/dev/null | sed -n 's/.*Library soname: \[\(.*\)\]/\1/p')"
    if [ -n "$soname" ]; then
      ln -sf "$(basename "$f")" "$R/usr/lib/$soname"
      base="${soname%.so.*}.so"
      [ "$base" != "$soname" ] && ln -sf "$soname" "$R/usr/lib/$base" 2>/dev/null || true
    fi
    n=$((n+1))
  elif echo "$REQUIRED" | grep -qw -- "$lib"; then
    echo "MISSING REQUIRED: $lib.so.$V" >&2; exit 1
  else
    log "optional $lib.so.$V not in payload -- skipping"
  fi
done

# SONAME-versioned upstream libs (egl-wayland/egl-gbm) -- own version, not driver's
for lib in libnvidia-egl-gbm libnvidia-egl-wayland; do
  real="$(ls "$RUNDIR/$lib".so.* 2>/dev/null | grep -v '\.so\.1$' | sort -V | tail -1)"
  [ -z "$real" ] && continue
  cp -f "$real" "$R/usr/lib/"
  ln -sf "$(basename "$real")" "$R/usr/lib/$lib.so.1"
  n=$((n+1))
done

[ -f "$RUNDIR/nvidia-smi" ] && cp -f "$RUNDIR/nvidia-smi" "$R/usr/bin/" && n=$((n+1))
log "staged $n userspace files into $R/usr/lib"

# ---- 3. GLVND / Vulkan / OpenCL vendor manifests ----
mkdir -p "$R/usr/share/glvnd/egl_vendor.d" "$R/usr/share/vulkan/icd.d" "$R/etc/OpenCL/vendors"
cp -f "$RUNDIR/10_nvidia.json" "$R/usr/share/glvnd/egl_vendor.d/"
cp -f "$RUNDIR/15_nvidia_gbm.json" "$R/usr/share/egl/egl_external_platform.d/" 2>/dev/null \
  || { mkdir -p "$R/usr/share/egl/egl_external_platform.d"; cp -f "$RUNDIR/15_nvidia_gbm.json" "$R/usr/share/egl/egl_external_platform.d/"; }
cp -f "$RUNDIR/nvidia_icd.json" "$R/usr/share/vulkan/icd.d/"
printf 'libnvidia-opencl.so.1\n' > "$R/etc/OpenCL/vendors/nvidia.icd"

# ---- 4. modprobe / ld.so.conf ----
cat > "$R/etc/modprobe.d/99-nvkvm.conf" <<'EOF'
# nvkvm guest: no real GPU here, nothing to blacklist -- this file exists so
# the module's default options are visible/overridable in one place.
options nvkvm_guest privileged_modeset=1
EOF

ldconfig -r "$R"
log "ldconfig -r $R done"

log "OK"
