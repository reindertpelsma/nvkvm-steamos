# nvkvm-pv on SteamOS

Run SteamOS as a KVM guest of
[nvkvm-pv](https://github.com/reindertpelsma/nvkvm-pv), with the NVIDIA GPU
still owned by the host.

This repository is the SteamOS integration layer for nvkvm-pv. It contains the
SteamOS image installer, boot/provisioning policy, the two-container display
deployment, validation notes, and the raw evidence from the bring-up runs.
nvkvm-pv remains the GPU paravirtualization implementation.

## Current status

For running the full SteamOS-on-nvkvm stack, the supported path is the
two-container Docker Compose deployment:

- `vmm`: patched nvkvm/QEMU plus the SteamOS VM. It receives `/dev/kvm` and the
  NVIDIA devices, but no host Wayland or X11 socket.
- `broker`: the host desktop window and input bridge. It receives the host
  Wayland/X11 mounts, but no `/dev/kvm`, GPU-control device, VM disk, recovery
  image, source share, or SSH key.

On first start the VMM downloads the SteamOS recovery image, boots a disposable
Alpine installer VM, lets Valve's own installer create a real dual-slot A/B
SteamOS qcow2, provisions that image with nvkvm's guest module and NVIDIA
userspace matching the host driver, then boots Plasma.

Outside Docker, the preferred image path is
[`install_steamos_vm.sh`](install_steamos_vm.sh). It uses the same disposable-VM
installer directly and does not require host root. The manual loop/chroot path
is still kept, but it does require root and is mainly useful when debugging the
image surgery itself.

The default build context fetches `reindertpelsma/nvkvm-pv#main`. To test a
local or review checkout explicitly:

```sh
NVKVM_CONTEXT=/path/to/nvkvm-pv docker compose build
```

## Quick start

Prerequisites: a graphical Linux session, Docker with the Compose plugin,
working `/dev/kvm`, a loaded NVIDIA driver, and NVIDIA Container Toolkit.

```sh
docker compose build
docker compose up -d
docker compose logs -f broker vmm
./steamos-ssh
```

For persistent state, security boundaries, Wayland/X11 selection, published
images, and configuration knobs, read
[`docs/container-compose.md`](docs/container-compose.md).

## Build an image outside Docker

Use this when you want a SteamOS qcow2 on the host instead of the full Compose
deployment:

```sh
./install_steamos_vm.sh \
  --repair steamdeck-oobe-repair-*.img \
  --out steamos.qcow2
```

To provision that image for nvkvm in the same run, use an nvkvm-pv checkout as
the read-only share:

```sh
./install_steamos_vm.sh \
  --repair steamdeck-oobe-repair-*.img \
  --out steamos.qcow2 \
  --stages repair,provision \
  --share /path/to/nvkvm-pv
```

This path needs `qemu-system-x86_64`, `qemu-img`, an OVMF package, common
archive tools, `/dev/kvm`, and a loaded NVIDIA driver for the provisioning
stage. It does not need `sudo`, `losetup`, host mounts, or a host chroot.

For the full explanation and verified output, read
[`docs/vm-installer.md`](docs/vm-installer.md). For the root-requiring manual
recovery-image path, read [`docs/manual-install.md`](docs/manual-install.md).

## What is proven

| area | state |
|---|---|
| SteamOS desktop | SteamOS 3.8.14 boots as an nvkvm guest on the physical RTX 4070 test box; Plasma renders on the NVIDIA GPU. |
| Present path | GL zero-copy was measured at 60 fps with `-vga none`; the visible desktop came through nvkvm, not an emulated VGA fallback. |
| Games | Portal 2 launches and plays under the GTK backend. Minecraft is playable through nvkvm under SDL on the non-SteamOS Linux guest. |
| Image creation | `install_steamos_vm.sh` creates a genuine dual-slot A/B SteamOS install using Valve's installer, without host root. |
| Container split | The VMM/display-broker separation is policy-tested, and broker restart does not restart or disturb the VM. |

Raw logs live in [`evidence-pc-20260823/`](evidence-pc-20260823/),
[`evidence-vm-install-20260824/`](evidence-vm-install-20260824/), and
[`boot/TESTING.md`](boot/TESTING.md). The condensed status and open issues are
in [`docs/status.md`](docs/status.md).

## What is not solved

- SteamOS under `sdl,gl=on` still shows a black window. SDL pointer lock works
  on the non-SteamOS guest, so this is the gap between "renders" and "fully
  playable SteamOS gaming".
- `gtk,gl=on` renders SteamOS and Portal 2, but GTK does not deliver usable
  pointer lock for mouse-look on the tested Wayland host.
- The smooth SteamOS cursor currently depends on `KWIN_FORCE_SW_CURSOR=1`; a
  real cursor plane in nvkvm is still the durable fix.
- The VM installer now produces an A/B image that can exercise SteamOS update
  behavior, but an end-to-end OTA update-hook run is not documented here yet.
- nvkvm-pv is experimental and is not a hardened guest/host security boundary.
  Do not use it for untrusted tenants.

## Docs

| read | for |
|---|---|
| [`docs/container-compose.md`](docs/container-compose.md) | the supported runtime/deployment path |
| [`docs/vm-installer.md`](docs/vm-installer.md) | the preferred non-Docker image builder and why it replaced loop/chroot for normal image creation |
| [`docs/status.md`](docs/status.md) | measured results, display backend matrix, open gaps, and evidence links |
| [`docs/manual-install.md`](docs/manual-install.md) | the root-requiring recovery-image provisioning path by hand; useful for debugging |
| [`TUTORIAL.md`](TUTORIAL.md) | a full source-build walkthrough, kept as a low-level reference rather than the README path |
| [`boot/TESTING.md`](boot/TESTING.md) | chronological validation notes and regressions found on real rigs |
| [`NOTES.md`](NOTES.md) | historical investigation log |
| [`archive/`](archive/README.md) | superseded scripts kept for reference |

## Credit

The SteamOS provisioning approach builds on
[28allday/steamos-nvidia-installer](https://github.com/28allday/steamos-nvidia-installer),
which established the offline NVIDIA-on-SteamOS pattern: operate on an
unmounted rootfs, fetch exact `linux-neptune-*-headers` from Valve's mirror,
build in a throwaway chroot, and survive atomic updates.

This project substitutes nvkvm's guest module into that pattern while keeping
the NVIDIA userspace side intact.
