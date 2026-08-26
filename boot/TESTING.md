# steamos_boot.sh — what was actually tested, and what failed

Test rig: vast.ai KVM VM (real `/dev/kvm`, RTX 3090 passthrough, host NVIDIA
580.105.08). The SteamOS repair image `steamdeck-oobe-repair-20260707.10-3.8.14`
was decompressed, loop-mounted, and Part 1 was run against it with
`--root <mounted rootfs>`, with a bind mount standing in for the 9p share.
This exercises everything except the 9p transport itself and an actual guest boot.

---

## AMENDMENT — 2026-08-25: standalone two-container deployment

Rig: the physical RTX 4070 workstation, host driver 595.84, Docker Compose,
GNOME/Wayland on the host, and the persisted genuine SteamOS A/B qcow2 from the
earlier run. The Docker build had no local `./nvkvm`, so it cloned public
`nvkvm-pv` main at `24b13f7d6f2b8773ef841309a691c98a777e065f` and built both
patched QEMU and the broker from that checkout.

**Proven in the published two-container layout:**

- SteamOS boots to SDDM's `plasma.desktop`; `kwin_wayland`, Xwayland, and
  `plasmashell` are live. The broker displays the 1920x1080 guest through its
  Wayland backend, and its X11 backend was also exercised.
- `nvidia-smi -L` reports the RTX 4070 and driver 595.84. The prebuilt probe
  creates a Vulkan device and verifies a 4096-element compute dispatch; the EGL
  probe creates an NVIDIA context and verifies both rendered pixels. CUDA is
  intentionally absent from the trimmed `steamos` profile.
- The VMM has no host display mount. QEMU has only `SETUID`, `SETGID`,
  `SETPCAP`, and `SYS_CHROOT`; sampled isolate processes had distinct high
  uid/gid values, root `/dev`, an empty capability bounding set,
  `NoNewPrivs: 1`, and two seccomp filters. The broker had no GPU/KVM device,
  no network, no VM state, and no effective or permitted capabilities.
- Recreating the broker Wayland -> X11 -> Wayland preserved the guest boot ID
  and left the VMM restart count at zero. Each broker received the cached
  1920x1080 frame after reconnect, without waiting for a new guest flip.

That restart test found one packaging defect before publication: the first VMM
image lacked `libGL.so.1`, so libepoxy aborted QEMU when broker loss briefly
activated QEMU's local fallback. Adding the `libgl1` runtime package fixed it;
the repeated test above is against the corrected image.

---

## AMENDMENT — 2026-08-23: a bare-metal run, and what it changed

Everything above and below this line, unless a note says otherwise, was
measured on the **rented vast.ai box (RTX 3090, host driver 580.105.08,
nested)**. On 2026-08-23 the same script ran on a **physical workstation
(RTX 4070, host driver 595.84)** with a real SteamOS A/B install, and that
moved the line in **both directions**. Read the rig before you read the result:
several conclusions in this file are properties of the rented box, not of the
script.

**Newly proven (bare metal, RTX 4070):**

- **Part 2 runs.** The guest boots, converges at every boot, loads the module
  and hands over to the desktop, with no manual step after the one-time offline
  provisioning. This file's *"No guest boot"* line is obsolete.
- **The module builds and installs through this script.** `module up to date at
  7ed98e26…` in `evidence-pc-20260823/part1_rerun.log` is `built_commit`
  matching `repo_commit`, and that `.commit` file is written by
  `build_and_install_module` and nothing else. The *"module was never actually
  built"* blocker was an artifact of the repair image's kernel being older than
  Valve's repo, not of the script.
- **GL zero-copy**, not readback — see the correction to *"Present path
  ANSWERED"* below.
- **A game runs.** Portal 2 launches and plays on the SteamOS guest, which
  retires this file's *"No actual game was launched"* caveat.

**Two real bugs this run found — both now fixed in `steamos_boot.sh`:**

1. **`ensure_build_deps` ran before the is-module-current check.** Caught in the
   act in `evidence-pc-20260823/part1_rerun.log`: `installing core build tools:
   gcc make` is printed *before* `module up to date at 7ed98e26…`. Two costs.
   It fetched gcc+make (55 MB down, 216 MB installed) on **every boot** on a
   rootfs with ~500 MB free and then removed them again; and on a root with no
   resolver the install fails, which set `rc=1` — so a **fully converged,
   perfectly working system reported `Part 1 finished (rc=1)` forever**. The
   toolchain fetch now lives inside the out-of-date branch, so it happens only
   when a build is actually going to happen.
2. **`validate()` returned a false CLASS 4 on a fully working system.** It gates
   on `ldconfig -p | grep libGLX_nvidia`, and on a real A/B install the offline
   chroot's `ldconfig` **did not persist** — `/etc/ld.so.cache` still had no
   NVIDIA entries on first boot. Everything worked anyway (the libs sit in
   `/usr/lib`, a default search directory, and the SONAME symlinks resolve), so
   the system printed *"validation FAILED … The desktop will start on the
   emulated VGA"* while the desktop was in fact running on nvkvm at 60 fps.
   This matters more than a cosmetic wrong message: **the recovery menu keys its
   three failure classes off `validate`**, so a green system was being routed
   into the recovery path. Fixed by running `in_target ldconfig` on **every**
   converge, not only after an install — cheap, idempotent, and it fixes
   `nvkvm-recovery.sh`'s own copy of the check at the same time, since both read
   the same cache. The check itself is unchanged.

   A green system reporting a hard failure is exactly as bad as the reverse, and
   this file exists to state what is proven — so it is worth naming the class of
   error: **the validator, not the system, was the thing that was broken.**

The reproduction path that reaches this end state is written out command by
command in [`../TUTORIAL.md`](../TUTORIAL.md).

**Still not exercised, on any rig:** the update hook against a real rauc A/B
device, the 30-second countdown, `nvkvm.skip=1`, and the interactive
`nvkvm-recovery.sh menu` selections. The CLASS-4 *branch* of Part 2 did run —
by way of bug 2 above — and printed its guidance correctly.

---

## AMENDMENT — 2026-08-24: the offline path, run end to end by a script

Rig: **vast.ai desktop-VM KVM instance, RTX 4090, host driver 570.133.20**,
nested but with real `/dev/kvm`. Ran
[`../build_steamos_image.sh`](../build_steamos_image.sh) — which wraps
`steamos_boot.sh --install-only` — against a freshly downloaded
`steamdeck-oobe-repair-20260707.10-3.8.14`, then booted the result under
**stock** QEMU 6.2 + OVMF. Logs: [`../evidence-vast-20260824/`](../evidence-vast-20260824/).

**Newly proven, and it closes this file's oldest open item:**

- **The module builds, installs and LOADS.** `module compile took 12s`,
  `module built and installed for 6.16.12-valve24.4-1-neptune-616-…`, and on the
  next boot `nvkvm_guest: loading out-of-tree module taints kernel`. The
  *"module was never actually built"* blocker was a property of an older image
  against Valve's pool: as of 2026-08-24 the exact-match headers for this
  image's kernel are back to **HTTP 200**, and `ensure_kernel_headers` fetches
  them.
- **The whole offline sequence works on the repair image**, which had never been
  taken past the pre-flight here: keyring init, `gcc`+`make` in the chroot,
  exact-match headers, the build area on `/home`, `nvidia-installer` with the
  type diversion, `restore_diverted_keepers`, the trim, the units. Part 1
  `rc=0`, wall time **1m48s** for the whole image.
- **The produced image boots and converges by itself.** OVMF loads from the
  NVMe (so `sgdisk -e` did its job), `nvkvm-boot.service` runs the planted
  `nvkvm-recovery.sh`, which mounts the **real 9p share** and hands over:
  `module up to date at 252bd44…`, `Part 1 finished (rc=0)`, `validation OK`.
- **`+60G` grows `/home`, not the rootfs** — measured on the booted guest:
  `home` 2 G → **62 G** on first boot, `rootfs-A` unchanged at 5 G / 89 % used /
  518 M free. The claim above that growing the image relieves rootfs pressure is
  wrong; it is a games budget. See
  [`../docs/manual-install.md`](../docs/manual-install.md#so-how-much-do-you-actually-need).

**Three defects this run found:**

1. **`locate_or_fetch_run` only knows one URL.** It builds
   `https://us.download.nvidia.com/XFree86/Linux-x86_64/<ver>/…`, and
   **datacenter-branch drivers are not published there**: 570.133.20 is `404`
   on that path and `200` under `/tesla/570.133.20/`. On any host running such a
   driver — which is most rented GPU boxes — Part 1 ends `rc=1` with
   `could not obtain the NVIDIA .run`, with the payload one URL away. Worked
   around here with `--nvidia-run`, which bind-mounts a local `.run` in and
   passes `--old-run-file`.
2. **`nvkvm-guest` NULL-derefs when it loads without an nvkvm device.**
   `nvkvm: host GPU discovery failed (-12); assuming 1`, then
   `BUG: kernel NULL pointer dereference … nvkvm_send_sync … nvkvm_open`, with
   `ksplashqml` as the caller. `/etc/modules-load.d/nvkvm.conf` force-loads the
   module, so *any* boot on a QEMU without the devices takes this — presenting
   as a black screen with a live cursor, then sshd dying. Guest-module bug, not
   an image bug, but it is what an unsupported QEMU looks like.
3. **`validate()` printed `validation OK` on that same boot**, because
   `/dev/nvidiactl`, `libGLX_nvidia` and the Vulkan ICD are all present while the
   device oopses on every open. The mirror image of the false CLASS 4 recorded
   in the 2026-08-23 amendment: the validator is again the thing that is wrong.

**Two things about the tooling around it, both measured:**

- **`pacman-key --init` leaves a `gpg-agent` running inside the chroot.** It
  outlives Part 1, holds the mounted image, and `umount -R` then fails with
  *target is busy* — which is precisely the moment someone reaches for
  `umount -l` and captures an unflushed filesystem.
  `build_steamos_image.sh` kills processes whose `/proc/<pid>/root` is inside the
  tree before unmounting.
- **The public `nvkvm-pv` does not contain `boot/`.** As of `252bd44` (and
  `integration-2026-08-23`) there is no `boot/steamos_boot.sh` and no
  `boot/image/` in that repository, so the README's
  `sudo /path/to/nvkvm-pv/boot/steamos_boot.sh` cannot be followed from a fresh
  public clone. This repo's `boot/` is the only published copy; copy it into the
  checkout you share.

**Still not exercised here:** anything to do with presentation. No nvkvm-patched
QEMU was built on this box, so no `virtio-nvgpu`, no `nvkvm-gpu`, no GL
zero-copy, no game — and therefore nothing in this amendment revises the
display findings below.

---

## Verified working (MEASURED)

- `ensure_pacman_keyring` — a freshly-mounted SteamOS rootfs has no initialised
  keyring; every pacman call fails with "keyring is not writable / required key
  missing". Initialising it once fixes it. `base-devel` then installs cleanly.
- `target_kver` picks the kernel the image BOOTS (the module dir containing
  `vmlinuz`), not the one that happens to have a build tree.
- Headers package derivation: `/usr/lib/modules/<kver>/pkgbase` gives
  `linux-neptune-616` directly; `linux-neptune-616-headers` is correct.
- Version pinning fails LOUDLY and correctly when the exact version is gone.
- `.run` sourcing: found on the share and used with no download (design note 1).
  The internet fallback also works — a 378 MB download at ~5 MB/s, and the
  archive's own `--check` passed.
- `.run` extraction + `nvidia-installer --no-kernel-modules`: installs the full
  userspace. All the libs that the old hand-rolled install silently missed are
  present: libnvidia-glsi, libnvidia-tls, libnvidia-glcore, libcuda,
  libGLX_nvidia, plus the glvnd EGL vendor JSON.
- `write_desktop_config` and `install_stub`: modprobe.d, modules-load.d, the
  recovery script, and all four units land correctly in the target root.

## Bugs found by testing, and fixed

1. **`local a="$1" b="${a}"` is broken under `set -u`.** Bash declares every name
   in a `local` list (unset) before performing any assignment, so `${a}` is
   unbound. Reproduced standalone. Split into separate statements.
2. **`log()` wrote to stdout**, and `locate_or_fetch_run` returns its path via
   stdout — so `run="$(locate_or_fetch_run ...)"` captured the log line together
   with the path, and every extraction failed with a misleading "no payload
   directory". All diagnostics now go to stderr.
3. **`/mnt` in SteamOS is a symlink to `var/mnt`**, and `/var` is a rauc-managed
   partition that post-install.sh REFORMATS on every update
   (`reformat_device_ext4 "$VAR_DEVICE_OTHER"`). Mount point moved to `/run/nvkvm`.
4. **The stub unit tested for a file on a filesystem nothing had mounted yet.**
   The in-image half now owns mounting the share; the share half owns the logic.
5. **The unpinned headers package installs the WRONG kernel.** MEASURED: asking
   for `linux-neptune-616-headers` on a `6.16.12-valve24.4-1` image installed
   `6.16.12.valve24.5-1` and created a second module directory. `target_kver`
   would then have picked it and built a module that loads nowhere. Now pinned via
   `kver_to_pkgver`, plus a vermagic assertion after the build as a backstop.
   (The generic `linux-neptune-headers` metapackage is even worse — it resolves to
   5.13.0.valve37-1.) This is the failure the design flagged as most likely, and it
   is subtler than expected: it fails *silently*, not loudly.
6. **`.run --target` is not honoured** — the archive forwards it to
   nvidia-installer. `-x` unpacks to `./NVIDIA-Linux-x86_64-<ver>/` in CWD.
7. **Extracting into the target rootfs fills it.** Now extracted outside the root
   and bind-mounted in, which is also what the proven offline recipe does.

> **[CORRECTED 2026-08-23, bare metal RTX 4070]** Two more, found only once the script ran on real hardware: `ensure_build_deps`
> firing before the is-module-current check, and `validate()` returning a false
> CLASS 4. Both are written up in the AMENDMENT section above.


## Still failing / open

> **[CORRECTED 2026-08-23]** Three of the four items below have moved. The module
> **does** build and install through this script; the guest **does** boot and
> Part 2 **does** run; disk space is no longer a hard blocker in practice,
> because the documented path grows the image by 60 GB before provisioning it
> (README step 1) — the underlying tightness of an *ungrown* 5 GB repair rootfs
> is unchanged and the pre-flight check still guards it. Only **the update hook
> against a real rauc A/B device** remains untested. See the AMENDMENT above.

- **The module was never actually built.** Blocked on 5: Valve's repo no longer
  carries headers for the repair image's kernel (`valve24.4`; the repo is on
  `valve24.5`). Not a script bug — the script correctly refuses. On a
  current image this path should work, but it is UNVERIFIED end to end.
- **Disk space is a hard blocker on the repair image.** The 5 GB rootfs cannot
  hold `base-devel` (~500 MB) + kernel headers + the NVIDIA userspace at once.
  MEASURED: with compat32, the install ran to 100% full and nvidia-installer died
  with **SIGBUS** mid-install; without compat32 the pre-flight check now stops it
  cleanly at free=634M vs needed=768M.
  Recommended fix (NOT implemented, wants a decision): install the toolchain,
  build the module, then REMOVE the toolchain before installing the driver. The
  header-removal logic already exists and would extend naturally. The alternative
  — building the module outside the guest and installing only the `.ko`, as
  `build_nvkvm_steamos_image.sh` does — is cheaper but gives up the
  "guest builds from the 9p repo at the matching commit" property.
- **The update hook has never been exercised** and cannot be, on this image: the
  repair image is single-slot, so `/dev/disk/by-partsets/other/rootfs` does not
  exist and rauc A/B semantics are absent. Needs a real installed device.
- **No guest boot.** Part 2, the countdown, `nvkvm.skip=1`, and the recovery menu
  are untested at runtime.

## nvidia-installer 580.105.08 — what it can actually target (MEASURED)

Run: `nvidia-installer --advanced-options` on the 580.105.08 payload on the box.

### Flags, against the hypothesis
CONFIRMED to exist: `--opengl-prefix`, `--opengl-libdir`, `--compat32-prefix`,
`--compat32-libdir`, `--x-prefix`, `--x-module-path`, `--x-library-path`,
`--utility-prefix`, `--utility-libdir`, `--application-profile-path`,
`--glvnd-egl-config-path`, `--documentation-prefix`, `--no-kernel-modules`.

REFUTED: there is **no `--prefix` and no `--libdir`**. There is no generic prefix at
all; it is split per component (opengl / utility / x / compat32 / wine / documentation).

Also present and not in the hypothesis: `--egl-external-platform-config-path`,
`--gbm-backend-dir`, `--gbm-backend-dir32`, `--compat32-chroot`, `--wine-prefix`,
`--wine-libdir`, `--xdg-data-dir`, `--no-opengl-files`, `--no-wine-files`,
`--installer-prefix`, and the decisive one:

    --override-file-type-destination=<FILE_TYPE>:<absolute path>

repeatable, keyed on the file types in the installer's own `.manifest`, and its
doc says it "takes precedence over any other options that might otherwise
influence the destination of the specified file type".

### Correction to a stated premise: the .run DOES have a manifest
`<payload>/.manifest`, 1248 lines, `<file> <checksum> <TYPE> [...]`, with a ~45-entry
type vocabulary. So "a .run has no manifest — nothing to enumerate, nothing to copy"
is not correct. It does not change the recommendation (an in-place install driven by
path flags is still cleaner than build-and-copy), but the blocker that was assumed
is not there.

### Measured size split (64-bit, KERNEL_MODULE_SRC excluded — `--no-kernel-modules`)
Total payload: **1383.6 MB**

Redirectable bulk (has a prefix/libdir flag, or an override type):
  OPENGL_LIB 427.2 | CUDA_LIB 411.3 | UTILITY_LIB 182.0 | OPENCL_LIB 107.6
  OPENGL_DATA 58.0 | NVCUVID_LIB 39.6 | UTILITY_BINARY 17.7
  GLX_MODULE_SHARED_LIB 12.8 | WINE_LIB 11.2 | XMODULE_SHARED_LIB 6.5
  GLVND_LIB 2.2 | GLX_CLIENT_LIB 1.5 | VDPAU_LIB 1.4 | ENCODEAPI_LIB 0.7
  EGL_CLIENT_LIB 0.2 | OPENCL_WRAPPER_LIB 0.1
  => approx **1,280 MB movable**

Must stay in the image (all the vendor configs and unit files):
  VULKAN_ICD_JSON(2), VULKANSC_ICD_JSON(1), EGL_EXTERNAL_PLATFORM_JSON(4),
  GLVND_EGL_ICD_JSON(1), CUDA_ICD(1), XORG_OUTPUTCLASS_CONFIG(1),
  SYSTEMD_UNIT(5) + SYSTEMD_UNIT_SYMLINK(6), APPLICATION_PROFILE(2),
  DOT_DESKTOP(1), ICON(1), SANDBOXUTILS_FILELIST_JSON(1), DKMS_CONF(2),
  and every *_SYMLINK type.
  => every one of these rounds to **0.0 MB**; together well under 1 MB.

  DOCUMENTATION 2.5 MB — also redirectable (`--documentation-prefix`).
  FIRMWARE 100.3 MB — GSP firmware (gsp_tu10x.bin, gsp_ga10x.bin), consumed by the
  KERNEL module. nvkvm supplies the kernel side from the host, so this is very
  likely unnecessary in the guest. NOT tested — flagging, not asserting.

compat32: the payload's `32/` tree is **392 MB**, and `--compat32-prefix` /
`--compat32-libdir` / `--compat32-chroot` all exist, so the 32-bit libraries are
redirectable too. That matters because SteamOS needs 32-bit for Steam, and the
current workaround is to drop them entirely (`NVKVM_NO_COMPAT32=1`).

### Verdict
The flags are there and the split is clean: **~1.28 GB (64-bit) + 392 MB (32-bit)
can move off the rootfs, leaving under ~3 MB of vendor configs behind.** It also
removes both of the compromises we are currently making — compat32 can come back,
and CUDA never has to be trimmed.

Dependency to design around: `/home` must be mounted before anything loads GL. An
`ld.so.conf.d` entry plus `ldconfig` handles the linker, but if `/home` fails to
mount the desktop loses GL entirely — `nvkvm-recovery.sh validate` should check the
library prefix is actually present, not just that ldconfig has an entry.

## SteamOS BOOTS as an nvkvm guest — and the two things that blocked it

Both found by bisection on the vast box, both reproducible.

### Blocker 1: `qemu-img resize` leaves a GPT that UEFI rejects
After `qemu-img resize <qcow2> +60G` the GPT's backup header is still at the OLD
end-of-disk. Linux tolerates this (lsblk/mount work fine, which is why provisioning
succeeded); **OVMF does not, and finds no bootable device.**
Fix: relocate the backup header with `sgdisk -e`. Do it on a **loop device over the
raw .img**, NOT over qemu-nbd — MEASURED: sgdisk against /dev/nbd0 fails with
"Read error 5", reports zero partitions, and its `-e` write fails. On a loop device
the same command reports "The operation has completed successfully".
Working order: cp raw -> truncate -s +60G -> losetup -P -> sgdisk -e -> provision
via the loop -> losetup -d -> qemu-img convert to qcow2.

### Blocker 2: `virtio-nvgpu` wedges OVMF unless its 64-bit PCI aperture is enlarged
Bisected by booting each device alone and reading guest RIP from the monitor
(kernel-space RIP = booted, firmware-range RIP = wedged):

    nvkvm-gpu only                  RIP=ffffffffa58d7aef   booted
    virtio-nvgpu only               RIP=000000007f46a561   WEDGED in firmware
    neither (control)               RIP=ffffffff928d7aef   booted

nvkvm reserves a large 64-bit GPA window (this host: "block base 0xdfdbc0000000
size 145 GiB"). OVMF's default 64-bit PCI MMIO aperture is far smaller, and it
hangs before GRUB rather than failing loudly. Fix, one flag:

    -fw_cfg opt/ovmf/X-PciMmio64Mb,string=262144

With it, both nvkvm devices attached: RIP=ffffffffa92d7aef and the SteamOS repair
desktop renders. Screenshot: steamos-nvkvm-boot.png in /workspace/nvkvm-steamos-vast/.

Debugging note that cost real time: with the nvkvm devices attached, nvkvm's scanout
becomes QEMU console 0, so a bare `screendump` captures nvkvm's
"Guest has not initialized the display (yet)" placeholder rather than the VGA — the
guest looks dead when it is merely rendering somewhere else. `screendump <file> <id>`
did not select the VGA either (and `-d <id>` is rejected outright: "unsupported
option -d"). Reading guest RIP from `info registers` is the reliable liveness check.

### Present path — NOT yet established
`NVKVM_PRESENT_TIMING=1` printed only
"nvkvm present: registered QemuConsole for guest GPU scanout (window display)".
No "display mode = ..." line appeared, because the guest compositor has not moved
onto nvkvm's plane yet, so nothing has been presented. GL-zero-copy vs readback is
therefore still unanswered on this 3090 host. Not asserting either.

## Present path ANSWERED: readback, and why — plus the compositor fix

> **[CORRECTED 2026-08-23, bare metal RTX 4070]** **The title is now rig-specific.** `readback` was this *rented box's* answer,
> and the section itself says so ("a rig limitation, not an nvkvm regression").
> On bare metal with `-display gtk,gl=on` the measured answer is
> `display mode = GL zero-copy (host UI renders on NVIDIA: native import)`,
> importing a dma-buf with the NVIDIA block-linear modifier
> `0x300000000606014` at 60 fps, `present_mean` ~0.31 ms, zero dropped or
> failed frames. `evidence-pc-20260823/final-state.txt`. Zero-copy remains
> unverified **on a 3090** — nobody has retried it there.


### Getting the compositor onto nvkvm's plane
Root cause of it staying on the VGA was an **ordering bug in my own unit**.
`nvkvm-drm-env.service` was ordered only `After=systemd-udev-settle`, so it ran
BEFORE `nvkvm-guest` was loaded. No card had driver `nvidia` yet, the loop matched
nothing, and it `exit 0`ed having written no file. MEASURED in-guest:

    systemctl is-active nvkvm-drm-env.service  -> active     (looks fine)
    ls /etc/environment.d/                     -> empty      (wrote nothing)
    kwin fds                                   -> card0 AND card1

i.e. the failure presented as success, and KWin auto-detecting both GPUs is the
known EGL-init failure. Fixed by ordering it `After=nvkvm-boot.service
systemd-modules-load.service` and polling up to 30s for a node whose driver is
`nvidia`, with a warning if none appears.

After the fix (fresh boot, zero manual steps):

    KWIN_DRM_DEVICES=/dev/dri/card0   in kwin_wayland's environ
    kwin fds -> /dev/dri/card0 + /dev/dri/renderD128 only, no card1
    card0 = driver nvidia (nvkvm), card1 = bochs-drm (the emulated VGA)
    nvkvm disp stats: 53.8 frames/s dropped=0 failed=0 present_mean=1.41ms

### The measurement
    nvkvm present: display mode = readback (UI console has no GL (e.g. -display vnc/curses))
    nvkvm present: host EGL ready (dma-buf import)
    nvkvm present: import fd=132 1920x1080 stride=7680 fourcc=0x34325241 modifier=0x0300000000606014

**readback on this host, and nvkvm says why: the UI console has no GL.** Note the
guest side is entirely healthy — host EGL is ready and dma-buf import is working
with a real tiled modifier; it is only the final present into the UI that copies.

This is a property of the QEMU UI backend, not of nvkvm and not of the 3090:
plain `-display gtk` gives QEMU's GTK backend no GL context. `-display gtk,gl=on`
is the flag that should yield zero-copy.

**`gl=on` was tried and did NOT work here**: QEMU came up but the guest never
reached a present, the monitor stopped answering `info registers`, and console 0
stayed on the placeholder. Reverted to plain `gtk`, which works. Not root-caused
— plausibly this box's X session (itself inside a VM, Xorg on the vast host's
virtual display) cannot give the GTK backend a usable GL context. On a real
workstation with a local X/Wayland session `gl=on` is the thing to try, and the
"GL zero-copy" line from NOTES.md's earlier 4070 session shows it does happen.

So: **readback is what this test rig produces, and it is a rig limitation, not an
nvkvm regression.** Zero-copy remains unverified on a 3090.

## Build time: 11-12s -> overlay stays EPHEMERAL

MEASURED across two clean runs: `module compile took 11s` / `12s`. Total Part 1
wall time ~60s including a headers download.

At that cost, create-build-destroy every run is simpler and strictly more correct
than caching: no versioning, no GC, no rollback edge case, and no way a stale
artifact can ever be reused. `build_area_up`/`build_area_down` already do exactly
this (an ext4 loopback on /home, made and destroyed per run), so no change was
needed. Versioning was NOT implemented, deliberately.

## Packages in the image: currently zero, by construction

`remove_added_packages` diffs `pacman -Qq` before and after and removes the
difference. On the last full run that was:

    gcc libisl libmpc linux-neptune-616-headers make pahole

Note `libisl`, `libmpc` and `pahole` are transitive/reactive installs that a
hand-maintained list would have missed — which is the argument for querying
rather than recording. After Part 1 the image carries **no added packages**, and
the resulting image boots, loads the module, and runs a Plasma session presenting
through nvkvm. That is the empirical answer to "do we need any packages in the
image": on this image, no.

Caveat worth stating: this is verified for the repair image's Plasma session. It
is not a proof for `gamescope-session` or for a Steam game, neither of which has
been run since the trim profile landed.

## SDL settled — and the readback reason is NOT "the rig has no GL"

> **[CORRECTED 2026-08-23, bare metal RTX 4070]** *"SDL settled"* is the wrong
> title for this section now, and its closing verdict — *"Working configuration
> for this box: `-display gtk`"* — is a statement about **that rented box**,
> not a recommendation.
>
> What is true now, attributed to guest and backend because the behaviour
> differs along both:
>
> | backend | pointer lock | Linux guest (Mint) | SteamOS guest |
> |---|---|---|---|
> | `sdl,gl=on` | **works** | renders; Minecraft playable at max settings | **black window**, cause unknown |
> | `gtk,gl=on` | **does not work** | renders | renders; Portal 2 launches and plays |
>
> - **SDL is not broken.** It gives a real Wayland pointer lock, and Minecraft
>   is playable at max settings through it on the Mint guest — a game that
>   cannot be played at all without mouse-look, which is what makes that a
>   proof rather than a frame counter.
> - **The SteamOS guest under SDL is a black window**, on the bare-metal box,
>   while QEMU reports zero-copy at ~60 fps and the guest is fully alive. The
>   cause is **not established**. The useful clue is that it is
>   **guest-specific** — same host, same nvkvm build, Mint is fine.
> - The `could not bind the render-node context to the present thread`
>   /`eglGetError=0x3000` failure recorded below was measured **on the 3090
>   box**. It is tempting to reach for it as the explanation of the SteamOS
>   black window, and the Mint result argues against it: that mechanism is
>   host-side and would break Mint under SDL too. Treat it as an open,
>   separate bug — the wrong-error-code half of it is a real defect either way.
> - **GTK's inability to grab is separately root-caused** and is not a
>   rig quirk: nvkvm-pv's pointer-lock investigation (2026-08-21) measured zero
>   `REL_X`/`REL_Y` events reaching the guest while grabbed, because QEMU runs
>   as an **X11 client under Xwayland** on a Wayland host and cannot confine or
>   warp the pointer.


The QEMU on the test box **is built with SDL**:

    -display help  -> none, gtk, sdl, egl-headless, dbus
    configure       -> "SDL support : YES 2.0.20", "sdl : enabled", "GTK support : YES"

So this is not a build-config gap. `scripts/build_qemu.sh` with `NVKVM_QEMU_UI=1`
produces both backends.

**The host has fully working GL**, which corrects my earlier guess:

    glxinfo -B (DISPLAY=:0, same env QEMU runs under)
      direct rendering: Yes
      OpenGL renderer string: NVIDIA GeForce RTX 3090/PCIe/SSE2
      OpenGL core profile version string: 4.6.0 NVIDIA 580.105.08

Results per backend, all on this box:

| `-display` | display mode | visible? | note |
|---|---|---|---|
| `gtk` | `readback (UI console has no GL)` | yes | expected: no `gl=on`, so no GL context offered |
| `gtk,gl=on` | never presented | no | QEMU came up, monitor stopped answering `info registers` |
| `sdl,gl=on` | `readback (UI never offered a GL context to probe)` | **no — black window** | see below |

The `sdl,gl=on` run produced the only real error, and it is an nvkvm-side one:

    nvkvm present: host EGL ready (dma-buf import)
    nvkvm present: could not bind the render-node context to the present thread
                   (eglGetError=0x3000); nothing will be displayed
    nvkvm present: display mode = readback (UI never offered a GL context to probe)

Two things worth flagging upstream:
- **`eglGetError=0x3000` is `EGL_SUCCESS`.** The code reports a bind failure while
  the EGL error code says nothing went wrong — so whatever actually failed is not
  being captured, and the diagnostic points nowhere. That is a bug in the error
  path regardless of the root cause.
- "nothing will be displayed" is literal: the SDL window stays black. A user who
  followed "build against SDL" advice would get a black screen with a message
  that only appears in QEMU's stderr.

This bind failure is **unique to the SDL run** — neither GTK run produced it.

**Conclusion: zero-copy is still unverified on a 3090, and the reason is now
specific rather than vague.** It is not "the rig has no GL" (it does) and not a
missing SDL build (it is there). nvkvm fails to bind its render-node EGL context
to the present thread on this host. Whether that is nested-virt-specific or a
genuine bug is NOT established here.

Working configuration for this box: **`-display gtk`** — readback, but visible
and stable.

## gamescope + Vulkan under the trim profile: WORKS

The open question was whether trimming CUDA/OpenCL breaks the gaming path. It
does not. All measured in-guest over the serial console, on the trimmed image:

    ls /usr/lib/libcuda*            -> (absent, trim confirmed)

    vulkaninfo --summary
      GPU0: deviceName = NVIDIA GeForce RTX 3090
            driverName = NVIDIA
            apiVersion = 1.4.312

    gamescope -W 640 -H 480 -- vkcube
      [gamescope] vulkan: selecting physical device 'NVIDIA GeForce RTX 3090': queue family 2
      [gamescope] vulkan: physical device supports DRM format modifiers
      [gamescope] vulkan: supported DRM formats for sampling usage: AR24 XR24 AB24 XB24 RG16 NV12 ...

    vkcube (directly, in the session)
      Selected GPU 0: NVIDIA GeForce RTX 3090, type: DiscreteGpu

gamescope **selects the GPU and enumerates DRM format modifiers** — which is
precisely the milestone the earlier M4 investigation was blocked on
("vulkan: failed to find physical device"). Under the trim profile that path is
healthy.

Caveats, stated rather than glossed:
- The nested `gamescope -- vkcube` run ended in `[Gamescope WSI] Failed to get
  Wayland objects` and vkcube dumped core. That is gamescope's WSI layer running
  *nested inside* KWin's Wayland session, not a driver or packaging fault —
  gamescope had already selected the GPU and set up its backend by then. A
  non-nested run needs its own VT/DRM master, which KWin currently holds.
- Two non-fatal `vkGetPhysicalDeviceFormatProperties2 returned zero modifiers`
  errors for the 10-bit formats AB4H/XB4H. gamescope continues past them.
- **No actual game was launched.** Steam is present in the image but needs a real
  login. "gamescope selects the GPU and Vulkan renders" is what is proven here.

> **[CORRECTED 2026-08-23]** A game has now been launched — **Portal 2, on the
> SteamOS guest on the bare-metal RTX 4070, under `gtk,gl=on`**: menu and
> in-game, smooth, nvkvm's present counter at ~60 fps. Portal 2 is a 32-bit
> Source title, so it also exercises the `lib32` NVIDIA libraries the `steamos`
> trim profile keeps — which the trim profile had not been proven against
> before. Mouse-look is unusable under GTK; see the SDL/GTK correction above.
> That run was through the **Plasma** session, not `gamescope-session`, so the
> gamescope caveats above still stand as written.


## Serial console: the in-guest access this project kept lacking

NOTES.md flagged the absence of a guest shell as a major time sink (keystroke
injection, OCR'd screendumps, `agent.py` over hostfwd). Much cheaper: bake a
serial getty into the image offline and give QEMU a unix-socket serial port.

    # offline, in the mounted rootfs
    chroot "$R" systemctl enable serial-getty@ttyS0.service
    sed -i 's|^root:[^:]*:|root::|' "$R/etc/shadow"          # VM-only throwaway
    printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear %%I 115200 linux\n' \
      > "$R/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf"

    # QEMU: a socket, not a file -- a file is write-only and gives no shell
    -serial unix:/root/work/serial.sock,server,nowait

Then drive it with socat. Every in-guest measurement above went through this.

## PROVEN: the desktop renders on nvkvm's plane, not the emulated VGA

The user asked for evidence rather than assertion, and frame counters are not it —
this repo has a commit literally named "present: stop reporting 60 fps at a blank
screen", so healthy stats are a documented false positive on this path.

**Test 1, `-vga none` (decisive).** Booted with no emulated VGA at all:

    QEMU: info pci  -> only VGA-class device is 10de:2204 (nvkvm's identity device)
    guest: /sys/class/drm  -> card0=nvidia ONLY. No card1, no bochs-drm at all.
    guest RIP -> ffffffffa6ad7aef  (kernel space: booted)
    screendump console 0 -> 1,176,287 bytes, 1920x1080, full SteamOS desktop

With no VGA in the machine there is nothing else the desktop could be on.
Screenshot: novga-console0.png.

**Corroborating (from the normal VGA-present config):**
- KWin's open fds are `/dev/dri/card0` + `renderD128` only. It never opened the
  bochs node. Confirmed `card0` is nvkvm **by driver name**, not by number:
  `card0 = nvidia`, `card1 = bochs-drm`.
- Resolutions disambiguate the consoles: nvkvm's connector Virtual-1 preferred
  mode is **1920x1080**; the bochs connector Virtual-2 is **1280x800**. The
  visible desktop is 1920x1080; a `screendump` of console 0 (which is the VGA in
  my device order, since `-device VGA` precedes virtio-nvgpu) returns a **blank
  1280x800, 2-colour** image. So the VGA has nothing drawing on it.
- nvkvm imported a 1920x1080 dma-buf with modifier `0x0300000000606014`, an NVIDIA
  block-linear modifier — llvmpipe/bochs would produce LINEAR (0x0).

Note for anyone repeating this: **which console is which depends on device order
on the QEMU command line.** With `-device VGA` before virtio-nvgpu, the VGA is
console 0 and a bare `screendump` grabs the VGA, not nvkvm.

## nvidia-smi: my bug, root-caused and fixed

Exact error from the guest:

    NVIDIA-SMI couldn't find libnvidia-ml.so library in your system. Please make
    sure that the NVIDIA Display Driver is properly installed and present in your
    system. ...
    EXIT=12

**Cause: `libnvidia-ml.so` (NVML) is typed `CUDA_LIB` in the installer's own
manifest**, and my `--override-file-type-destination=CUDA_LIB:...` diversion threw
the whole type away. Upstream's *filename* trim list deliberately keeps NVML — so
the manifest's TYPE granularity is coarser than the filename list, and my
"improvement" over install-then-delete silently over-removed. `CUDA_LIB` contains:

    TRIM  libcuda, libcudadebugger, libnvidia-nvvm, libnvidia-nvvm70, (32-bit ditto)
    KEEP  libnvidia-ml, libnvidia-ptxjitcompiler, libnvidia-sandboxutils, (32-bit ditto)

Vulkan and gamescope kept working throughout because neither uses NVML — which is
why this hid behind a green test run.

**Fix:** `restore_diverted_keepers()` re-installs, from the extracted payload,
every diverted-type file whose basename does NOT match upstream's trim regex,
into `/usr/lib` or `/usr/lib32` per its manifest path, then runs `ldconfig` to
recreate the SONAME symlinks that `nvidia-smi` actually dlopens. Driven by the
`.run`'s own `.manifest`, so it stays correct across driver versions.

Verified after the fix (in-guest):

    NVIDIA-SMI 580.105.08   Driver Version: 580.105.08   CUDA Version: N/A
    GPU 0: NVIDIA GeForce RTX 3090   1199MiB / 24576MiB   93% util

`CUDA Version: N/A` is **expected and correct** on the steamos profile — CUDA is
trimmed by design. It is not a fault.

### A second, separate bug this exposed: lazy unmount before imaging
The first post-fix boot STILL failed, with `libnvidia-ml.so.580.105.08` present
but **0 bytes** in the guest while the same file was 2.2 MB on the mounted
filesystem. Cause was in my test harness, not the script: teardown did
`umount -R ... || umount -l ...`, and the **lazy** fallback returns before the
flush completes. `losetup -d` + `qemu-img convert` then captured a pre-flush
filesystem. Always `sync` and use a real (non-lazy) unmount before imaging, and
verify the file inside the qcow2 rather than on the mount you just released.

## SSH access: openssh already ships in SteamOS

**`ssh: openssh already present in the image`** — SteamOS carries it (developer
mode uses it), so **the zero-added-packages property survives untouched**. Nothing
is installed for this feature on this image; the install branch exists only for
images that lack it.

Design: the operator drops a key at **`data/authorized_keys`** in the repo that is
9p-mounted. Its presence IS the switch — absent, sshd is not started; present, the
key is installed and sshd is enabled. No flag, no default to choose, and no state
in which sshd runs with credentials nobody picked.

`/etc/ssh/sshd_config.d/10-nvkvm.conf` sets:

    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin prohibit-password

`PasswordAuthentication no` is the load-bearing line and is set explicitly rather
than relying on "the deck user has no password": SteamOS prompts users to set one
when enabling developer mode or sudo, and the moment it exists password login
would go live with nothing in our design having changed.

Details that would otherwise fail silently, all handled:
- `~/.ssh` is `700`, `authorized_keys` `600`, both `chown`ed to the target user,
  and the home directory has `go-w` removed — sshd ignores keys with loose
  permissions and says nothing useful client-side.
- Key goes on the interactive user (`deck`, falling back to `user`), never root.
  Root access is a separate deliberate file, `data/root_authorized_keys`.
- Host keys generated with `ssh-keygen -A` **only if missing**, so the guest does
  not present a new host key every boot.
- `data/authorized_keys` and `data/root_authorized_keys` are gitignored, because
  nvkvm-pv is a PUBLIC repo.

**Reachability:** the guest is behind slirp NAT, so it is reachable only once QEMU
also has a hostfwd, e.g. `-netdev user,id=net0,hostfwd=tcp::15022-:22`. Turning
the feature on does not by itself expose anything.

Verified end to end:

    ssh -i <key> -p 15022 deck@127.0.0.1 'nvidia-smi --query-gpu=name,driver_version --format=csv,noheader'
      -> NVIDIA GeForce RTX 3090, 580.105.08

    (password auth) -> deck@127.0.0.1: Permission denied (publickey).

The key used for this test is a **throwaway** generated for the test box; its
private half never left the local machine.
