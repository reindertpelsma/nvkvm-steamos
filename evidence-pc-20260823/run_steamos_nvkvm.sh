#!/bin/bash
# SteamOS-as-nvkvm-guest launcher (real A/B install, provisioned by steamos_boot.sh Part 1)
set -u
W=/root/steamos-nvkvm/run2
QCOW="${QCOW:-/opt/nvkvm-guest/steamOS-nvkvm.qcow2}"
SHARE="${SHARE:-/srv/nvkvm-steamos}"
QEMU="${QEMU:-/opt/qemu-nvkvm/bin/qemu-system-x86_64}"
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS="$W/OVMF_VARS.fd"
[ -f "$OVMF_VARS" ] || cp -f /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS"

export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-0
export DISPLAY=:0
export XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
export GDK_BACKEND="${GDK_BACKEND:-wayland}"
export NVKVM_PRESENT_TIMING=1
[ -n "${NVKVM_PRESENT_MODE:-}" ] && export NVKVM_PRESENT_MODE

# VGA=none  -> decisive: nothing but nvkvm can be drawing
# VGA=vga   -> keep the emulated VGA for the boot console
VGA_ARGS=(-vga none)
[ "${VGA:-none}" = "vga" ] && VGA_ARGS=(-device VGA,id=bootvga)

DISP="${VM_DISPLAY:-gtk,gl=on}"
echo "== display=$DISP vga=${VGA:-none} present_mode=${NVKVM_PRESENT_MODE:-auto} qcow=$QCOW =="
exec "$QEMU" \
  -enable-kvm -m 12G -smp 8 -cpu host -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -drive file="$QCOW",format=qcow2,if=none,id=nvm0 \
  -device nvme,drive=nvm0,serial=nvkvmsteamos \
  -netdev user,id=net0,hostfwd=tcp::15022-:22 \
  -device virtio-net-pci,netdev=net0 \
  "${VGA_ARGS[@]}" \
  -device virtio-nvgpu-pci-non-transitional,id=nvkvm0 \
  -device nvkvm-gpu,addr=7 \
  -virtfs local,path="$SHARE",mount_tag=nvkvm,security_model=none,readonly=on \
  -fw_cfg opt/ovmf/X-PciMmio64Mb,string=262144 \
  -device virtio-keyboard-pci -device virtio-tablet-pci \
  -qmp unix:$W/qmp.sock,server,nowait \
  -serial file:$W/serial.log \
  -display "$DISP"
