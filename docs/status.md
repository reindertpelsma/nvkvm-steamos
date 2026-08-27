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

### UNRESOLVED: Steam wipes its own install inside the guest (2026-08-27/28)

The owner lost a Steam login and a 40 GB game install.  Steam re-bootstraps
("unpacking Steam") on every launch and requires a fresh login each time.

**The decisive observation, from the owner:** open Steam, log in, quit it
*gracefully* from the tray, relaunch — and it is wiped again, **within a single
boot, with no reboot involved.**  That eliminates the VM lifecycle, the shutdown
path and anything this repo does at boot.

**Steam's own log shows it starts with genuinely empty state**, not corrupt
state:

```
[2026-08-27 15:04:08] Client beta changed from '' to 'steamdeck_stable'
[2026-08-27 15:04:08] Failed to load cached hosts file (update_hosts_cached.vdf not found)
```

Consequence chain: no config -> logged out -> re-bootstrap -> no
libraryfolders.vdf -> Steam does not know the game is installed -> offers a
re-install.  Games are account-licensed but disk-resident, so a re-login must
never uninstall anything; that it appears to is a symptom of the lost library
index, not of deletion.

**Ruled out, each by measurement, not argument:**
- `/etc/machine-id` is stable across boots (read-only, unchanged since Aug 26).
- Clock is correct and NTP-synchronised; no skew, no backwards jumps.
- Filesystem loss: boot -4 (the session with the game) **ended cleanly** --
  systemd unmounted in order and flushed the journal.  `lost+found` is empty.
- Disk integrity: `qemu-img info` reports no backing file, no snapshots,
  `corrupt: false`; 61.1 GiB genuinely allocated, so the game *was* written.
- This repo's scripts: the only `rm -rf` calls are scoped to `/usr/lib` and
  `/usr/lib/firmware/nvidia`; `/home/.nvkvm-build.img` is a 1 GB scratch FILE
  that gets mkfs'd, never the partition.  Nothing here writes to `/home/deck`
  except the `.ssh` authorized_keys installer.
- `steamapps/common/FAKEGAME/blob` (64 MB) survived two reboots, so nothing is
  deleting indiscriminately.

**Two hypotheses raised and RETRACTED, recorded so they are not re-derived:**
1. *Unclean-shutdown data loss.*  Wrong.  ext4 commits its journal every 5 s and
   `data=ordered` writes data first; QEMU's default writeback cache honours
   guest flushes, and killing QEMU on a live host does not lose committed
   writes -- the host page cache survives the process.  Only host power loss
   would, and the host never went down.
2. *A marker-file "reproduction".*  Wrong, and a bad experiment: the markers
   were written as **root** into Steam's own tree.  Steam legitimately cleans
   foreign files out of its directory during bootstrap.  `deck`-owned markers
   survived untouched.  Any future test MUST create files as the `deck` user.

**Dead end for tooling:** the neptune kernel is built without `CONFIG_AUDIT`.
`audit=1` reaches `/proc/cmdline` and `auditctl` still reports "audit support
not in kernel", so syscall auditing cannot be used to name the deleter here.
(systemd's `+AUDIT` means systemd links libaudit -- it says nothing about the
kernel.)

**Where to resume:** `~/.local/share/Steam/logs/` now exists and is populated.
Read `bootstrap_log.txt` and `console-linux.txt` across one exit-and-relaunch
cycle.  That needs no reboots, no markers and no kernel features this image
lacks, and it should name whatever resets the install.

Evidence bundle: `evidence-steam-wipe-20260828/` (guest boot table, boot -4
tail proving the clean shutdown, Steam bootstrap log, and the DRM
`enabled=disabled` capture).

### The guest DRM output can come up `enabled=disabled` (2026-08-27)

One boot in six came up with `card0-Virtual-1: status=connected enabled=disabled`
and **zero flips** -- KWin logged `There are no outputs - creating placeholder
screen` across every KDE component, so the session had no output to draw on.

NOT a startup race in the obvious direction: the broker logged `client attached`
at 20:41:48.56 UTC and KWin reported no outputs at 20:42:37 -- **49 seconds
later**.  The display was present and the guest still saw nothing.  Root cause
unknown.  A VM restart clears it; a fresh boot 16 s later had the output
`enabled` with flips flowing.  Capture in `evidence-steam-wipe-20260828/drm-disabled/`.

### Chromium GPU watchdogs kill processes when forwarding is slow (2026-08-27)

Planetary Annihilation Titans crashed after ~20 minutes.  The crash is NOT a
memory bug -- frame #0 of the core is:

```
content::GpuWatchdogThread::DeliberatelyTerminateToRecoverFromHang
```

That is Chromium killing its own GPU process on purpose because the GPU thread
stopped responding inside the watchdog interval (~10-15s).  The dead process was
`CoherentUI_Host --type=gpu-process`, which `nvidia-smi` had listed holding
1473 MiB -- PA's browser-based UI layer, not its renderer.  The game's own `PA`
process (735 MiB) was healthy.

**This is a class, not a title.**  Coherent UI, CEF, Electron and the Steam
overlay all ship the same watchdog.  Anything that makes a GPU operation exceed
the interval turns into a *crash* rather than a stall, and the crash signature
points at the application, not at us.  Expect it whenever forwarding latency
spikes.

Correlated in the same window, causality NOT established: the broker logged
`frame: REUSE-IN-FLIGHT ... the compositor never released it` at 19:33:21 UTC
and the watchdog fired at 19:35:13 UTC -- 112s later, far longer than a
watchdog interval, so the buffer event is not the trigger.  Both are consistent
with the HOST compositor stalling the present path.

Not investigated: which forwarded operation is slow.  The guest also logged
449,990 `signal interrupted forwarded ioctl wait` events against Xwayland
(pid 1811) -- that path is handled correctly and returns the real response
rather than -ERESTARTSYS (`src/guest/nvkvm_virtio.c:630-646`), so it is volume,
not error.  Whether that volume costs latency is unmeasured.

### spice-vdagent segfaults repeatedly (2026-08-27)

Three SIGSEGV core dumps in one session (10:52, 11:10, 11:11 PDT), all
`/usr/bin/spice-vdagent`, ~520-544 KiB each.  This is the clipboard agent the
image installs, so it is ours to explain.  The broker still reports "clipboard
agent present", so it restarts.  Not diagnosed.

### The guest cannot be shut down from outside (measured 2026-08-27)

`system_powerdown` over QMP does **not** power the guest off, and never did.
What it used to do was worse: the guest entered S3 and became unwakeable from
the UI.  `query-status` returned `{"status": "suspended", "running": false}`
with vCPU time frozen (15276 -> 15276 over 5s), sshd stopped answering, the
serial console went silent and QEMU never exited.  A suspended VM is
indistinguishable from a hung one, which is how it was reported at the time.
`system_wakeup` over QMP recovers it fully -- SSH, presentation and even a
resolution renegotiation to 3672x2070 all survived the round trip.

The suspend half is **fixed**: `steamos_boot.sh` now masks `sleep.target`,
`suspend.target`, `hibernate.target` and `hybrid-sleep.target`, so the same
event leaves the guest running.  Verified on the physical PC.

The poweroff half is **still open**.  The chain is logind
`HandlePowerKey=ignore` -> PowerDevil holds a *block* inhibitor on
`handle-power-key` ("KDE handles power events") -> its default action is sleep.
Appending `powerButtonAction=4` under `[AC][HandleButtonEvents]` and restarting
PowerDevil did **not** change the outcome (no serial output, guest stayed up),
so the enum value is either wrong or PowerDevil is not acting on the ACPI event
at all.  Not chased further.

Consequence: `docker compose down` stops QEMU with SIGTERM while the guest is
still running, so guest writes are not flushed.  That is the documented cause
of files coming back **0-length with their mtime intact** -- and systemd
reports a 0-byte unit as "masked", which reads like a deliberate mask and is
not.

Suggested fix, not yet implemented: have the vmm entrypoint trap SIGTERM and
run `systemctl poweroff` in the guest over the container-managed SSH key
(`nvkvm-steamos-ssh` already has it) before letting QEMU exit.  That bypasses
the desktop's power handling entirely rather than negotiating with it.

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
