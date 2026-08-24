# nvkvm-pv on SteamOS

Running [SteamOS](https://store.steampowered.com/steamos) as a guest of
[nvkvm-pv](https://github.com/reindertpelsma/nvkvm-pv), NVIDIA GPU
paravirtualisation for KVM.

**Status — 2026-08-23.** On a physical RTX 4070 workstation (host driver
595.84), SteamOS boots as an nvkvm guest, the whole Plasma desktop renders on
the GPU with **GL zero-copy**, and **Portal 2 launches and plays** — menu and
in-game, under the GTK display backend.

Gaming through nvkvm is proven, not aspirational: **Minecraft is playable at
max settings under the SDL backend**, which means SDL's pointer lock works. One
narrow gap remains, and it is the only thing between SteamOS and fully playable
gaming: **the SteamOS guest under SDL shows a black window**, cause unknown. See
[Display backends: which one to use](#display-backends-which-one-to-use).

SteamOS is an interesting target precisely because nothing about it was built
for this: it is immutable (read-only rootfs, atomic A/B updates), has no usable
package manager, is AMD-first, and ships **no NVIDIA support at all**.

> **This document is what is true now**, in brief.
>
> - **Reproducing it from scratch:** [`TUTORIAL.md`](TUTORIAL.md) — every
>   command from a bare Debian host, including building nvkvm's QEMU, through
>   to launching a game.
> - **Just the image, in one command:**
>   [`build_steamos_image.sh`](build_steamos_image.sh) — steps 1 and 2 below,
>   mechanised, with the pre-flight checks and the cleanup.
>   [`docs/manual-install.md`](docs/manual-install.md) is the same sequence by
>   hand, with the reason for every step.
> - **How any of it was found out:** [`NOTES.md`](NOTES.md) (the investigation
>   log, historical) and [`boot/TESTING.md`](boot/TESTING.md) (what was tested,
>   and on which machine).
> - **Superseded scripts:** [`archive/`](archive/README.md).

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

## Start here: image to running guest

Five steps. Everything after step 4 is automatic and re-runnable.

**If you are starting from a machine with nothing set up, use
[`TUTORIAL.md`](TUTORIAL.md) instead** — it is the same path with the host
build, the package lists, and every failure mode written out. What follows is
the at-a-glance version for someone who already has nvkvm-pv built.

### 0. What you need on the host

- A built **nvkvm-pv** checkout — its patched QEMU and its host-side module.
  See that repo; nothing here builds it.
- The NVIDIA driver loaded on the host (`/proc/driver/nvidia/version` readable).
- A SteamOS image. Everything below was done with the recovery image
  `steamdeck-oobe-repair-20260707.10-3.8.14`.

> **The 9p share is the `nvkvm-pv` checkout, not this repo.** `steamos_boot.sh`
> builds the guest module from `<share>/src/guest`, so a share pointed at
> *this* repo fails with `nvkvm guest source not found`. `boot/` here is a copy
> of nvkvm-pv's `boot/`, published so the mechanism can be read on its own.
>
> **The share needs both halves.** The public `nvkvm-pv` does not currently ship
> `boot/` (checked at `252bd44`, 2026-08-24), and `install_stub` needs
> `<share>/boot/image/` for the systemd units — so copy this repo's `boot/` into
> the checkout you share: `cp -r nvkvm-steamos/boot nvkvm-pv/`.

> **Steps 1 and 2 are one command if you want them to be:**
> ```sh
> sudo ./build_steamos_image.sh --src steamdeck-repair.img --share /path/to/nvkvm-pv
> ```
> [`build_steamos_image.sh`](build_steamos_image.sh) does exactly what the next
> two sections do, plus the pre-flight checks, the loop-device cleanup and two
> bind mounts the text below omits. The by-hand version, with the reason for
> every step and the traps around it, is
> [`docs/manual-install.md`](docs/manual-install.md).

### 1. Grow the image, and fix the GPT

The image needs room for a persistent `/home` — Steam's runtime and its library
live there, and on the recovery image `/home` is 2 GB and full. Growing the disk
is enough: `/home` is the **last** partition and this image expands it into the
new space by itself on first boot (measured: 2 G → 62 G with `+60G`). It does
**not** grow the ~5 GB btrfs rootfs, which is not last on disk.

**60 GB is a games budget, not a requirement.** It buys nothing at provisioning
time; `0` is enough to build the image, ~8–16 GB to boot and sign into Steam,
and more only if you install games — see
[`docs/manual-install.md`](docs/manual-install.md#so-how-much-do-you-actually-need).

```sh
cp steamdeck-repair.img work.img
truncate -s +60G work.img
sudo losetup -Pf --show work.img          # -> /dev/loopN
sudo sgdisk -e /dev/loopN                 # relocate the backup GPT header
```

`sgdisk -e` is **not optional**: growing the file leaves the backup GPT header
at the old end-of-disk. Linux tolerates that, **OVMF does not**, and it fails by
finding no bootable device rather than by saying anything. Run it against a
**loop** device — against `/dev/nbd0` sgdisk fails with `Read error 5`.

### 2. Provision the image offline

Mount the rootfs, put the nvkvm-pv checkout where the script expects the share,
and run Part 1 against the mounted root. `--install-only` touches no
running-kernel state, so it is safe to run against a root that is not yours.

```sh
sudo mount /dev/loopNp<rootfs> /mnt/steamos
sudo btrfs property set /mnt/steamos ro false

sudo mkdir -p /run/nvkvm
sudo mount --bind /path/to/nvkvm-pv /run/nvkvm      # stands in for the 9p share

sudo /path/to/nvkvm-pv/boot/steamos_boot.sh --install-only --root /mnt/steamos
```

That one command does all of it: builds `nvkvm-guest.ko` against the image's own
kernel, installs the NVIDIA userspace matching the **host** driver version,
writes the desktop configuration, and plants the systemd units that make the
guest self-provisioning from then on. The units have to be planted this way
because they are not in the image until something puts them there.

Practical notes, each one a measured failure:

- The build runs `pacman` inside a chroot of the target root, so that root needs
  a working resolver (`/etc/resolv.conf`) and network. Without one the build
  step fails and Part 1 reports `rc=1`.
- Provisioning refuses, loudly, if Valve's repo no longer carries headers for
  the exact kernel in the image. That is correct behaviour, not a script bug —
  building against a *newer* neptune point release silently produces a module
  that loads nowhere.
- **Do not lazy-unmount before imaging.** `umount -l` returns before the flush
  completes and you will capture a pre-flush filesystem — with, for example, a
  0-byte `libnvidia-ml.so`.

```sh
sudo sync
sudo umount -R /mnt/steamos                 # a real unmount, never -l
sudo losetup -d /dev/loopN
qemu-img convert -O qcow2 work.img steamos-nvkvm.qcow2
```

### 3. Boot it

```sh
QCOW=/path/to/steamos-nvkvm.qcow2 \
SHARE=/path/to/nvkvm-pv \
QEMU=/opt/qemu-nvkvm/bin/qemu-system-x86_64 \
  boot/run_steamos_nvkvm.sh
```

Three flags in that script are load-bearing and were each established by
bisection:

| flag | why |
|---|---|
| `-fw_cfg opt/ovmf/X-PciMmio64Mb,string=262144` | nvkvm reserves a ~145 GiB 64-bit GPA window. OVMF's default aperture is far smaller and it **hangs in firmware before the bootloader, with no error on any console**. |
| `-device nvme,drive=nvm0` | SteamOS expects its partitions at `/dev/nvme0n1p*`. |
| `gl=on` on the display backend | plain `-display gtk` gives QEMU's GTK backend no GL context, and nvkvm falls back to `readback`. `gl=on` is what produces zero-copy. |

Two environment knobs on that script matter:

- `VM_DISPLAY` — defaults to `gtk,gl=on`, which is what renders on SteamOS
  today. `sdl,gl=on` is the backend with working pointer lock, but the SteamOS
  guest under it is currently a black window. Read
  [Display backends](#display-backends-which-one-to-use) before choosing.
- `VGA=vga` keeps an emulated VGA for the boot console. The default `-vga none`
  is the decisive configuration — with no other VGA-class device in the
  machine, anything you see came through nvkvm.

A healthy first boot logs, in the guest journal:

```
module up to date at <commit> → NVIDIA userspace matches host (<version>)
→ Part 1 finished (rc=0) → validation OK
```

and on the host, with `NVKVM_PRESENT_TIMING=1` (the script sets it):

```
nvkvm present: display mode = GL zero-copy (host UI renders on NVIDIA: native import);
               host GL renderer: NVIDIA Corporation / NVIDIA GeForce RTX 4070/PCIe/SSE2
nvkvm disp stats: 60.0 frames/s dropped=0 failed=0 present_mean=0.31ms
```

### 4. Use it

Log into Steam in the Plasma session and install a game. Nothing else is needed
— the desktop is already on the GPU. **Portal 2 launches and plays** from here,
under `gtk,gl=on`, with the pointer-lock caveat in
[Display backends](#display-backends-which-one-to-use).

Optional, and worth it: drop an SSH public key at `data/authorized_keys` in the
nvkvm-pv checkout that is shared over 9p. Its presence *is* the switch — the key
is installed and sshd enabled on the next converge, and with the run script's
`hostfwd` the guest is reachable at `ssh -p 15022 deck@127.0.0.1`. Absent, sshd
is never started.

### 5. Updates take care of themselves

A SteamOS update replaces the entire rootfs, so everything installed above is
gone in the new image. `nvkvm-plant-stub.path` watches for the staged update and
runs the same script against the new root, which re-arms itself there. Nothing
is copied by hand.

## What works — measured

All of the following on a physical RTX 4070, host driver 595.84, 2026-08-23,
on a **SteamOS 3.8.14 guest** unless a bullet says otherwise. Logs in
[`evidence-pc-20260823/`](evidence-pc-20260823/).

- **GL zero-copy**, not readback:
  `display mode = GL zero-copy (host UI renders on NVIDIA: native import)`,
  importing a 1920x1080 dma-buf with modifier `0x300000000606014` — an NVIDIA
  block-linear modifier, which llvmpipe or bochs could not produce. 60 fps,
  `present_mean` ~0.31 ms, zero dropped or failed frames. **This is a first for
  SteamOS here**; every earlier attempt, all on rented boxes, only ever reached
  readback.
- **Proven with `-vga none`**, not inferred from a visible desktop: the only
  VGA-class device in the machine is the RTX 4070, `/sys/class/drm` has
  `card0 -> nvidia` **by driver name**, there is no `card1`, and `bochs-drm` is
  not loaded at all.
- `nvidia-smi` in-guest reports the host's GPU, and KWin, Xwayland,
  plasmashell, Steam and steamwebhelper all appear as real GPU processes.
- **Portal 2 launches and plays** — menu and in-game, smooth, with nvkvm's
  present counter at ~60 fps. It is a **32-bit Source title**, so it exercises
  the `lib32` NVIDIA libraries that the `steamos` trim profile deliberately
  keeps. *Observed on the physical screen; not captured to a log file, and no
  frame-time capture of the game itself was taken.*
- **Games are playable through nvkvm** — Minecraft runs at max settings under
  the SDL backend, mouse-look included, which is direct proof that SDL's
  pointer lock works. *Different guest: that was on the project's non-SteamOS
  Linux guest, not on SteamOS. See
  [Display backends](#display-backends-which-one-to-use) for why the two are
  still separate results.*
- **Unprivileged QEMU works.** Run as a normal user (not root): full
  forwarding, zero-copy, 60 fps. `isolate` degrades from namespace to seccomp
  and says so loudly rather than silently.
- **The boot script converges at every boot** and needs no manual step after the
  one-time offline provisioning.

## Display backends: which one to use

Attribute every result below to its **guest** and its **backend** — the
behaviour differs along both axes, and mixing them up is how this got
mis-stated before.

| backend | pointer lock | Linux guest (Mint) | SteamOS guest |
|---|---|---|---|
| `sdl,gl=on` | **works** | renders; **Minecraft playable at max settings** | **black window** — cause unknown |
| `gtk,gl=on` | **does not work** | renders | renders; Portal 2 launches and plays |

- **SDL is the backend with working pointer lock.** It gives a real Wayland
  pointer lock
  (`zwp_pointer_constraints_v1` + `zwp_relative_pointer_v1` under
  `SDL_SetRelativeMouseMode`), and **Minecraft is playable at max settings**
  through it — a game that cannot be played at all without working mouse-look,
  which is what makes it proof rather than a frame counter. That was on the
  project's non-SteamOS Linux guest (the Mint guest used for nvkvm bring-up),
  not on SteamOS.

- **GTK renders everywhere but cannot grab.** On SteamOS under GTK, the desktop
  and games render and **Portal 2 launches and plays** — but pointer lock does
  not work, so mouse-look is unusable and games are not genuinely playable that
  way. nvkvm-pv's own pointer-lock investigation (2026-08-21, same 4070 box)
  measured **zero** `REL_X`/`REL_Y` events reaching the guest's virtio mouse
  while grabbed, and attributes it to QEMU running as an **X11 client under
  Xwayland** on a Wayland host: the confine and warp primitives GTK's grab
  depends on are not available to it, so no deltas are ever queued. That is a
  QEMU-on-Wayland limitation, not something a change in this repo fixes.

- **The one open gap: SteamOS + SDL is a black window.** QEMU reports zero-copy
  at ~60 fps and the guest is fully alive underneath, but nothing is visible.
  **The cause is not established.** The most useful clue anyone picking this up has is that it is
  **guest-specific**: the Mint guest renders correctly under SDL on the same
  host and the same nvkvm build, so this is not an SDL-wide or nvkvm-wide
  failure. It is one guest, one backend, and everything around it works.
  - There is a superficially similar failure elsewhere in the project —
    `could not bind the render-node context to the present thread`, where
    `nvkvm_present_capture()` and the present thread both bind the same EGL
    context and an EGL context can be current on only one thread at a time.
    **That is a hypothesis, and the Mint result argues against it**: the
    mechanism is host-side and would break Mint under SDL too, and it does not.

So: run SteamOS under `gtk,gl=on` today and accept that mouse-look does not
work, or close the SteamOS-under-SDL gap and get both. Neither half is worth
advertising as solved until that gap is closed.

## What does not work

### Mouse lag on the desktop — worked around, not fixed

The Plasma cursor was unusably laggy. **Root cause: nvkvm's virtual KMS has no
cursor plane.** `DRM_IOCTL_MODE_GETPLANERESOURCES` in-guest returns **0 planes**,
because `src/guest/nvkvm_kms.c` builds the pipeline with
`drm_simple_display_pipe`, which creates one primary plane and nothing else. KWin
therefore drives the cursor through a GL path that cannot work — 621
`GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT` errors per 15 s of motion, and the frames
were never presented at all rather than presented slowly.

`write_desktop_config` ships **`KWIN_FORCE_SW_CURSOR=1`**, which takes the count
to **0** and the user confirmed the cursor is smooth. That is a **workaround**.
The durable fix is a real cursor plane in nvkvm and **it is not done**.

A/B measurement: [`evidence-pc-20260823/cursor-latency-ab.txt`](evidence-pc-20260823/cursor-latency-ab.txt).

### Other open items

- **The update hook has never been exercised on a real A/B device.** The
  mechanism is written and its `--install-only` half is proven; rauc A/B
  semantics are not testable on a single-slot repair image.
- **`NVKVM_PRESENT_MODE=readback` hung the guest at the GRUB handoff** on an
  earlier host, reproducibly. Not root-caused. There has been no reason to use
  it since zero-copy started working.
- **Benign, and worth knowing so you do not chase them:** `nvkvm: DENY ctrl cmd
  0x00730102` and `0x2080220b` appear on a fully working system and correlate
  with no failure.

## Build

**[`build_steamos_image.sh`](build_steamos_image.sh) is the supported image
builder**: pristine `.img` in, provisioned qcow2 out, by wrapping
`steamos_boot.sh --install-only` rather than reimplementing it. It never touches
the input image, discovers the rootfs partition instead of assuming one, and runs
the whole loop-device + chroot phase inside a private mount namespace so a
crashed run cannot leave a half-unmounted tree behind. See
[`docs/manual-install.md`](docs/manual-install.md) for the same thing by hand.

The older image builder [`build_nvkvm_steamos_image.sh`](build_nvkvm_steamos_image.sh)
predates `steamos_boot.sh` and is **not** the supported path — it takes a
prebuilt `.ko` and hardcodes `KWIN_DRM_DEVICES=/dev/dri/card0` from observation
rather than a sysfs lookup. It is kept because it was run end to end and its
output booted to the same measured state, so it documents a working offline
recipe: NBD-mount, `btrfs property set ro false`, install the module, run
NVIDIA's own installer in a chroot, write config, resize.

For anything new, use `boot/steamos_boot.sh --install-only`.

## Two lessons worth more than the code

1. **Never hand-pick NVIDIA userspace libraries.** A hand-written file list
   omitted `libnvidia-glsi/tls/glcore/gpucomp`, so `libGLX_nvidia.so.0` failed
   to `dlopen`, Vulkan enumerated zero devices, and **no kernel activity
   happened at all** — which looked like an nvkvm forwarding bug and was not.
   Use `nvidia-installer --no-kernel-modules`: 69 files staged against ~19 by
   hand, including the 32-bit libs Steam needs. (Which Portal 2 then used.)
2. **Mount where you can, install where you must.** On a managed distro,
   mounting the host's driver libraries into the guest makes them track the host
   automatically. An immutable rootfs makes that impossible, so the installer is
   the only route — at the cost of pinning a version.

## Layout

| path | what |
|---|---|
| `boot/steamos_boot.sh` | **the one supported mechanism** — converge, validate, boot. A copy of nvkvm-pv's. |
| `boot/image/` | the four small files that live *inside* the SteamOS image: the units and the recovery menu |
| `boot/run_steamos_nvkvm.sh` | the QEMU command line, with every non-obvious flag explained |
| `boot/TESTING.md` | what was tested, on which machine, and what failed |
| `NOTES.md` | the investigation log — **historical**, predates the boot script |
| `evidence-pc-20260823/` | raw logs from the bare-metal RTX 4070 run |
| `evidence-vast-20260824/` | the scripted image build, run end to end, and the guest booting and converging by itself |
| `evidence/` | screendumps from inside the guest (earlier, rented boxes) |
| `patches/` | `0001-steamos-force-sw-cursor.patch` — the cursor workaround as a patch |
| `diagnostics/vk_probe.py` | ctypes-only Vulkan probe — the recovery image has no compiler |
| `nv2081_fix.diff` | adds the `NV2081_BINAPI` alloc-param size row to nvkvm |
| `build_steamos_image.sh` | **the image builder** — pristine `.img` → provisioned qcow2, wrapping `steamos_boot.sh --install-only` |
| `docs/manual-install.md` | the same provisioning by hand, and why each step exists |
| `build_nvkvm_steamos_image.sh` | the older image builder; see [Build](#build) |
| `TUTORIAL.md` | the full walkthrough: bare Debian host → built nvkvm → provisioned image → a game |
| `archive/` | superseded scripts, kept for reference — see [`archive/README.md`](archive/README.md) |
