# Tutorial: SteamOS on nvkvm, from a bare Debian host to a running game

Every command, in order, starting from a Debian/Ubuntu machine with an NVIDIA
GPU and nothing else set up. Allow **90 minutes**, most of it QEMU compiling and
SteamOS downloading.

> **Read this first — what is proven and what is not.**
>
> - The end state described here **was reached on real hardware on
>   2026-08-23**: a physical RTX 4070 workstation, host driver 595.84, SteamOS
>   3.8.14 guest, GL zero-copy at 60 fps, **Portal 2 launching and playing**.
>   The logs are in [`evidence-pc-20260823/`](evidence-pc-20260823/).
> - That host was an **Ubuntu-class system running a Wayland GNOME session**.
>   The Debian package names in step 2 come from nvkvm-pv's own dependency
>   probe, which recognises Debian/Ubuntu; **the sequence below has not been
>   re-run start-to-finish on a clean Debian install.** If something does not
>   match, the mechanism is right and the packaging may not be.
> - **Mouse-look does not work** in the configuration this tutorial produces.
>   That is a real, current limitation, not something you have done wrong.
>   Read [Step 8](#step-8--the-mouse-look-problem-read-before-you-blame-yourself)
>   before you get to it.
>
> The README now points at the two-container deployment. This document is the
> older low-level walkthrough, with the host build included and nothing assumed.

---

## Step 0 — Check the host can do this at all

```sh
uname -m                                   # must be x86_64
ls -l /dev/kvm                             # must exist and be readable by you
cat /proc/driver/nvidia/version            # the NVIDIA driver must be loaded
cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null   # 1, or absent
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
ls /dev/dri                                # must exist -- see below if it does not
```

- **x86-64 only.** nvkvm's isolate stub is x86-64 assembly; the build refuses
  anything else in one line rather than after twenty minutes.
- **The driver must be loaded**, not merely installed: QEMU's device realize
  opens `/dev/nvidiactl` and fails hard if it cannot.
- **Unprivileged user namespaces must be enabled** — the isolate sandbox uses
  `CLONE_NEWUSER` + `pivot_root`. Without them nvkvm degrades to a weaker
  seccomp isolation and *says so loudly*; it still works, but you should know
  which one you are running.
- **You do not need root to run the guest.** Running QEMU as an ordinary user
  was verified on the bare-metal box: full forwarding, zero-copy, 60 fps.
- **`/dev/dri` must exist, and on a headless host it usually does not.** A
  compute-only machine loads the NVIDIA driver without `nvidia_drm`, so there
  are no DRM nodes at all, and no compositor in the guest can ever start. Load
  it with modesetting:

  ```sh
  sudo modprobe nvidia-drm modeset=1
  ls /dev/dri                              # card0 / renderD128 should appear now
  ```

  Persist it with `options nvidia-drm modeset=1` in `/etc/modprobe.d/`. Note
  that `docs/` elsewhere says a compute host "has no `/dev/dri` and does not
  need one" — that is true for CUDA, and false here. Rented GPU boxes are all
  in this state.
- **On an X11 host, authorise the container to the X server first.** Run this
  once per login, before `docker compose up`:

  ```sh
  xhost +si:localuser:root
  ```

  Without it the broker fails with `Authorization required, but no
  authorization protocol specified` and `xcb_connect failed`, *even when
  `XAUTHORITY` is set and the cookie file is valid* — X cookies are keyed by
  hostname and display, and the container matches neither. Check which session
  you are actually in first, because it is not always the one you think:

  ```sh
  echo $XDG_SESSION_TYPE      # x11 or wayland
  ```
- **A display server the host can actually present to.** `Xvfb` does not work:
  it has no DRI3, and the broker refuses it (with an explicit error saying so).
  You need a real X11 or Wayland session, or the container path with the host's
  own compositor.

Note the driver version from `nvidia-smi`. Everything downstream pins to it.

## Step 1 — Get the repositories

```sh
mkdir -p ~/nvkvm && cd ~/nvkvm
git clone https://github.com/reindertpelsma/nvkvm-pv.git
git clone https://github.com/reindertpelsma/nvkvm-steamos.git
```

**`nvkvm-pv` is the one that matters at runtime.** It is what gets shared into
the guest over 9p, and `steamos_boot.sh` builds the guest kernel module from
`nvkvm-pv/src/guest`. This repository (`nvkvm-steamos`) holds the SteamOS
evidence and documentation; `boot/` here is a published copy of nvkvm-pv's
`boot/`, so the mechanism can be read without cloning both.

> Point the 9p share at `nvkvm-pv`. A share pointed at `nvkvm-steamos` fails
> with `nvkvm guest source not found at /run/nvkvm/src/guest`.

## Step 2 — Build nvkvm's QEMU, with a window

nvkvm is a patched QEMU 9.2.0 (ten patches, plus a file copy) and a small
freestanding "isolate stub" binary. One script builds both.

```sh
cd ~/nvkvm/nvkvm-pv
sudo bash scripts/build_qemu.sh --install-deps      # installs deps, needs root
```

On Debian/Ubuntu `--install-deps` installs:

```
ninja-build meson libglib2.0-dev libpixman-1-dev python3 python3-venv
python3-tomli git libslirp-dev pkg-config libattr1-dev
libepoxy-dev libgbm-dev libegl-dev libdrm-dev xxd
```

If you would rather install them yourself, run `bash scripts/build_qemu.sh`
without the flag: it probes, refuses to install anything, and prints exactly
what is missing with the package line for your distro.

### The one flag you must not omit

**The default build has no window at all** — it configures with
`--disable-gtk --disable-sdl`, because a headless compute build should not
carry display attack surface. For SteamOS you need a window:

```sh
sudo NVKVM_QEMU_UI=1 bash scripts/build_qemu.sh --force
```

`--force` matters too: the script **exits 0 without rebuilding** if the binary
already exists, so if you ran it once without `NVKVM_QEMU_UI=1`, a plain re-run
is a silent no-op and you will spend an hour wondering why `-display gtk` is
rejected.

Output: `/opt/qemu-nvkvm/bin/qemu-system-x86_64` (or
`~/.local/share/nvkvm/qemu-nvkvm/...` if `/opt` is not writable). Check it:

```sh
/opt/qemu-nvkvm/bin/qemu-system-x86_64 -display help    # must list gtk and sdl
/opt/qemu-nvkvm/bin/qemu-system-x86_64 -device help | grep nvkvm
```

You want to see both `virtio-nvgpu-pci` and `nvkvm-gpu` in that second listing.

> **You may not need to build at all.** nvkvm-pv publishes a release tarball
> and a container image, both with build provenance you can check with
> `gh attestation verify`. But **the released binary is headless**, so for this
> tutorial you want the source build.

## Step 3 — Get a SteamOS image

Download Valve's **SteamOS recovery image** (the "Steam Deck Recovery
Instructions" download). Everything documented in this repository was done with
`steamdeck-repair-20250521.10-3.7.7`, which is still downloadable directly:

```sh
curl -O https://steamdeck-images.steamos.cloud/recovery/steamdeck-repair-20250521.10-3.7.7.img.bz2
```

That URL is a **pin, not the only option** — newer recovery images appear under
the same `recovery/` prefix, and a newer one is often what you want, because
provisioning refuses (correctly) if Valve's pool no longer carries kernel headers
for the exact kernel in your image.

```sh
cd ~/nvkvm
unzip steamdeck-repair-*.img.zip          # -> steamdeck-repair-*.img
cp steamdeck-repair-*.img work.img        # keep the pristine one
```

Keep the original. You will want to start over at least once.

> **Steps 4 and 5 are one command if you want them to be.**
> ```sh
> sudo ~/nvkvm/nvkvm-steamos/build_steamos_image.sh \
>   --src ~/nvkvm/steamdeck-repair-20250521.10-3.7.7.img \
>   --share ~/nvkvm/nvkvm-pv
> ```
> [`build_steamos_image.sh`](build_steamos_image.sh) mechanises everything from
> here to the end of step 5, including two bind mounts the text below omits, and
> cleans up after itself when it fails. Read
> [`docs/manual-install.md`](docs/manual-install.md) for the by-hand version with
> the reason for every step; the rest of this section is the short form.

## Step 4 — Grow the image, and repair the GPT

Grow the disk before doing anything else. This is what gives the guest a
persistent, disk-backed `/home` — `/home` is the **last** partition and this
image expands it into the new space by itself on first boot, which is where
Steam's runtime and every game live. It does *not* grow the 5 GB btrfs rootfs
(not last on disk); that constraint is handled by the `steamos` trim profile and
the pre-flight check in step 5.

```sh
truncate -s +60G work.img
sudo losetup -Pf --show work.img          # note the device, e.g. /dev/loop0
sudo sgdisk -e /dev/loop0                 # -> "The operation has completed successfully"
```

Two measured traps here, both of which fail in ways that point elsewhere:

- **`sgdisk -e` is mandatory.** Growing the file leaves the backup GPT header at
  the old end-of-disk. Linux tolerates that — `lsblk` and `mount` work fine,
  which is why provisioning succeeds — but **OVMF does not**, and it fails by
  finding no bootable device rather than by complaining about the GPT.
- **Run it on a loop device, not on `/dev/nbd0`.** Against nbd, `sgdisk` fails
  with `Read error 5`, reports zero partitions, and its `-e` write fails.

```sh
lsblk /dev/loop0                          # find the SteamOS rootfs partition
```

## Step 5 — Provision the image, offline

This is the whole install. One command builds the guest kernel module against
the image's own kernel, installs the NVIDIA userspace matching **your host's**
driver, writes the desktop configuration, and plants the systemd units that make
the guest self-provisioning from then on.

```sh
sudo mkdir -p /mnt/steamos
sudo mount /dev/loop0p<rootfs> /mnt/steamos
sudo btrfs property set /mnt/steamos ro false

# the 9p share, at the path the script expects, standing in for the real thing
sudo mkdir -p /run/nvkvm
sudo mount --bind ~/nvkvm/nvkvm-pv /run/nvkvm

sudo ~/nvkvm/nvkvm-pv/boot/steamos_boot.sh --install-only --root /mnt/steamos
```

`--install-only` (Part 1) touches **no running-kernel state**, which is what
makes it safe to run against a root that is not the one you booted. The systemd
units have to be planted this way because they are not in the image until
something puts them there — after this, the guest converges itself at every
boot and you never do this by hand again.

A healthy run ends with:

```
[nvkvm] === Part 1 finished (rc=0) ===
```

**If it says `rc=1`, read the log rather than continuing** — it names what
failed. The usual causes, each a measured failure:

| symptom | cause |
|---|---|
| `could not install core build tools`, `Could not resolve host` | the chroot has no resolver. Copy a working `/etc/resolv.conf` into `/mnt/steamos/etc/` and re-run. |
| refuses with a version-pin error on `linux-neptune-*-headers` | Valve's repo no longer carries headers for the exact kernel in your image. **This is correct behaviour**: building against a newer neptune point release silently produces a module that loads nowhere. Use a newer recovery image. |
| `nvkvm guest source not found` | the bind mount points at the wrong repo. It must be **nvkvm-pv**. |
| pre-flight stops at `free=634M vs needed=768M` | you skipped step 4. |

Optionally, before unmounting, drop an SSH key so you can get a shell into the
guest later. Its presence *is* the switch — no flag, no default:

```sh
cp ~/.ssh/id_ed25519.pub ~/nvkvm/nvkvm-pv/data/authorized_keys
```

Then tear down — **carefully**:

```sh
sudo sync
sudo umount -R /mnt/steamos        # a real unmount. NEVER umount -l here.
sudo umount /run/nvkvm
sudo losetup -d /dev/loop0
qemu-img convert -O qcow2 work.img steamos-nvkvm.qcow2
```

> **Do not lazy-unmount.** `umount -l` returns before the flush completes, and
> `qemu-img convert` then captures a pre-flush filesystem. This was measured:
> the result was a **0-byte `libnvidia-ml.so`** inside the qcow2 while the same
> file was 2.2 MB on the mount that had just been released, and it presented as
> a driver bug.

## Step 6 — Boot it

```sh
cd ~/nvkvm
QCOW=$PWD/steamos-nvkvm.qcow2 \
SHARE=$PWD/nvkvm-pv \
QEMU=/opt/qemu-nvkvm/bin/qemu-system-x86_64 \
WORK=$PWD \
  nvkvm-steamos/boot/run_steamos_nvkvm.sh
```

If you would rather type the command line yourself, three of its flags are
load-bearing and each was found by bisection:

| flag | what happens without it |
|---|---|
| `-fw_cfg opt/ovmf/X-PciMmio64Mb,string=262144` | nvkvm reserves a ~145 GiB 64-bit GPA window; OVMF's default aperture is far smaller and it **hangs in firmware before the bootloader, with no error on any console.** This is the single most confusing failure in the whole path. |
| `-device nvme,drive=nvm0` | SteamOS expects its partitions at `/dev/nvme0n1p*` and will not find its root. |
| `gl=on` on the display | QEMU's GTK backend gets no GL context, nvkvm falls back to `readback`, and you get a working but copying present path instead of zero-copy. |

The script defaults to `-vga none`, which is deliberate: with no other VGA-class
device in the machine, anything you see came through nvkvm. Set `VGA=vga` if you
want the emulated VGA back for the early boot console.

## Step 7 — Confirm it actually worked

**On the host**, in QEMU's stderr (the script sets `NVKVM_PRESENT_TIMING=1`):

```
nvkvm present: display mode = GL zero-copy (host UI renders on NVIDIA: native import);
               host GL renderer: NVIDIA Corporation / NVIDIA GeForce RTX 4070/PCIe/SSE2
nvkvm disp stats: 60.0 frames/s dropped=0 failed=0 present_mean=0.31ms
```

`GL zero-copy` is the good one. `readback` means the UI backend gave QEMU no GL
context — check `gl=on`, and check that step 2 was built with
`NVKVM_QEMU_UI=1`.

**In the guest** (`ssh -p 15022 deck@127.0.0.1` if you installed a key):

```sh
journalctl -u nvkvm-boot.service | tail -20
# ... module up to date at <commit>
# ... NVIDIA userspace matches host (595.84)
# ... Part 1 finished (rc=0)
# ... validation OK -- handing over to the desktop

nvidia-smi                       # the host's GPU, plus kwin/Xwayland/plasmashell
ls -l /sys/class/drm/card0/device/driver     # -> .../nvidia, by NAME not index
lsmod | grep bochs                            # with -vga none: nothing
```

Two log lines that look alarming and are not — they appear on a fully working
system and correlate with no failure:

```
nvkvm: DENY ctrl cmd 0x00730102
nvkvm: DENY ctrl cmd 0x2080220b
```

## Step 8 — The mouse-look problem, read before you blame yourself

**Under `gtk,gl=on`, QEMU does not deliver pointer lock.** The desktop works,
games render, but mouse-look does not. This is not a misconfiguration and there
is no setting in the guest that fixes it.

Root cause, measured on the same 4070 box (2026-08-21): with the pointer
grabbed, **zero** `REL_X`/`REL_Y` events reach the guest's virtio mouse. QEMU is
an **X11 client under Xwayland** on a Wayland host, and the confine and warp
primitives GTK's grab depends on are not available to it, so no deltas are ever
queued. The host cursor leaves the window while "grabbed", which is the visible
tell.

**SDL does not have this problem** — it runs QEMU as a native Wayland client
with a real `zwp_pointer_constraints_v1` pointer lock, and **Minecraft is
playable at max settings** through it on this project's Mint guest.

**But the SteamOS guest under SDL is currently a black window**, while QEMU
reports zero-copy at ~60 fps and the guest is fully alive underneath. **The
cause is not established.** It is guest-specific — same host, same nvkvm build,
the Mint guest renders fine — and closing it is the one thing standing between
SteamOS and fully playable gaming here.

Try it anyway; if it renders on your machine, that is a finding worth reporting:

```sh
VM_DISPLAY=sdl,gl=on  ... nvkvm-steamos/boot/run_steamos_nvkvm.sh
```

There is a **second, unrelated** pointer problem that *is* fixed: the Plasma
cursor was unusably laggy because nvkvm's virtual KMS has **no cursor plane**
(`GETPLANERESOURCES` returns 0 planes). `KWIN_FORCE_SW_CURSOR=1` now ships in
`write_desktop_config` and takes the error count from 621 per 15 s of motion to
0. That is a workaround; a real cursor plane in nvkvm is the fix and is not
done.

## Step 9 — Steam, and a game

Nothing further is needed on the GPU side — the desktop is already on it.

1. In the Plasma session, launch **Steam**. It is already in the image.
2. Sign in. This needs your real credentials and will hit 2FA; it cannot be
   automated and this project does not try.
3. Install a game and launch it.

**Portal 2 launches and plays** from here — menu and in-game, smooth, with
nvkvm's present counter at ~60 fps. It is a **32-bit Source title**, which makes
it a better test than it looks: it exercises the `lib32` NVIDIA libraries that
the `steamos` trim profile deliberately keeps, and those are exactly the
libraries an earlier hand-written library list silently omitted.

*Observed on the physical screen. Not captured to a log file, and no frame-time
capture of the game itself was taken.*

Two things to expect:

- **Mouse-look will not work** under GTK. See step 8. A menu-driven or
  keyboard-driven game is playable; a first-person shooter is not.
- The session is **Plasma**, not `gamescope-session`. Steam's Big Picture path
  under gamescope has been shown to select the GPU and enumerate DRM format
  modifiers, but a *game* has not been run through `gamescope-session` since
  the trim profile landed.

## Step 10 — Updates

Nothing to do. A SteamOS update replaces the whole rootfs, so everything
installed in step 5 is gone in the new image; `nvkvm-plant-stub.path` notices
the staged update and runs the same script against the new root, which re-arms
itself there.

The update gate can only ever check *"did it build and install"*, never *"does
it work"* — it runs on a live system against a different kernel, so it cannot
load the module. That is why the boot half has a recovery menu.

> **Not yet verified.** The update hook has never been exercised against a real
> rauc A/B device. The recovery image is single-slot, so
> `/dev/disk/by-partsets/other/rootfs` does not exist there and rauc's A/B
> semantics are absent. The `--install-only` half of the mechanism is proven;
> the trigger is not.

---

## Going further: a real installed SteamOS instead of the recovery image

The tutorial above provisions the **recovery image** and runs it directly. That
is the fully documented path and everything in this repository's measurements
except one file was taken that way.

The 2026-08-23 bare-metal run went one step further and provisioned a **real
installed SteamOS with both A/B slots**:
`evidence-pc-20260823/part1_rerun.log` is a Part 1 run against the second slot
(`ROOT=/mnt/sos_b`), and `guest-boot-evidence.txt` is that installed system
booting with `ROOT=/` and `validation OK`.

Getting there means booting the recovery image under nvkvm and using **Valve's
own installer** inside it to install onto a second virtual disk — this project
neither automates nor documents that step, and the exact QEMU disk arrangement
used on the night was not captured. Once installed, provisioning is unchanged:
mount the installed rootfs (over `qemu-nbd` for a qcow2) and run the same

```sh
sudo steamos_boot.sh --install-only --root /mnt/<slot>
```

against each slot you care about.

## Where to go when something is wrong

| you want | read |
|---|---|
| what to run first | [`README.md`](README.md) |
| current status and open gaps | [`docs/status.md`](docs/status.md) |
| steps 4-5 by hand, with the reason for every step | [`docs/manual-install.md`](docs/manual-install.md) |
| what has been tested, on which machine, and what failed | [`boot/TESTING.md`](boot/TESTING.md) |
| how any of this was originally worked out (historical) | [`NOTES.md`](NOTES.md) |
| why the old scripts are gone | [`archive/README.md`](archive/README.md) |
| the raw logs from the bare-metal run | [`evidence-pc-20260823/`](evidence-pc-20260823/) |
