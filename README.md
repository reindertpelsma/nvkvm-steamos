# nvkvm-pv on SteamOS

Run SteamOS as a KVM guest of
[nvkvm-pv](https://github.com/reindertpelsma/nvkvm-pv), with the NVIDIA GPU
still owned and usuable by the host.

This repository is the SteamOS integration layer for nvkvm-pv. It contains the
SteamOS image installer, boot/provisioning policy, the two-container display
deployment, validation notes, and the raw evidence from the bring-up runs.
nvkvm-pv remains the GPU paravirtualization implementation. 

This project is a great test target for the possible capabilities of nvkvm-pv.

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
| Present path | GL zero-copy was measured at 60 fps with `-vga none`; the visible desktop came through nvkvm, not an emulated VGA fallback. Linear dma-buf (and universal shm) fallback in case the display is on iGPU/AMD GPU but rendering needs to be on a discrete NVIDIA card such as common on many laptops. |
| Games | Portal 2, Stardew Valley, Planetary Annihilation and tomb raider launches and plays under the GTK backend and the NVKVM broker (the docker-compose.yml setup). Minecraft is playable through nvkvm under SDL on the non-SteamOS Linux guest. |
| Image creation | `install_steamos_vm.sh` creates a genuine dual-slot A/B SteamOS install using Valve's installer, without host root. |
| Container split | The VMM/display-broker separation is policy-tested, and broker restart does not restart or disturb the VM. |

Raw logs live in [`evidence-pc-20260823/`](evidence-pc-20260823/),
[`evidence-vm-install-20260824/`](evidence-vm-install-20260824/), and
[`boot/TESTING.md`](boot/TESTING.md). The condensed status and open issues are
in [`docs/status.md`](docs/status.md).

## What is not solved

- The smooth SteamOS cursor currently depends on `KWIN_FORCE_SW_CURSOR=1`; a
  real cursor plane in nvkvm is still the durable fix.
- The VM installer now produces an A/B image that can exercise SteamOS update
  behavior, but an end-to-end OTA update-hook run is not documented here yet.
- nvkvm-pv is experimental and is not yet a fully mature hardened guest/host security boundary.
  Do not use it for untrusted tenants. The steamOS QEMU VMM is placed in a tight sandboxed container without access to your display socket to significantly reduce the harm of a breakout. 

## FAQ

**Is this a VFIO utility to bind the GPU to a VM?**
No, there is no VFIO and no real GPU device is bound to the VM, your host GPU is genuinely shared with the VM similar to CUDA containers.
The VM only has access to your GPU to do graphics and compute.

**Will my GPU work?**
Only NVIDIA GPUs work. Turing (GTX 16xx / RTX 20xx) or newer. Six architectures are tested, from GTX
1660 to H100 — see tested platforms under nvkvm-pv. Pascal and older do not work.

**How much resources will the VM get from my GPU?**
The VRAM and Cuda cores are shared, just like in cuda containers. If the VMM is put in a container, then it only has access what the container was provisioned with.

**How can I enter fullscreen or let my in-game character follow my mouse movements**
Press CTRL+ALT+F to enter fullscreen mode, press it again to exit.
Press CTRL+ALT+G to enter Grab mode, in grab mode you will give up your keyboard and mouse to the guest until you press the shortcut again. For most first/second games to move your character, you need to enter grab mode. This will allow the guest to receive real mouse movements (dx/dy) instead of absolute coordinates over the guest window.

**Will my GPU driver work?**
Only the host driver matters, the guest will install the driver version for cuda userspace automatically thats installed on the host. Only the official NVIDIA GPU kernel driver is supported [https://github.com/nvidia/open-gpu-kernel-modules](https://github.com/nvidia/open-gpu-kernel-modules), most distros pre-install the open source driver if you have a Turing or newer GPU. Nouveau is not supported. A large ranges of drivers is supported, nvkvm-pv tracks 216 ogkm tags for ABI, not all driver versions have been equally throughly tested though. See the nvkvm-pv project for the support matrix.

**Will my VM break if my host driver updates?**
No, at VM boot it checks through nvkvm the host driver version and as soon as there is a mismatch, it automatically installs the official NVIDIA run for that driver version before proceeding. This means if your host distro updates your steamOS VM will automatically follow

**Will it follow SteamOS updates?**
Yes, during an A/B update the boot script will ensure the new updated image gets the proper nvkvm, libcuda and cuda Vulkan libraries.

**Is headless supported?**
Possible, nvkvm-pv supports headless rendering desktops, that you can remotely connect to. However it hasn't been configured with the scripts in this repository

**Will anti-cheat work?**
No, most anti-cheat usually breaks under VMs and this is a won't fix. Rigorous anti cheat deliberately only works on bare metal with full root access to your system, many use kernel modules.
Games relying on anti cheat cannot be reliably sandboxed, you have to trust the vendor of the game that they have properly secured the game client to be resilient against possible untrusted multiplayer servers or players.

**Will DRM protected games work?**
Likely, as DRM is not as strict as anti cheat and Steam uses your account to authenticate rather than the device.

**Where is my game data stored and how can I increase disk space?**
In a qcow2 disk image, which contains 2 read-only fixed size partitions containing the steamOS image called A/B, allowing for atomic updates with fallback to an older version if it fails to boot, and a home partition containing all your files and games, always sitting at the end that can grow unlimited. The docker container sets the size to atleast 64GiB and atmost 1024GiB at 60% of the free space on the host system. If the disk is too small then you can resize the disk and the last partition.

**How to copy and paste clipboard text?**
If using the broker (the docker container setup) then copy/paste is through vdagent (QEMU SPICE). The broker only allows copy when the window is in focus, paste is only allowed on explicit consent (pressing CTRL+V or CTRL+SHIFT+V) during window focus (similar to Firefox/Safari), so pasting through menu options might not receive your host clipboard, press CTRL+V to send it to the guest even if the shortcut itself does nothing in the guest software.

**Why are there multiple containers with VMM, broker and audio in docker-compose.yml (not steamOS specific)?**
That primarily is to significantly improve the security of the system in case the VM is broken out. To play the guest OS with native performance, the VMM (the process managing your VM) needs access to the display window, headless game streaming would introduce unnecessarily lag and complexity. Mounting your display socket (wayland/X) would give the VMM full access to your display and inputs, effectively an almost host OS compromise. To reduce the risk, a broker is placed in a seperate container giving the VMM only access to the display contents and only access to the inputs when the window is in focus or if the user entered grab mode. This still allows zero copy rendering without lag. The rhird container is the same principle as for display but then for audio.

Most QEMU breakouts/bugs (or nvkvm bugs) that end up in the VMM now strand in an unprivileged cuda container with most capabilities stripped and nowhere to attach a keylogger. A host kernel level breakout through KVM itself is far less likely.

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
