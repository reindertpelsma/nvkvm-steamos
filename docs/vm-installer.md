# The VM installer — a real dual-slot SteamOS install, built unprivileged

`install_steamos_vm.sh` + `vm/guest-init.sh` replace the loop-device-and-chroot
approach of `build_steamos_image.sh` with a **disposable VM**. The host runs
`qemu` and nothing else; Valve's own installer does the install.

```
host (unprivileged):  qemu -kernel alpine-vmlinuz-virt -initrd combined.img
                           -drive repair.img (snapshot=on, never modified)
                           -device nvme,drive=target  ->  /dev/nvme0n1 in guest
guest (Alpine, in RAM):  mount repair rootfs -> chroot -> repair_device.sh all
                         [-> chroot -> steamos_boot.sh --install-only]
                         poweroff
```

## What this buys, in ascending order of importance

1. **The host script is unprivileged.** No `losetup`, no `mount`, no `chroot`,
   no mount namespace. The only privilege is read/write on `/dev/kvm`, which is
   a group membership. The entire class of failure `build_steamos_image.sh`
   works hard to *contain* — leaked loop devices, half-unmounted trees, an
   agent holding a mount open — is *deleted*.
2. **Valve's installer does the work.** We stop reimplementing (and drifting
   from) `casefold` / `-T huge` / `steamos-bootconf` / `steamcl-install` /
   `grub-mkimage`.
3. **The output is a real dual-slot A/B install** — `rootfs-A` *and* `rootfs-B`,
   `efi-A`/`efi-B`, `var-A`/`var-B`. `build_steamos_image.sh` modifies Valve's
   *recovery* image, which is A-slot only, so its output cannot take a SteamOS
   OTA update and the nvkvm update hook is untestable on it. This one is
   testable. That is the payoff.

It also makes modifying the repair image redundant: install to a fresh target,
then run `steamos_boot.sh --install-only` against the installed `rootfs-A`.

## Usage

```bash
# The install itself (this is the part that is verified end to end)
./install_steamos_vm.sh --repair steamdeck-repair-*.img --out steamos.qcow2

# Install + nvkvm provisioning in one go (needs an NVIDIA build host, see below)
./install_steamos_vm.sh --repair steamdeck-repair-*.img --out steamos.qcow2 \
    --stages repair,provision --share ~/src/nvkvm-pv

# Debugging: boot the guest to a busybox shell with everything attached
./install_steamos_vm.sh --repair ... --out scratch.qcow2 --shell
```

Host requirements: `qemu-system-x86_64`, `qemu-img`, `cpio`, `gzip`, `curl`,
`tar`, an **OVMF** firmware package, and `/dev/kvm`. No root.

## Verified output (2026-08-24, `steamdeck-repair-20250521.10-3.7.7.img`)

`repair_device.sh all` ran to `Reimaging complete.` headless, and the disk it
wrote is a genuine dual-slot install:

```
NAME   PARTLABEL FSTYPE  SIZE
p1     esp       vfat    256M
p2     efi-A     vfat     64M
p3     efi-B     vfat     64M
p4     rootfs-A  btrfs     5G     UUID 68dc5ad6-…   (randomised per slot)
p5     rootfs-B  btrfs     5G     UUID 006e4f1e-…
p6     var-A     ext4    256M
p7     var-B     ext4    256M
p8     home      ext4    100M     (systemd-repart grows it on first boot)
```

with `/esp/SteamOS/conf/A.conf` and `B.conf` written by `steamos-bootconf`,
`grub.cfg` per slot, `steamcl.efi` at `/esp/efi/steamos/`, and the
removable-path copy at `/esp/efi/boot/bootx64.efi`.

And it **boots**: handed to OVMF + NVMe with nothing else attached, the image
goes firmware → `steamcl.efi` → grub → the neptune kernel, switches the display
to 1280x800 and writes 100+ MB to the disk over the next few minutes (first-boot
`systemd-repart`/`growfs`/journal). The screen stays black throughout, which is
expected: SteamOS boots `quiet splash` with `fbcon=vc:4-6` and then wants a GPU
for its session, and this test VM has only an emulated VGA. Booting it *as an
nvkvm guest* is what `boot/run_steamos_nvkvm.sh` is for.

**This is the payoff**: `rootfs-B`/`efi-B`/`var-B` exist, so rauc's atomic A/B
semantics are present and the image can take a SteamOS OTA update. The nvkvm
update hook — which has never been exercised on any rig, because
`build_steamos_image.sh` output has no B slot to update into — now has a rig it
can be exercised on. (Satisfying the *precondition* is what is verified here;
actually driving `steamos-update` through the hook is the next exercise, not
this one.)

## How the guest is bootstrapped

* **Alpine netboot** `vmlinuz-virt` + `initramfs-virt` are standalone
  downloadable files. There is **no Alpine disk image to build or maintain**:
  the initramfs is already a complete busybox userspace in RAM, and that is all
  we need because all we ever do is chroot.
* **The script is delivered by appending a cpio to the initramfs.** The kernel
  unpacks *multiple concatenated cpio archives* into one rootfs — the same
  mechanism early microcode loading uses — so `cat initramfs-virt custom.cpio.gz
  > combined.img` is the whole trick. No 9p and no extra disk are needed just to
  read our own script. It is selected with `rdinit=/nvkvm/guest-init.sh`, so
  Alpine's own `/init` is left in place and simply never runs.
* **Kernel modules come from `modloop-virt`.** VERIFIED by unpacking
  `initramfs-virt`: it ships `virtio_blk`, `squashfs`, `loop`, `overlay`,
  `vfat`/`fat` and the NLS tables, but **not `nvme`, `btrfs` or `ext4`** — all
  three of which we need (`nvme` for the target device itself). `modloop-virt`
  is attached as a virtio-blk disk and mounted as `/lib/modules`; it *is* the
  module tree, `modules.dep` included, so ordinary `modprobe` and kernel
  autoload (`request_module()` from `mount -t btrfs`) both work. Do **not**
  hand-pick `.ko` files and `insmod` them: `btrfs` pulls `zstd_compress`,
  `lzo_compress`, `raid6_pq`, `xor`, `libcrc32c`, `insmod` resolves no
  dependencies, and the ordering would need re-deriving on every Alpine kernel
  bump.
* The kernel needs `btrfs` regardless of the chroot, because the SteamOS tools
  inside it call the host kernel's filesystem support.

## The seven things the guest has to get right

These are the *only* places the VM differs from a Steam Deck, and each one was
found the hard way:

1. **The target must be attached as NVMe.** `repair_device.sh:17` is a plain
   `DISK=/dev/nvme0n1` assignment, not env-overridable. `-device nvme` lands it
   at exactly that path with no ambiguity and no patching of Valve's script.
2. **`/dev/fd` must exist.** devtmpfs does not create it; udev/systemd normally
   does, and there is neither here. `steamos-chroot`'s
   `get_device_by_partlabel()` feeds `sfdisk` into a `while read` through a bash
   **process substitution**, and process substitution *is* `/dev/fd`. Without
   the symlink the run dies at "Finalizing install part A" with
   `/dev/fd/63: No such file or directory`.
3. **The guest must boot under UEFI (OVMF, not SeaBIOS).** `steamos-chroot`
   unconditionally does `mount --bind /sys/firmware/efi/efivars ...`, and that
   directory only exists when the kernel booted with EFI runtime services. It
   cannot be faked with a tmpfs over `/sys/firmware`, because `steamos-chroot`
   uses `mount --bind /sys`, which does not carry submounts.
4. **The chroot root must be the real block device**, not an overlayfs.
   `repair_device.sh` finds its own source with `findmnt -n -o source /` and
   `dd`s that device into the target; an overlay root reports `overlay` there
   and `imageroot` fails. Writability is bought instead with a tmpfs over
   `/tmp` (the repair rootfs is a read-only btrfs subvolume, `ro=true`, and
   `steamos-chroot` does `mktemp -d`) and by mounting the repair image's own
   `var-A` and `home` partitions.
5. **udev has to be running.** Alpine's initramfs has none (it uses
   mdev/nlplug-findfs) and devtmpfs alone populates neither `/run/udev` nor
   `/dev/disk/*`. MEASURED: without a udev database,
   `lsblk --pairs -o ...,PARTTYPE,PARTUUID,FSTYPE,...` returns those three
   fields **empty**; `steamcl-install`'s `find_esp()` then falls through to its
   loose "just match `/esp`" branch, leaves `$esp_partuuid` empty, and
   `need_new_efi_boot_entry` passes only two arguments to `check_boot_path` —
   which, under `set -eu`, dies as
   `steamcl-install: line 464: 3: unbound variable`. The fix is not to patch
   Valve's script but to give it the environment it expects: the repair image
   ships `udevadm` (`systemd-udevd` is a symlink to it), so the guest runs the
   real daemon inside the chroot. With it running, the same line prints
   `ESP vfat c12a7328-... PARTUUID=b8779ad6-...` and the step succeeds.
6. **Slot A has to be marked as the boot target afterwards.**
   `repair_device.sh` runs `steamos-bootconf create --image A|B`, which writes
   both slot configs with **every field zero**, `boot-requested-at` included.
   MEASURED: an install left in that state boots as far as OVMF handing control
   to `steamcl.efi` and then stops dead — the chainloader blanks the screen,
   spins on CPU, and issues *not one disk read*; grub is never reached. Setting
   `boot-requested-at` on slot A is the entire difference: with just that one
   field patched on the produced image, the guest immediately switched the
   display to 1280x800 and wrote 100+ MB, i.e. it booted. The guest therefore
   finishes the repair stage with
   `steamos-chroot … --partset A -- steamos-bootconf set-mode first-boot --image A`
   — Valve's own tool, in Valve's own chroot, with the same
   `--conf-dir`/`--efi-dir` `repair_device.sh` passes to `create`. On a Deck the
   reimage is followed by a reboot into an OOBE flow that presumably arranges
   this; headless, nothing does it for us.
7. **efivarfs has to be MOUNTED, not merely present.** With the directory
   there but nothing on it, the whole install runs to completion and *then*
   `steamcl-install`'s `efibootmgr` reports "EFI variables are not supported on
   this system" → "ESP: Failed to create boot entry 0000" → rc=1, after all the
   real work already succeeded. The NVRAM entry it writes lands in the
   throwaway OVMF vars file and is discarded with the VM; what actually makes
   the produced image bootable is the removable-path copy that
   `--force-extra-removable` puts at `/esp/efi/boot/bootx64.efi`.

## What does NOT need stubbing (measured, not assumed)

`repair_device.sh` is `set -eu` with a `trap err ERR`, and its
`cmd() { showcmd "$@"; "$@"; }` wrapper does not swallow return values — so any
failing step aborts the run. Three steps looked like they would:

| step | what actually happens in a VM |
|---|---|
| `jupiter-biosupdate` (staged unconditionally when `writeOS=1`) | reads `/sys/class/dmi/id/board_{vendor,name}`, finds no `Valve`/`Jupiter`/`Galileo`, and calls `finish 0 ... 'Skipping update due to unsupported hardware revision'`. **Exits 0.** |
| `jupiter-controller-update` | same DMI check → `info "Device does not look like a Steam Deck..."; exit 0`. **Exits 0.** |
| `sanitize_all` (the `all` target runs it first) | `nvme sanitize-log` returns `Invalid Field in Command (0x4002)` on QEMU's emulated NVMe → `get_sanitize_progress` returns 2 → the fallback `nvme format -n 1 -s 1 -r` runs and **succeeds**. |

So **no stub is needed for any of them**, and Valve's scripts run verbatim.

The one thing that *is* stubbed is `systemctl`. `prompt_reboot` ends with
`cmd systemctl poweroff` (or `reboot`), and there is no systemd in the chroot —
that would fail *after* all the real work was done, which is the worst kind of
failure to have to tell apart from a real one. The stub is a two-line script in
a tmpfs directory prepended to `PATH`; nothing on any image is patched.

Prompts are suppressed with `NOPROMPT=1` (the contract Valve's own
`factory_reimage.sh` uses). `REBOOTPROMPT` is deliberately left *unset*: it is
tested as a string, so `REBOOTPROMPT=0` would *force* the zenity prompt rather
than suppress it.

## The input image is never modified

The repair image is attached with QEMU's `snapshot=on`: the backing file is
opened read-only and every guest write lands in a throwaway overlay. That is
also what makes it safe to mount the repair rootfs read-write and to write into
its `/home` inside the guest.

## Sizing

Valve's layout is fixed: `esp` 256M, `efi-A`/`efi-B` 64M, `rootfs-A`/`rootfs-B`
5120M, `var-A`/`var-B` 256M, and a **100M `home` stub** — about 11 GiB in total,
regardless of `--size`. The stub is deliberate: SteamOS ships
`/usr/lib/repart.d/90-home.conf`, so `systemd-repart` grows the home *partition*
to fill the disk on first boot and `x-systemd.growfs` in `/etc/fstab` then grows
the ext4 onto it. So `--size` is purely the games budget, it costs nothing up
front (qcow2 is sparse), and nothing needs to grow the partition by hand the way
`build_steamos_image.sh --grow` does.

## Cost

**MEASURED: 64-90 seconds** end to end (2 vCPU, 4 GB, KVM, everything on one
SATA SSD; 64s when the repair image is warm in the host page cache, 90s cold) —
for a full dual-slot install, i.e. *faster* than the ~1m48s
`build_steamos_image.sh` takes for a single-slot in-place edit. Nearly all of it
is Valve's two 5 GiB `dd`s of the rootfs into slot A and slot B (~45s and ~22s
respectively; the second is faster because the source is in the host page cache
by then) plus two `btrfs check` passes. The output is ~10 GiB of allocated qcow2.

Runs 2-6 in `evidence-vm-install-20260824/` are the iterations to that point, in
case a future repair image regresses one of them; run 7 is the good one.

## The `provision` stage and driver-version handoff

`steamos_boot.sh --install-only --root DIR` is documented as safe inside a
chroot of a *different* image (it is exactly what the update hook does), so the
guest runs it **inside the repair chroot** — that is where bash, pacman, chroot
and a real userspace live; the Alpine side is busybox only and could not.
It gets: the installed `rootfs-A` mounted at `/run/nvkvm-target` (plus the
installed `/home`, which is where the 1 GB module build area and the `.run`
cache have to land — the 5 GiB rootfs has no room), the `nvkvm-pv` checkout over
read-only 9p at `/run/nvkvm` with the same tag the guest gets at runtime, QEMU
user-mode networking, and a resolver bound over both chroots' read-only
`/etc/resolv.conf`.

There is no NVIDIA kernel driver inside the disposable Alpine VM, so it cannot
discover the host version from its own procfs. `install_steamos_vm.sh` reads the
version supplied to the outer host/container through
`/proc/driver/nvidia/version` (or accepts `--driver-version VERSION`) and passes
that value on the kernel command line. `guest-init.sh` then supplies it to
`steamos_boot.sh --install-only --root ... --driver-version VERSION`.

No version is hardcoded. Provisioning fails before QEMU starts if neither an
explicit version nor a parseable procfs value is available, and
`steamos_boot.sh --install-only` likewise fails instead of producing a silently
driver-less image. Normal SteamOS boot and the A/B update path need no explicit
argument: after nvkvm is loaded, its procfs bridge exposes the running host
version.

The complete `repair,provision` path is verified on the physical RTX 4070 host,
including a genuine dual-slot image, first boot, module rebuild, matching
userspace, Plasma, Vulkan compute, and EGL pixel verification. `--shell`
remains the recovery tool: it boots the installer VM with the share, network,
and installed target attached and drops to a BusyBox prompt.
