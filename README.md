# nvkvm-pv on SteamOS — working artifacts

Rescued from the physical PC (`root@172.22.1.20`), which is periodically handed
over and is **not durable storage**. Everything here is the part that cannot be
regenerated; everything regenerable was deliberately left behind.

## What this is

Getting **SteamOS** — an immutable, AMD-first OS with no NVIDIA support of its
own — to run as an **nvkvm-pv guest** with working GPU acceleration, and
ultimately to run games.

Status at time of rescue (2026-08-23): SteamOS boots as an nvkvm guest,
`nvidia-smi` reports the host's RTX 4070 / driver 595.84, Vulkan enumerates the
GPU (`vkEnumeratePhysicalDevices rc=0 count=1`), and **Steam's client renders
through nvkvm under gamescope**. Open: persistent disk (the repair image's 5 GB
rootfs leaves ~36 MB after the driver install), whole-desktop-on-nvkvm, and
launching an actual game.

## Files

| file | what |
|---|---|
| `NOTES.md` | the working log — read this first |
| `install_nvkvm_userspace.sh` | the offline installer (NBD-mount the image, `btrfs property set ro false`, chroot, install) |
| `nv2081_fix.diff` | adds the `NV2081_BINAPI` alloc-param size row to nvkvm (`src/abi/nvgpu.h` + both switch sites in `src/guest/nvkvm_main.c`) — **not yet committed upstream** |
| `diagnostics/vk_probe.py` | ctypes-only Vulkan probe; needs no compiler, which the repair image lacks |
| `type_send.sh` | drives the guest via QEMU-monitor `sendkey` (the image has no sshd) |
| `*_boot*.log`, `gate_build.log`, `build_qemu.log` | build and boot evidence |
| `evidence/*.ppm.gz` | screendumps from inside the guest |

## Two lessons worth keeping

1. **Never hand-pick NVIDIA userspace libraries.** A hand-written file list
   silently omitted `libnvidia-glsi/tls/glcore/gpucomp`, so `libGLX_nvidia.so.0`
   failed to `dlopen`, Vulkan enumerated zero devices, and **no kernel activity
   happened at all** — which looked like an nvkvm forwarding bug and was not.
   Use NVIDIA's own installer with `--no-kernel-modules`; it staged 69 files
   against ~19 by hand, including the 32-bit compat libs Steam needs.
2. **Mount where you can, install where you must.** On a managed distro,
   mounting the host's driver libraries into the guest makes them track the host
   automatically. SteamOS's immutable rootfs makes that impossible, so
   `nvidia-installer` is the only route there — at the cost of pinning a version
   that must be re-run when the host driver moves.

## Deliberately not rescued (all regenerable)

`steamos-nvkvm.qcow2`, the extracted `NVIDIA-Linux-x86_64-595.84.run` payload,
Valve's `linux-neptune-*-headers` tarball and its `vmlinux`, and the SteamOS
repair image itself — ~7.9 GB combined.
