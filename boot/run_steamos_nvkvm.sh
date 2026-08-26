#!/bin/bash
# Boot a provisioned SteamOS qcow2 as an nvkvm guest.
# Every non-obvious flag here was established by bisection -- see TESTING.md.
#
# This is the command line that was run on the bare-metal RTX 4070 box on
# 2026-08-23 and produced GL zero-copy at 60 fps with -vga none.
#
#   VM_DISPLAY=gtk,gl=on   (default) renders, but QEMU delivers no pointer lock
#   VM_DISPLAY=sdl,gl=on             pointer lock works, but the SteamOS guest
#                                    is a black window -- see the README
#   VGA=vga                          keep an emulated VGA for the boot console
#                                    (default: -vga none, the decisive config)
set -u
QCOW="${QCOW:-/opt/nvkvm-guest/steamOS-nvkvm.qcow2}"
SHARE="${SHARE:-/srv/nvkvm-steamos}"          # an nvkvm-pv checkout, not this repo
QEMU="${QEMU:-/opt/qemu-nvkvm/bin/qemu-system-x86_64}"
WORK="${WORK:-$PWD}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-$WORK/OVMF_VARS.fd}"

[ -f "$OVMF_VARS" ] || cp -f /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS"

# QEMU needs the desktop session's environment when it is launched from a
# service, a remote shell or a different user than the one holding the seat.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DISPLAY="${DISPLAY:-:0}"
export GDK_BACKEND="${GDK_BACKEND:-wayland}"
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland}"
export NVKVM_PRESENT_TIMING=1
[ -n "${NVKVM_PRESENT_MODE:-}" ] && export NVKVM_PRESENT_MODE

# VGA=none -> decisive: nothing but nvkvm can be drawing.
VGA_ARGS=(-vga none)
[ "${VGA:-none}" = "vga" ] && VGA_ARGS=(-device "VGA,id=bootvga")

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
  -qmp unix:"$WORK/qmp.sock",server,nowait \
  -serial file:"$WORK/serial.log" \
  -display "$DISP"
