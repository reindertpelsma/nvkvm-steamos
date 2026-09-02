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

## Windows titles through Proton

Every title in the section above is native Linux/Vulkan. Proton adds a
translation layer between the game and the driver, so it is worth recording
separately -- it was also, for a while, broken here without our noticing.

- **Red Dead Redemption 2** (MEASURED 2026-09-01, RTX 4070 / driver 595.84).
  D3D12 through vkd3d-proton. It failed at `ERR_GFX_INIT` until 2026-09-01,
  because `libcuda.so.1` was never staged on an Arch-family guest and the
  NVIDIA Vulkan ICD could not build a device; fixed in nvkvm-pv. After the fix:
  12 minutes of continuous gameplay, GPU 28-39%, VRAM ~5.07 GB, 49-65 W,
  2.2-2.7 GHz, 41 C, with the host reporting 38-39% and ~5.08 GB for the same
  GPU at the same moment.
- **Just Cause 2** (MEASURED 2026-09-02, RTX 3050 Laptop GPU / driver
  580.173.02, Proton 11.0). Launches and plays on a build made from nothing: a
  `docker system prune -a` plus `docker volume prune -a`, then
  `docker compose build` from `main` alone on this repo and on nvkvm-pv. The
  binary is PE32/i386, so this also exercises the 32-bit NVIDIA userspace --
  `/usr/lib32/libGLX_nvidia.so.580.173.02` and a 32-bit `libvulkan` are mapped
  into the running process. It reaches the driver through DXVK, not
  vkd3d-proton, which is why it survives the gap below.

### OPEN: RDR2 does not reproduce on a clean build -- `--profile steamos` trims libcuda

MEASURED 2026-09-02 on the same fresh guest that runs Just Cause 2, using
`tests/repro/vk_device_extensions.c` from nvkvm-pv, the acceptance test written
for this bug:

| requested device extensions | result |
|---|---|
| none | `VK_SUCCESS` |
| `VK_KHR_swapchain` | `VK_SUCCESS` |
| all seven ray-tracing extensions | `VK_ERROR_INITIALIZATION_FAILED` |
| each of the seven, individually | `VK_ERROR_INITIALIZATION_FAILED` |

That is the original RDR2 signature exactly, with both controls passing. The
guest has 44 NVIDIA libraries staged in `/usr/lib` but **no `libcuda.so` at
all**, and no `libnvidia-nvvm.so`.

The cause is a design decision that the RDR2 finding invalidated.
`boot/steamos_boot.sh` defaults to `PROFILE=steamos`, whose `TRIM_RE` discards
`libcuda|libcudadebugger|libnvidia-nvvm|libnvidia-opencl|libnvoptix|nvidia-cuda-mps|OpenCL`
-- upstream steamos-nvidia-installer's trim set, reused verbatim on the premise
that a gaming profile has no use for CUDA. That premise is wrong for D3D12:
NVIDIA's Vulkan ICD `dlopen`s `libcuda.so.1` while creating a device with any of
the ray-tracing extensions, so vkd3d-proton cannot expose DXR without it.
`tests/nvidia_userspace_completeness_test.sh` actively asserts that `libcuda` is
never a completeness sentinel, so the trim is locked in by the test suite too.

The RDR2 fix in nvkvm-pv (`scripts/stage_guest_libs.sh`, staging into `/usr/lib`
on Arch-family guests) is real, but it is a *different code path*: a SteamOS
guest is staged by `steamos_boot.sh`, which never consults it. The 2026-09-01
RDR2 run therefore happened on a guest that had `libcuda` present; a reader
building from `main` today with defaults will hit `ERR_GFX_INIT`.

Not yet fixed, and deliberately not patched blind: dropping `libcuda` from
`TRIM_RE` is a one-line change, but it costs image size, needs the assertion in
the completeness test relaxed, and must be re-measured against the repro above
before it is claimed to work.

Neither entry is a frame-rate claim: nothing here measures frame timing. For
RDR2 the low GPU utilisation alongside a smooth-looking frame rate suggests a
vsync cap rather than a GPU-bound scene. No GPU counters were recorded for the
Just Cause 2 run.

Anti-cheat titles are out of scope and are expected to stay that way.

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

### OPEN: the host driver must be a version NVIDIA actually publishes

MEASURED 2026-09-02. The guest provisions its NVIDIA userspace by downloading
the official runfile matching the *host* driver version -- that is what keeps
guest and host in lockstep across host driver updates. If the host runs a
version NVIDIA never published as a runfile, there is nothing to download and
provisioning fails:

```
[nvkvm] ERROR: could not obtain the NVIDIA .run for 575.51.03
[nvkvm] === Part 1 finished (rc=1) ===
NVKVM-GUEST-RESULT: 1
```

This is not an exotic configuration. The host had its driver from **NVIDIA's
own CUDA apt repo** (`developer.download.nvidia.com/compute/cuda/repos/...`),
which is the path NVIDIA's own container-toolkit instructions lead you down --
and several driver builds published there have no corresponding runfile:

| version | source | runfile on us.download.nvidia.com |
|---|---|---|
| 575.51.03 | CUDA apt repo (installed here) | **404** |
| 570.133.20 | CUDA apt repo | **404** |
| 570.124.06 | CUDA apt repo | **404** |
| 575.57.08 | CUDA apt repo | 200 |
| 580.82.09 / 580.65.06 / 580.95.05 | runfile only | 200 |

So "install the NVIDIA driver the way NVIDIA documents it" can land a host on a
version the guest cannot follow. Upgrading within the same repo (575.51.03 ->
575.57.08) was enough to fix it here, which is the cheapest workaround: pick a
packaged version that also ships a runfile.

Everything else in provisioning had already succeeded: the pacman keyring was
trusted in the target, the guest module built, the OTA hook was installed and
the in-image stub verified byte-for-byte. Only the download failed. The failure
is at least loud and specific rather than silent.

Workarounds, in order of preference:

1. Pick a host driver version that ships both ways -- e.g. 575.57.08 rather
   than 575.51.03, both of which are in NVIDIA's CUDA apt repo.
2. Supply the runfile yourself: `--old-run-file DIR` takes a bind-mounted cache
   directory of NVIDIA `.run` files, which is also the offline install path.

Worth improving: falling back to the nearest published version in the same
branch would be wrong (guest and host userspace must match exactly), so the
honest options are to fail as it does now or to document the cache path more
prominently. It currently fails after several minutes of successful work, which
is a poor place to discover the problem -- checking that the runfile is
obtainable *before* provisioning starts would turn minutes into seconds.

### RESOLVED: Steam wiped its own install inside the guest (2026-08-27/28)

**Root cause: Valve's own `steam-jupiter-oobe` package, not nvkvm and not the
VM.**  On OOBE recovery images `/usr/bin/steam-jupiter` is a wrapper that opens
with

```bash
( # On OOBE images we want to always start with a fresh steam per boot as we
  # lack the proper steam overlay/repair code
  rm -rf --one-file-system "$STEAM_LINKS" "$STEAM_DIR" )
exec /usr/lib/steam/steam -steamdeck -skipinitialbootstrap "$@"
```

Every launch deleted the library before Steam started.  This is deliberate
Valve behaviour for factory/out-of-box images, and it is why the owner lost a
login and a 40 GB install.  It is not documented on the download page, and the
default download button offers exactly this image.

**Fixes, in order of preference (both shipped):**
1. Install the **plain (non-OOBE) repair image**.  `steamos-container-entrypoint.sh`
   resolves it through Valve's stable `steamdeck-repair-latest` alias, sorting
   on the VERSION field rather than the filename, with a pinned fallback.
2. If an OOBE image is used anyway, `steamos_boot.sh` comments out that single
   `rm -rf` and leaves a marker in the file, then lets Valve's own OOBE setup
   flow run instead of hijacking the session with an SDDM override.

**Verified on the physical PC, 2026-08-28** (RTX 4070, driver 595.84): log into
Steam, quit gracefully via "Exit Steam" from the tray icon, relaunch.  The
install survives -- 2.5 GB under `~/.local/share/Steam` with
`config/loginusers.vdf` intact, where before it was recreated empty.  The
guest's live wrapper carries the guard and contains zero unguarded
`rm -rf --one-file-system`.

**The decisive clue, from the owner,** was that a graceful quit and relaunch
wiped the install *within a single boot, with no reboot involved* -- which
eliminated the VM lifecycle, the shutdown path and everything this repo does at
boot, and pointed at the launcher itself.  The owner also maintained throughout
that this was not normal SteamOS behaviour, which was correct and was the reason
the search continued past several plausible dead ends.

**Ruled out along the way, each by measurement** (kept so they are not
re-derived): stable `/etc/machine-id`; correct NTP-synced clock; clean unmount
and journal flush on the boot that held the game, with an empty `lost+found`;
`qemu-img info` reporting no snapshots, `corrupt: false`, 61.1 GiB genuinely
allocated; this repo's `rm -rf` calls all scoped to `/usr/lib`; and a 64 MB
`FAKEGAME/blob` surviving two reboots, so nothing was deleting indiscriminately.

**Two hypotheses raised and RETRACTED:**
1. *Unclean-shutdown data loss.*  Wrong.  ext4 commits its journal every 5 s,
   `data=ordered` writes data first, QEMU's writeback cache honours guest
   flushes, and killing QEMU on a live host does not lose committed writes --
   the host page cache survives the process.  Only host power loss would, and
   the host never went down.
2. *A marker-file "reproduction".*  Wrong, and a bad experiment: the markers
   were written as **root** into Steam's own tree, and Steam legitimately cleans
   foreign files out of its directory during bootstrap.  `deck`-owned markers
   survived untouched.  Any future test MUST create files as the `deck` user.

**Dead end for tooling:** the neptune kernel is built without `CONFIG_AUDIT`.
`audit=1` reaches `/proc/cmdline` but `auditctl` still reports "audit support
not in kernel", so syscall auditing cannot name a deleter on this image.
(systemd's `+AUDIT` only means systemd links libaudit.)

Evidence bundle: `evidence-steam-wipe-20260828/`.

### RESOLVED: the guest DRM output coming up `enabled=disabled` (2026-08-27/28)

Some boots came up with `card0-Virtual-1: status=connected enabled=disabled` and
**zero flips** -- KWin logged `There are no outputs - creating placeholder
screen` across every KDE component, so the session had no output to draw on.
It was never a startup race in the obvious direction: the broker logged
`client attached` 49 seconds *before* KWin reported no outputs.

**Root cause: the host ran out of GPU virtual address space.**  With the host
wedged, guest allocations fail; NVIDIA's EGL reports a refused ioctl as
`GL_OUT_OF_MEMORY`; KWin cannot build its scene buffer, so it never completes a
modeset, so the output stays `disabled` and nothing ever flips.  No component
in that chain reports the real error.

Confirmed on 2026-08-28: with `alloc VA space` errors in the host kernel log the
guest could not display at all; after a host reboot, with **zero** such errors
and host Vulkan healthy, the *same commit* rendered the SteamOS desktop and
Steam normally.  The historical one-in-six intermittency is consistent with a
partially-exhausted host, though that specific earlier occurrence was not
measured at the time.

The VA exhaustion itself is a separate open bug, tracked below.  It **is**
inherent to nvkvm, and it scales with the number of client *teardowns* rather
than with elapsed time -- which is why one 9-hour session holding a single game
open leaked almost nothing while shorter sessions that start and stop many
clients collapse the host.

Capture in `evidence-steam-wipe-20260828/drm-disabled/`.

### OPEN: host BAR1 address-space leak, 59 mappings per guest client teardown

The host runs out of **GPU BAR1 aperture address space** (not VRAM) until no
process on the machine can create a Vulkan device.  It is the cause of the
`enabled=disabled` display failure above, and it is nvkvm-specific.

```
clientUnmapResourceRefMappings: Failed to auto-unmap (status=0x23) hClient c1d003f3: hResource: 40
```
`status=0x23` is `NV_ERR_INVALID_CLIENT`: RM's teardown sweep cannot release the
mapping, so it is never freed.  BAR1 on the test host is only **256 MiB**
(Resizable BAR off), which is likely why this box noticed first.

**Deterministic reproduction** -- run `vkcube` in the guest for 60 s and kill it:

| client | teardown | new failed auto-unmaps |
|---|---|---|
| `vkcube` in guest | SIGKILL | **+59** |
| `vkcube` in guest | clean SIGTERM | **+59** |
| same `vkcube` binary **on the host** | SIGKILL | **0** |
| host CUDA, 10 Kata GPU containers | clean | **0** |

Clean and abnormal exit leak identically, so abnormal teardown is not the
trigger.  It scales with client teardowns, not with time: a long session holding
one game open leaks little; repeated launch/quit cycles collapse the host.

**Nothing surfaces it.**  While wedged, `nvidia-smi` reported BAR1 Used = 59 MiB
of 256 MiB -- the leak consumes address space without being accounted as used.
Watch this instead (kernel VA errors lag the real failure by ~7 minutes):

```
journalctl -k -b 0 --no-pager | grep -c "Failed to auto-unmap"
```
Use `journalctl`, **not `dmesg`** -- its ring buffer rotates and under-counts.

**Recovery needs no reboot:** `rmmod nvidia_drm nvidia_modeset nvidia_uvm nvidia`
then `modprobe` restores Vulkan.  (That measurement was confounded by stopping
`gdm` first, so it does not yet separate the reload from killing the compositor.)

**Ruled out by measurement:** idle guests, 45 clean isolates, 15 SIGKILLed
isolates, continuous rendering -- all return exactly to baseline.  Kata alone and
Kata concurrent with the VM both leak zero.

**Narrowed to fd/client identity.**  Every map uses the same per-client
`h_device=0xbeef0004` (NV20_SUBDEVICE_0), 895 maps against 376 unmaps, and the
failing client was torn down via the implicit fd-close path.  The suspicion is
that nvkvm spreads one guest device file across several host opens, so the
client owning the mapping context is not the client RM tears down.

Full investigation, evidence and tooling live in the `nvkvm-pv` repo under
`docs/investigations/va-space-leak/` (branch `va-space-leak`).

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

A third candidate now exists, untested: the **BAR1 address-space leak** above.
Chromium-based UI layers spawn and tear down GPU clients repeatedly, which is
exactly the pattern that leaks, and a GPU operation that stalls on exhausted
address space would blow the watchdog interval while reporting nothing.  The
20-minute time-to-crash is consistent with a host that degrades gradually.
Testing this needs only the `Failed to auto-unmap` counter sampled during a
play session.

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
