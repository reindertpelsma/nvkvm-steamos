# Current status and open gaps

This page keeps the evidence-heavy material out of the README. It describes
what was measured, where it was measured, and what is still open.

## Proven on hardware

The main SteamOS desktop result was measured on 2026-08-23 on a physical
RTX 4070 workstation with host driver 595.84 and a SteamOS 3.8.14 guest. Raw
logs are in [`../evidence-pc-20260823/`](../evidence-pc-20260823/).

- SteamOS boots as an nvkvm guest and reaches Plasma.
- The whole Plasma desktop renders on the NVIDIA GPU with GL zero-copy.
- The decisive run used `-vga none`; there was no emulated VGA-class display
  device for the desktop to fall back to.
- `nvidia-smi` in the guest reports the host RTX 4070, and KWin, Xwayland,
  plasmashell, Steam, and steamwebhelper appear as GPU processes.
- Portal 2 launches and plays under the GTK display backend. It is a 32-bit
  Source title, so this also exercises the `lib32` NVIDIA userspace kept by the
  SteamOS profile.
- The boot script converges at every boot after one-time provisioning.

The two-container deployment was re-tested on 2026-08-25 on the same physical
RTX 4070 machine. See the amendment in [`../boot/TESTING.md`](../boot/TESTING.md).
That run proved the VMM/broker split, the broker reconnect path, and the
capability-restricted container policy.

## Image creation

There are two image paths:

| path | status |
|---|---|
| `install_steamos_vm.sh` | Preferred outside Docker. Boots a disposable Alpine VM and lets Valve's own installer create a real dual-slot A/B SteamOS install. Host root is not required; `/dev/kvm` is enough. See [`vm-installer.md`](vm-installer.md). |
| `build_steamos_image.sh` | Legacy/debugging path. Edits Valve's recovery image offline through loop devices and chroot. It requires root, and produces a recovery-image based result rather than a real A/B install. See [`manual-install.md`](manual-install.md). |

The VM installer was verified on 2026-08-24 with
`steamdeck-oobe-repair-20260707.10-3.8.14.img`. The good run produced
`rootfs-A`, `rootfs-B`, `efi-A`, `efi-B`, `var-A`, and `var-B`, then booted
unaided. Logs are in
[`../evidence-vm-install-20260824/`](../evidence-vm-install-20260824/).

The A/B image makes SteamOS update-hook testing possible. Actually driving a
SteamOS OTA update through the nvkvm hook is still future validation, not a
claim this repository currently makes.

## Display backends

Attribute each result to both the guest and the QEMU display backend. Mixing
those up caused several wrong conclusions during bring-up.

| backend | pointer lock | Linux guest | SteamOS guest |
|---|---|---|---|
| `sdl,gl=on` | works | renders; Minecraft playable at max settings | black window; cause unknown |
| `gtk,gl=on` | does not work on the tested Wayland host | renders | renders; Portal 2 launches and plays |

SDL is the backend with working pointer lock. The Minecraft result is from the
non-SteamOS Linux guest used during nvkvm bring-up, not from SteamOS.

GTK is the backend that renders SteamOS today. It can show the desktop and run
Portal 2, but it does not provide usable mouse-look: the pointer-lock
investigation measured zero `REL_X`/`REL_Y` events reaching the guest while the
pointer was grabbed.

The open display gap is therefore narrow but important: SteamOS needs SDL to
render, or GTK needs a usable pointer-lock path, before the SteamOS result is
fully playable for first-person games.

## Known open items

- SteamOS plus `sdl,gl=on` is a black window while the guest remains alive and
  QEMU reports presentation activity. The same nvkvm build renders the Linux
  guest under SDL, so this is guest/backend-specific rather than a blanket SDL
  or nvkvm failure.
- The SteamOS cursor is smooth because provisioning sets `KWIN_FORCE_SW_CURSOR=1`.
  The underlying nvkvm KMS gap is still the lack of a cursor plane.
- `NVKVM_PRESENT_MODE=readback` hung the guest at the GRUB handoff on an older
  host. Zero-copy is the useful path today, so this has not been root-caused.
- Some denied control commands are benign on a working system:
  `0x00730102` and `0x2080220b` appeared during successful runs.
- nvkvm-pv is not ready for untrusted tenants. The container split reduces the
  host desktop exposure of the SteamOS deployment, but it does not turn nvkvm
  into a hardened multi-tenant GPU product.

## Lessons kept from bring-up

Do not hand-pick NVIDIA userspace libraries. A hand-written list missed pieces
needed by GL/Vulkan and 32-bit Steam titles. Use NVIDIA's own installer in
userspace-only mode and then trim deliberately.

Mount where you can, install where you must. On ordinary guests, mounting the
host's driver libraries keeps them matched to the host automatically. SteamOS's
immutable rootfs makes that impractical, so this project installs the matching
userspace into the image and accepts that the result is tied to the host driver
version it was provisioned against.

For raw chronology, failed hypotheses, and rig-specific notes, keep using
[`../boot/TESTING.md`](../boot/TESTING.md) and
[`../NOTES.md`](../NOTES.md).
