# VM-installer bring-up — 2026-08-24

Serial logs from the six runs it took to get `repair_device.sh all` to complete
headless inside the disposable Alpine VM, against
`steamdeck-oobe-repair-20260707.10-3.8.14.img`. Host: 2 vCPU, 15 GB, KVM,
QEMU 10.2.1, OVMF (Debian `ovmf` package), Alpine netboot 3.24.1
(kernel 6.18.35-0-virt).

`run1` is not kept: it never reached the chroot. Alpine's `initramfs-virt` ships
`/bin/busybox` and a `/bin/sh` symlink and **no applet symlinks**, and its
busybox is not built with the standalone-shell feature, so `mount`, `sleep` and
`poweroff` did not exist as commands. Fixed with `busybox --install -s`.

| run | how far it got | what stopped it |
|---|---|---|
| 2 | partition table, all filesystems, both 5 GiB rootfs copies, both `btrfs check`s | `steamos-chroot: line 31: /dev/fd/63: No such file or directory` — devtmpfs has no `/dev/fd`, and `get_device_by_partlabel()` uses a bash process substitution |
| 3 | + `finalize_part A` and `B` (partsets, bootconf, grub-mkimage, update-grub) | `steamcl-install: line 464: 3: unbound variable` — no udev, so `lsblk` reported empty `PARTTYPE/PARTUUID/FSTYPE`, `find_esp()` left `$esp_partuuid` empty, and `check_boot_path` got two args instead of three |
| 4 | + `find_esp` now resolves fully (`ESP vfat c12a7328-… PARTUUID=b8779ad6-…`) after starting the repair image's own `systemd-udevd` in the chroot | `EFI variables are not supported on this system` → `ESP: Failed to create boot entry 0000` — efivarfs was not mounted |
| 5 | same | efivarfs mounted on the *guest's* `/sys`, which a plain `mount --bind /sys` into the chroot does not carry |
| 6 | **`Reimaging complete.` / `NVKVM-GUEST-RESULT: 0`, 85 s** — but the image it produced would not boot: OVMF handed control to `steamcl.efi`, which blanked the screen, span at ~85% CPU and issued **not one disk read** for 4 minutes | `steamos-bootconf create` leaves `boot-requested-at: 0` on both slots. Patching just that one field on the finished image by hand made the same image boot immediately (display switched to 1280x800, 100+ MB written) |
| 7 | **`Reimaging complete.` + `boot-requested-at: 20260824151744` + `NVKVM-GUEST-RESULT: 0`**, and the produced image boots unaided | — |

Things that were expected to need stubbing and did **not** (all visible in the
logs): `jupiter-biosupdate` and `jupiter-controller-update` both self-skip on
non-Valve DMI and exit 0; `sanitize_all` gets
`NVMe status: Invalid Field in Command (0x4002)` from `nvme sanitize-log` on
QEMU's emulated NVMe and falls through to `nvme format -n 1 -s 1 -r`, which
succeeds. The only stub is `systemctl` (see `[stub] systemctl reboot` at the end
of run 6).

Verified on the produced qcow2 afterwards: 8 partitions with the expected
partlabels, `rootfs-A` and `rootfs-B` carrying *different* btrfs UUIDs
(`btrfstune -f -u` did its job), `A.conf`/`B.conf` under `/esp/SteamOS/conf`,
and `steamcl.efi` both at `/esp/efi/steamos/` and at the removable path
`/esp/efi/boot/bootx64.efi`.
