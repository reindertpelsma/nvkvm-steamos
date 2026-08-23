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

## The path: image to working desktop

There is **one** supported path, and one script. `boot/steamos_boot.sh` is a
single self-repairing mechanism that runs at every boot and converges the system
to a known state. There is deliberately **no separate "fresh install" and
"update" path** — every step is check-then-act and safe to re-run. On a fresh
image everything is missing so it does everything; when only the host driver
changed it reinstalls only the `.run`; when only the nvkvm repo moved it rebuilds
only the `.ko`.

The script lives on the **read-only 9p share**, not in the image, so changing
this logic never means touching the SteamOS image.

### 1. Bootstrap (the only steps done from the host)

Exactly two actions, both against the repair `.img`:

1. **Resize it.** Note that `qemu-img resize` leaves the backup GPT header at the
   old end-of-disk. Linux tolerates that; **OVMF does not** and will refuse to
   boot. Fix with `sgdisk -e`, and run it against a **loop** device — against
   `/dev/nbd0` sgdisk fails with `Read error 5`.
2. **Provision the image offline**, which also plants the systemd unit:

   ```
   steamos_boot.sh --install-only --root <mounted rootfs>
   ```

   `--install-only` touches no running-kernel state, so it is safe against a root
   that is not yours.

Nothing else is ever done by hand.

### 2. Boot

`nvkvm-boot.service` fires, mounts the 9p share, hands over to the script, which
converges, validates, and hands to the desktop. A healthy run reads:

```
module up to date at <commit> → NVIDIA userspace matches host (<version>)
→ Part 1 finished (rc=0) → validation OK
```

The QEMU command line needs `-fw_cfg opt/ovmf/X-PciMmio64Mb,string=262144` or
OVMF hangs in firmware before the bootloader **with no error on any console**;
the qcow2 must be presented as **nvme** (SteamOS expects `/dev/nvme0n1p*`); and
for playable games use the **SDL** display backend, because GTK does not deliver
pointer lock.

### 3. Updates

A SteamOS update replaces the entire rootfs, so everything the script installed
is gone in the new image. The update hook simply runs the same script against the
new root:

```
steamos_boot.sh --install-only --root <new image root>
```

Part 1 sees the arm is missing there and **re-arms itself**, so the stub
propagates forward without any copy step. Gating the update on this script's exit
code is deliberate: if provisioning fails, the update does not apply and the old,
working image keeps running.

Note the gate can only ever check *"did it build and install"*, never *"does it
work"* — it runs on a live system against a different kernel, so it cannot load
the module. That is why the boot half has an interactive recovery menu.

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
