# Provisioning a SteamOS image by hand

This is the long-hand version of README [step 1–2](../README.md#start-here-image-to-running-guest)
and TUTORIAL [steps 4–5](../TUTORIAL.md#step-4--grow-the-image-and-repair-the-gpt):
take a pristine SteamOS recovery image and turn it into a provisioned,
nvkvm-ready guest disk, entirely offline — no guest boot required.

**If you just want the image, run the script instead:**

```sh
sudo ./build_steamos_image.sh \
  --src  steamdeck-oobe-repair-20260707.10-3.8.14.img \
  --share ~/nvkvm/nvkvm-pv
```

[`build_steamos_image.sh`](../build_steamos_image.sh) is this document, mechanised —
same steps, same order, plus the cleanup and the pre-flight checks that are easy
to forget by hand. Read *this* document when the script fails, when you want to
do something it does not do, or when you want to understand what it is doing to
your filesystem. **Every step below says why it exists**; a reader who
understands them can debug a failure, one who copies them cannot.

---

## 0. What you need first

| | |
|---|---|
| **A SteamOS recovery image** | see below |
| **An `nvkvm-pv` checkout** | **not this repo.** The guest module is built from `<share>/src/guest`; a share pointed at `nvkvm-steamos` fails with `nvkvm guest source not found`. |
| **The NVIDIA driver loaded on the host** | `/proc/driver/nvidia/version` must be readable. The image is pinned to *this host's* driver version. |
| **root** | losetup, mount, chroot |
| **Host tools** | `losetup`, `sgdisk` (gptfdisk), `btrfs` (btrfs-progs), `blkid`, `findmnt`, `chroot`, `modinfo` (kmod), `mkfs.ext4`, `qemu-img` |

### Getting the image

Everything in this repository was measured against **SteamOS 3.8.14**, the OOBE
recovery image dated 2026-07-07:

```sh
curl -O https://steamdeck-images.steamos.cloud/recovery/steamdeck-oobe-repair-20260707.10-3.8.14.img.bz2
# 3,357,999,306 bytes compressed; check it before you spend an hour on a bad copy
ls -l steamdeck-oobe-repair-20260707.10-3.8.14.img.bz2
bunzip2 -k steamdeck-oobe-repair-20260707.10-3.8.14.img.bz2
```

That URL is a **pin, not the only option** — Valve publishes newer recovery
images under the same `recovery/` prefix, and Valve's own
[Steam Deck Recovery Instructions](https://help.steampowered.com/en/faqs/view/65B4-2AA3-5F37-4227#install)
page always links the current one. A newer image is often *better*: provisioning
refuses, correctly, if Valve's package pool no longer carries kernel headers for
the exact kernel in your image, and that is the single most common reason to
need a fresher one. Note the version you used — results are not comparable
across SteamOS versions.

**Never provision the downloaded image itself.** It is the input, it is a 3.4 GB
download, and you will want to start over at least once.

### A note on the host's NVIDIA driver

`steamos_boot.sh` reads the *host's* driver version out of
`/proc/driver/nvidia/version` and installs the matching NVIDIA userspace into
the image. If it cannot read that file it prints a warning, **skips the NVIDIA
install entirely, and still reports `rc=0`** — leaving you with a finished-looking
image that has no driver in it. Check before you start:

```sh
cat /proc/driver/nvidia/version
```

---

## 1. Copy the image

```sh
cp --reflink=auto --sparse=always steamdeck-oobe-repair-20260707.10-3.8.14.img work.img
```

Not a rename, not "just be careful". Provisioning writes ~2 GB into the rootfs,
chroots into it and runs `pacman` and `nvidia-installer` inside it; there is no
undo. `--reflink=auto` makes this instant on btrfs/XFS and falls back to a real
copy elsewhere.

## 2. Grow the disk

```sh
truncate -s +60G work.img
```

**What this actually buys you, which is not what the README implies.** The
recovery image's btrfs **rootfs is ~5 GB and this does not grow it** — the
rootfs is partition 3, and only the *last* partition can absorb space appended
to the end of a disk. What grows is `/home` (the last partition), and it grows
by itself: this SteamOS image ships a boot-time grow-last-partition unit, so on
the guest's first boot partition 5 expands to fill the new space with no action
from you. Measured: `/home` went from 2.0 G / 100 % used to **61 G with 60 G
free**, and `resize2fs` reported there was nothing left to do.

That is worth doing because `/home` is where Steam's library, its runtime and
every game live — without it Steam cannot even bootstrap. It does **not**
relieve the rootfs pressure during provisioning; see
[Space traps](#space-traps-the-three-that-actually-bite) for what does.

`truncate` writes a hole, so the file does not consume 60 GB today. It will as
the guest fills it.

## 3. Attach a loop device — and note which one you got

```sh
sudo losetup -Pf --show work.img          # prints e.g. /dev/loop3
```

`-P` tells the kernel to scan the partition table and create `/dev/loopNp1…`;
`-f --show` picks the first free device *and prints it*. **Use what it printed.**
Loop devices come from a global kernel pool shared with everything else on the
machine — `/dev/loop0` is very often somebody else's snap package. Hardcoding a
number is how people end up detaching a device they do not own, or leaving their
own attached to a file they have since deleted.

If you lose track:

```sh
losetup -j work.img          # which loop device is bound to this file
losetup -l                   # everything, including entries marked (deleted)
```

## 4. Relocate the backup GPT header

```sh
sudo sgdisk -e /dev/loop3                 # -> "The operation has completed successfully"
```

A GPT keeps a **backup header in the last sector of the disk**. Growing the file
moved the last sector; the backup is still sitting where the old end used to be,
and the table now reads as damaged.

**Linux does not care.** `lsblk` works, `mount` works, provisioning works — which
is exactly why this is easy to skip. **OVMF does care**, and it fails by finding
*no bootable device*, with nothing on any console mentioning the GPT. That
symptom sends you hunting through QEMU flags for an hour. `sgdisk -e` moves the
backup header to the real end of the disk.

Two hard-won details:

- **Run it on a loop device over the raw `.img`, never over `qemu-nbd`.** Against
  `/dev/nbd0` sgdisk fails with `Read error 5`, reports zero partitions, and its
  write silently does nothing.
- Do it **now**, before converting to qcow2. The working order is
  `cp → truncate → losetup -P → sgdisk -e → provision → losetup -d → qemu-img convert`.

## 5. Find the rootfs partition — do not hardcode it

```sh
lsblk -o NAME,PARTLABEL,FSTYPE,SIZE /dev/loop3
# or, per partition:
blkid -p -s PART_ENTRY_NAME -o value /dev/loop3p3
```

On the `steamdeck-oobe-repair` image the layout is
`1=esp 2=efi-A 3=rootfs-A (btrfs) 4=var-A (ext4) 5=home (ext4)`, so the rootfs is
`p3`. **Do not carry that number anywhere.** A real installed SteamOS has both
A/B slots (`rootfs-A` *and* `rootfs-B`, different numbers), Valve has changed the
layout between releases, and the older
[`build_nvkvm_steamos_image.sh`](../build_nvkvm_steamos_image.sh) hardcodes `p3`
and says so in a comment for exactly this reason.

Identify it by what the image itself declares:

- **the GPT partition name** — `rootfs-A` (or `rootfs-B` for the other slot), or
- **the only btrfs partition** on the disk. SteamOS's rootfs is btrfs; `var` and
  `home` are ext4.

Note the `home` partition number too — you need it in step 7.

## 6. Mount the rootfs, and make it writable

```sh
sudo mkdir -p /mnt/steamos
sudo mount /dev/loop3p3 /mnt/steamos
sudo btrfs property set /mnt/steamos ro false
```

**SteamOS ships an immutable rootfs.** That is not a mount option you can
override with `-o rw`: the btrfs *subvolume* carries the `ro` property, so every
write returns EROFS however you mounted the block device. `btrfs property set
… ro false` clears it. (On a live SteamOS the same thing is spelled
`steamos-readonly disable`.)

**Doing it here, rather than letting the script do it, is a deliberate choice
about the finished image.** `steamos_boot.sh` clears the property itself
whenever it needs to write — but it also *records what it found on entry* and
restores that on exit. So:

- clear it first (as above) → the script sees `rw`, leaves it `rw`, and the
  finished image ships with a writable rootfs. This is what the documented path
  produces.
- leave it set → the script sees `ro`, unlocks per operation, and **re-locks it
  at exit**, giving you an image whose rootfs is immutable again.

Either boots. The first is friendlier to poke at; the second is closer to stock
SteamOS.

Sanity-check you mounted the right thing before going further:

```sh
ls /mnt/steamos/usr/lib/modules /mnt/steamos/etc/pacman.conf
```

## 7. Mount the image's `/home` as well

```sh
sudo mount /dev/loop3p5 /mnt/steamos/home
```

**This step is missing from the README and TUTORIAL, and it matters.**
`steamos_boot.sh` builds the guest module in a 1 GB ext4 loopback image at
`/home/.nvkvm-build.img` *inside the target root*, and caches the ~380 MB NVIDIA
`.run` under `/home/deck/.local/share/nvkvm/`. With only the rootfs mounted,
both of those land on the ~5 GB btrfs rootfs — the one partition that has no
room — and the `.run` cache stays there permanently, in the finished image.

(Why a loopback image and not a plain directory: SteamOS's `/home` is ext4 with
the `casefold` feature, and a casefolded directory breaks kernel builds. The
ext4 image gives the build a normal filesystem.)

If your image's `/home` is a symlink, follow it and mount at the target.

## 8. Give the chroot `/proc`, `/sys` and `/dev`

```sh
sudo mount --bind /proc /mnt/steamos/proc
sudo mount --bind /sys  /mnt/steamos/sys
sudo mount --rbind /dev /mnt/steamos/dev
```

**Also missing from the README and TUTORIAL.** `steamos_boot.sh` chroots into
the target for `pacman`, `curl`, `nvidia-installer`, `ldconfig` and `depmod`,
but it does not set up the kernel filesystems itself — it assumes its caller
did. Both of its other callers do:
[`nvkvm-recovery.sh plant`](../boot/image/nvkvm-recovery.sh) binds all three
before running `--install-only --root`, and so does the older image builder.
`nvidia-installer` in particular is unhappy without them.

## 9. Give the chroot a resolver

```sh
cat /mnt/steamos/etc/resolv.conf          # is there anything usable in there?
```

The build runs `pacman` and `curl` **inside** the chroot, against Valve's
mirror. A root with no working `/etc/resolv.conf` fails with
`Could not resolve host` / `could not install core build tools`, and Part 1 ends
`rc=1`. This is the single most common failure.

Prefer a bind mount over a copy, so the host's DNS configuration is not baked
into the image you ship:

```sh
sudo mount --bind /etc/resolv.conf /mnt/steamos/etc/resolv.conf
```

If `/etc/resolv.conf` in the image is a dangling symlink (SteamOS points it at
`systemd-resolved`'s stub), create the *link target* inside the image first,
bind onto that, and delete it again before you unmount.

## 10. Stand in for the 9p share

```sh
sudo mkdir -p /run/nvkvm
sudo mount --bind /path/to/nvkvm-pv /run/nvkvm
sudo mount -o remount,bind,ro /run/nvkvm
```

**What the real boot path does instead.** At runtime the guest gets the
`nvkvm-pv` checkout over **9p from QEMU** —
`-virtfs local,path=<nvkvm-pv>,mount_tag=nvkvm,security_model=none,readonly=on`
(see [`boot/run_steamos_nvkvm.sh`](../boot/run_steamos_nvkvm.sh)) — and
`steamos_boot.sh` mounts it itself with
`mount -t 9p -o trans=virtio,version=9p2000.L,ro,msize=512000 nvkvm /run/nvkvm`.
Offline there is no QEMU and no virtio transport, so a **bind mount puts the
same directory at the same path**. `mount_9p_share()` returns success early if
`/run/nvkvm` is already a mountpoint, which is precisely what makes the
substitution work.

Three things that are load-bearing:

- **It must be a real mount, not a symlink and not a copied directory.** The
  check is `mountpoint -q /run/nvkvm`. Anything that is not a mountpoint falls
  through to the 9p mount, which fails, and Part 1 aborts on its first step.
- **It must be `nvkvm-pv`**, the repo whose `src/guest` holds the guest module —
  not `nvkvm-steamos`. This repo's `boot/` is a published *copy* of nvkvm-pv's,
  so it looks right and is not.
- **`/run/nvkvm`, not `/mnt/nvkvm`.** In SteamOS `/mnt` is a symlink to
  `var/mnt`, and `/var` is a rauc-managed partition that Valve's own
  `post-install.sh` **reformats on every OS update**. `/run` is tmpfs, always
  writable, exists before anything is mounted, and never survives a boot.

Mount it read-only for the same reason the real share is read-only: nothing in
the build may write into your `nvkvm-pv` checkout.

Optional, and worth it — drop an SSH public key into the share *before* you
provision. Its presence **is** the switch; absent, sshd is never started:

```sh
cp ~/.ssh/id_ed25519.pub /path/to/nvkvm-pv/data/authorized_keys
```

## 11. Provision

```sh
sudo /path/to/nvkvm-pv/boot/steamos_boot.sh --install-only --root /mnt/steamos
```

`--install-only` is Part 1: it touches **no running-kernel state** — no
`modprobe`, no `rmmod`, no validation against the host's dmesg — which is what
makes it safe to run against a root that is not the one you booted. In one
command it:

1. builds `nvkvm-guest.ko` against **the image's own kernel** (headers fetched
   from Valve's pool, pinned to the exact version — see below);
2. installs the NVIDIA userspace matching **your host's** driver, via NVIDIA's
   own `nvidia-installer --no-kernel-modules`;
3. writes the desktop configuration (`privileged_modeset=0`, the DRM-node
   resolver unit, `KWIN_FORCE_SW_CURSOR=1`);
4. plants the four systemd units that make the guest self-provisioning from then
   on — they are not in the image until something puts them there.

A healthy run ends with:

```
[nvkvm] === Part 1 finished (rc=0) ===
```

**If it says `rc=1`, read the log rather than continuing.** It names what failed:

| symptom | cause |
|---|---|
| `could not install core build tools`, `Could not resolve host` | step 9 — no resolver in the chroot |
| version-pin error on `linux-neptune-*-headers` | Valve's pool no longer carries headers for this image's exact kernel. **This is correct behaviour**, not a bug: building against a newer neptune point release silently produces a module that loads nowhere. Use a newer recovery image. |
| `nvkvm guest source not found` | step 10 — the bind mount points at the wrong repo |
| `free=634M vs needed=768M` | out of rootfs space; see below |
| finishes `rc=0` but no NVIDIA libraries in the image | step 0 — the host driver was not loaded, and this only *warns* |

## 12. Verify before you unmount

`rc=0` is necessary, not sufficient. Check the things that have actually been
wrong before:

```sh
KVER=$(basename "$(ls -d /mnt/steamos/usr/lib/modules/*/vmlinuz | head -1 | xargs dirname)")
ls -l /mnt/steamos/usr/lib/modules/$KVER/updates/nvkvm-guest.ko      # exists, non-zero
ls -l /mnt/steamos/usr/lib/libnvidia-glcore.so.*                     # matches your host driver
ls -l /mnt/steamos/usr/lib/libnvidia-{glsi,tls}.so.* /mnt/steamos/usr/lib/libGLX_nvidia.so.*
find /mnt/steamos/usr/lib -maxdepth 1 -name 'libnvidia-*.so.*' -size 0   # must print NOTHING
ls /mnt/steamos/etc/systemd/system/nvkvm-boot.service \
   /mnt/steamos/etc/systemd/system/nvkvm-plant-stub.{path,service} \
   /mnt/steamos/usr/local/sbin/nvkvm-recovery.sh
```

The zero-length check is not paranoia — see step 13.

## 13. Flush, and unmount **for real**

```sh
sudo sync
sudo umount -R /mnt/steamos       # a real unmount. NEVER umount -l here.
sudo umount /run/nvkvm
sudo losetup -d /dev/loop3
```

**Why `sync` first.** Everything written by provisioning is still in the page
cache. The next thing you do reads the *backing file* — `qemu-img convert` opens
`work.img`, not the mount — so anything not yet written back is simply not in the
output.

**Why `-R` and never `-l`.** `-R` unmounts the whole tree beneath
`/mnt/steamos`, which by now is five or six deep (`/proc`, `/sys`, `/dev`, the
resolver bind, `/home`, plus anything `steamos_boot.sh` left behind — it
bind-mounts the extracted NVIDIA payload at `/tmp/nvidia-install` and mounts a
loopback build area under `/home`). A plain `umount /mnt/steamos` just says
`target is busy`.

`umount -l` (lazy) makes that error go away, and it is the worst thing you can do
here. **A lazy unmount detaches the tree from the namespace and returns
immediately, while writeback is still in flight.** It reports success on a
filesystem that is not yet consistent on disk. This was measured on this project:
teardown fell back to `umount -l`, `qemu-img convert` ran straight afterwards,
and the resulting qcow2 contained a **0-byte `libnvidia-ml.so`** while the very
same file was 2.2 MB on the mount that had just been "released". It presented as
an NVIDIA driver bug and cost hours.

So: if `umount -R` says busy, **find what is holding it** —

```sh
findmnt -R /mnt/steamos
fuser -vm /mnt/steamos
```

— and fix that. Never reach for `-l` to make the message go away. If you cannot
release it, the image is not safe to convert; start the run again.

## 14. Convert

```sh
qemu-img convert -f raw -O qcow2 work.img steamos-nvkvm.qcow2
qemu-img check steamos-nvkvm.qcow2
```

`-f raw` is explicit on purpose — never let `qemu-img` probe the format of a disk
image you just wrote.

## 15. Boot it

```sh
QCOW=/path/to/steamos-nvkvm.qcow2 \
SHARE=/path/to/nvkvm-pv \
QEMU=/opt/qemu-nvkvm/bin/qemu-system-x86_64 \
  boot/run_steamos_nvkvm.sh
```

`SHARE` is the same `nvkvm-pv` checkout you bind-mounted in step 10 — this time
it really is exported over 9p. See the README for what a healthy first boot
prints, on the host and in the guest.

---

## Space traps: the three that actually bite

The 5 GB rootfs is the constraint in this whole procedure, and the +60 G from
step 2 does not touch it. Three separate things compete for it:

1. **The extracted NVIDIA payload lands next to your mount point, on the
   host.** `install_nvidia_userspace()` extracts the `.run` to
   `$(dirname "$(readlink -f "$ROOT")")/nvkvm-nvidia-extract` — so with
   `--root /mnt/steamos` that is **`/mnt/nvkvm-nvidia-extract`**, about **1.4 GB**,
   on whatever filesystem `/mnt` lives on (usually `/`). Make sure there is room
   there, and do not put the mount point on a tmpfs — `/tmp/steamos` would put
   1.4 GB in RAM.
2. **The "diverted" bulk is written into the image anyway, offline.** To save
   space, provisioning tells `nvidia-installer` to send `FIRMWARE`, `CUDA_LIB`
   and `OPENCL_LIB` (~620 MB) to `/tmp/nvkvm-discard` *inside the target root*,
   then deletes them. On a **live** guest `/tmp` is tmpfs, so that costs no disk.
   **Offline, `/tmp` is a real directory on the 5 GB btrfs rootfs**, so the
   diversion writes every byte it was supposed to avoid writing, and needs the
   peak space anyway. Shadow it before provisioning if you are tight:
   ```sh
   sudo mount --bind /some/host/scratch /mnt/steamos/tmp
   ```
   (`/tmp` is a tmpfs at runtime, so nothing there is meant to survive.)
   `build_steamos_image.sh` does this by default.
3. **The pre-flight check only counts what it can see.** Provisioning stops
   cleanly at `free=634M vs needed=768M` (`steamos` profile) rather than dying
   half-installed — the earlier failure mode was `nvidia-installer` taking
   **SIGBUS** at 100 % full. If you hit it, `NVKVM_NO_COMPAT32=1` halves the
   requirement, at the cost of the 32-bit libraries Steam needs — Portal 2 is a
   32-bit Source title and uses them. The profile is deliberately **never**
   downgraded automatically on the basis of free space.

## Cleaning up after a failed run

An interrupted run leaves state in two places, and they behave differently:

```sh
findmnt -R /mnt/steamos                # mounts, innermost first
sudo umount -R /mnt/steamos            # not -l
sudo umount /run/nvkvm
losetup -j work.img                    # the loop device bound to your image
sudo losetup -d /dev/loopN
losetup -l | grep '(deleted)'          # loops pinned to files that no longer exist
```

The mounts you can always undo. The **loop device is global kernel state**: if
the run died before detaching it and you then deleted `work.img`, the device
stays attached to a file that no longer has a name, holding its space, and
`losetup -l` shows it as `(deleted)`.

This is exactly the cleanup `build_steamos_image.sh` does not need: it runs the
whole mount phase inside `unshare -m --propagation private`, so every mount dies
with the process even on `kill -9` — but it still detaches the loop device from
a `trap`, because **a mount namespace does not isolate loop devices**.

---

## Where this document disagrees with the README and TUTORIAL

Written down rather than quietly fixed, because the older text was right about
what was *run* and this is about what the code *does*:

1. **`/proc`, `/sys` and `/dev` are not bind-mounted** in either walkthrough
   (step 8 here). `steamos_boot.sh` chroots but does not mount them; its other
   two callers both do it for it.
2. **The `home` partition is not mounted** in either walkthrough (step 7 here),
   so the 1 GB build area and the `.run` cache land on the rootfs.
3. **`truncate -s +60G` is presented as fixing the rootfs**
   ("The repair image's rootfs is too small to hold a toolchain, kernel headers
   and the NVIDIA userspace at once" — README step 1). It does not: the rootfs
   is not the last partition on the disk and does not grow. What grows is
   `/home`, at the guest's first boot. `boot/TESTING.md`'s "disk space is no
   longer a hard blocker … because the documented path grows the image by 60 GB"
   inherits the same error; the rootfs pre-flight still guards a 5 GB partition.
4. **`btrfs property set … ro false` is not strictly required** — `steamos_boot.sh`
   unlocks per operation on its own. What the manual step actually decides is
   whether the finished image ships writable or immutable (step 6).
5. **The bare `sudo mount --bind … /run/nvkvm` leaves the share writable.** The
   real 9p share is exported `readonly=on`; the bind should be remounted `ro` to
   match (step 10).
6. **A `rc=0` with no NVIDIA driver installed is possible** when
   `/proc/driver/nvidia/version` is unreadable — worth checking before you
   start, since nothing downstream complains until the guest boots (step 0).
