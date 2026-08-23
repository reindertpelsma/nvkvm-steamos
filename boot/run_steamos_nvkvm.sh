#!/bin/bash
# Boot a provisioned SteamOS qcow2 as an nvkvm guest.
# Every non-obvious flag here was established by bisection -- see TESTING.md.
set -u
QCOW="${QCOW:-/root/work/steamos2.qcow2}"
REPO="${REPO:-/root/work/nvkvm-pv}"
QEMU="${QEMU:-/opt/qemu-nvkvm/bin/qemu-system-x86_64}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-/root/work/OVMF_VARS.fd}"

[ -f "$OVMF_VARS" ] || cp -f /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS"

export NVKVM_PRESENT_TIMING=1
exec "$QEMU" \
  -enable-kvm -m 12G -smp 8 -cpu host -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -drive file="$QCOW",format=qcow2,if=none,id=nvm0 \
  -device nvme,drive=nvm0,serial=nvkvmsteamos \
  -netdev user,id=net0,hostfwd=tcp::15022-:22 \
  -device virtio-net-pci,netdev=net0 \
  -device VGA,id=bootvga \
  -device virtio-nvgpu-pci-non-transitional,id=nvkvm0 \
  -device nvkvm-gpu,addr=7 \
  -virtfs local,path="$REPO",mount_tag=nvkvm,security_model=none,readonly=on \
  -fw_cfg opt/ovmf/X-PciMmio64Mb,string=262144 \
  -device virtio-keyboard-pci -device virtio-tablet-pci \
  -monitor unix:/root/work/qmp.sock,server,nowait \
  -serial file:/root/work/steamos_serial.log \
  -display gtk
