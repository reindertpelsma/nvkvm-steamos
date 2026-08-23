# nvkvm-pv on SteamOS

An **attempt** to run [SteamOS](https://store.steampowered.com/steamos) as a
guest of [nvkvm-pv](https://github.com/reindertpelsma/nvkvm-pv), NVIDIA GPU
paravirtualisation for KVM.

**Status: it boots and the desktop is GPU-accelerated. It is not finished.**
No game has been launched yet.

SteamOS is an interesting target precisely because nothing about it was built
for this: it is immutable (read-only rootfs, atomic A/B updates), has no usable
package manager, is AMD-first, and ships **no NVIDIA support at all**.

## Credit

The approach here is built directly on
**[28allday/steamos-nvidia-installer](https://github.com/28allday/steamos-nvidia-installer)**,
which solved the hard parts of getting an NVIDIA driver onto SteamOS at all:
working *offline* on an unmounted rootfs rather than fighting the read-only
filesystem, fetching exact-version `linux-neptune-*-headers` from Valve's own
mirror, building in a throwaway overlay chroot, and surviving atomic updates by
wrapping `steamos-update` itself.

This project is essentially a substitution into that pattern: instead of
installing NVIDIA's kernel module, install **nvkvm's guest module**, and keep the
userspace half unchanged. Without that project's groundwork this would have been
a much longer road.

## What works

Measured on an RTX 4070 host (driver 595.84), guest booted from Valve's
SteamOS recovery image:

- `nvkvm-guest.ko` builds against Valve's neptune kernel (`6.16.12-valve24.4`)
- `nvidia-smi` **inside the guest** reports the host's GPU: `Driver 595.84,
  CUDA 13.2, NVIDIA GeForce RTX 4070`
- Vulkan enumerates the GPU: `vkEnumeratePhysicalDevices rc=0 count=1`
- **The entire Plasma desktop renders through nvkvm**, automatically from a cold
  boot — `nvidia-smi` in the guest lists `kwin_wayland`, `Xwayland` and
  `plasmashell` as real GPU processes, and KWin holds only nvkvm's DRM node open
- QEMU reports `display mode = GL zero-copy ... NVIDIA GeForce RTX 4070`,
  **40–60 fps at under 0.5 ms present latency, zero dropped frames**
- Steam's client runs (under gamescope and from the desktop) on persistent disk

## What does not

- **No game launched.** Steam sits at an unauthenticated sign-in screen; that
  needs interactive credentials and 2FA.
- Built against the **recovery image**, not a real installed SteamOS. Whether
  the recovery image's own install flow carries these changes into an installed
  system is untested.
- One non-fatal `GL_INVALID_OPERATION` per boot, matching nvkvm's documented
  limitation that NVIDIA cannot use a LINEAR dma-buf as an EGLImage render
  target — believed to be KWin's hardware cursor plane. Cosmetic; the desktop
  composites fine.
- `NVKVM_PRESENT_MODE=readback` **hangs the guest at the GRUB handoff** on this
  host, reproducibly. Not root-caused.

## Build

```sh
./build_nvkvm_steamos_image.sh --ko path/to/nvkvm-guest.ko   # see --help
```

Offline: NBD-mount the image, `btrfs property set ro false`, install the module,
run NVIDIA's own installer in a chroot, write config, resize. No boot required.

This script was **run and its output booted** as an independent VM reaching the
same measured end state — not merely written. Its header states two limits it
does not solve: it takes a prebuilt `.ko`, and it hardcodes
`KWIN_DRM_DEVICES=/dev/dri/card0` from observation rather than a sysfs lookup.

## Two lessons worth more than the code

1. **Never hand-pick NVIDIA userspace libraries.** A hand-written file list
   omitted `libnvidia-glsi/tls/glcore/gpucomp`, so `libGLX_nvidia.so.0` failed
   to `dlopen`, Vulkan enumerated zero devices, and **no kernel activity
   happened at all** — which looked like an nvkvm forwarding bug and was not.
   Use `nvidia-installer --no-kernel-modules`: 69 files staged against ~19 by
   hand, including the 32-bit libs Steam needs.
2. **Mount where you can, install where you must.** On a managed distro,
   mounting the host's driver libraries into the guest makes them track the host
   automatically. An immutable rootfs makes that impossible, so the installer is
   the only route — at the cost of pinning a version.

## Layout

| path | what |
|---|---|
| `build_nvkvm_steamos_image.sh` | the image builder |
| `install_nvkvm_userspace.sh` | the userspace half, standalone |
| `agent.py`, `inject_agent.sh` | command channel for a guest with no sshd (base64 over the QEMU monitor) |
| `diagnostics/vk_probe.py` | ctypes-only Vulkan probe — the recovery image has no compiler |
| `nv2081_fix.diff` | adds the `NV2081_BINAPI` alloc-param size row to nvkvm |
| `NOTES.md` | the full working log, 700+ lines |
| `evidence/` | screendumps from inside the guest |
