# SteamOS-as-nvkvm-guest — run notes (2026-08-23)

Artifacts in this directory:
- steamos-nvkvm.qcow2        — patched working copy (module + 595.84 userspace baked in)
- OVMF_VARS.fd                — UEFI vars for this VM (OVMF_CODE is shared/system, read-only)
- install_nvkvm_userspace.sh  — offline staging script (module + libs + vendor JSON into a mounted rootfs)
- nvkvm-guest-neptune616.ko   — built module, vermagic 6.16.12-valve24.4-1-neptune-616-gfe145653a794
- headers/                    — extracted linux-neptune-616 headers package (build tree)
- nvidia-run/extracted/       — extracted NVIDIA-Linux-x86_64-595.84.run payload
- diagnostics/vk_probe.py     — ctypes Vulkan probe used to isolate the M4 failure
- mnt/rootfs, nbd_dev.txt     — leftover mount-point/bookkeeping from the offline-mount steps (nothing mounted now)
- build_qemu.log, steamos_boot.log, gate_build.log — raw logs
- type_send.sh                — QEMU-monitor sendkey typing helper (no guest network/SSH access in this image)

## Result summary
M1 GATE: PASS. nvkvm-guest.ko builds clean against the exact SteamOS/neptune
kernel headers (linux-neptune-616-headers-6.16.12.valve24.4-1, fetched from
steamdeck-packages.steamos.cloud). vermagic matches exactly. Needed pahole
(dwarves) on the build host for BTF; not present by default on this Ubuntu box.

M2 INSTALLER: substance done, OTA wrapper NOT implemented. Offline-mounted the
qcow2 copy's rootfs-A (nbd + btrfs ro=false, no live steamos-readonly toggle
used), installed nvkvm-guest.ko into usr/lib/modules/$KVER/updates + depmod,
extracted the 595.84 .run and staged the required+optional libs with SONAME
symlinks, wrote GLVND/Vulkan/OpenCL vendor manifests, added
/etc/modules-load.d/nvkvm.conf. Did NOT port steamos-nvidia-installer's
steamos-update wrapper/repatch.sh (no real OTA available to test against here).
Deviated from the reference installer's "build in a throwaway pacman chroot"
step: nvkvm-guest.ko has no package-manager dependency (plain kbuild, unlike
nvidia-open-dkms), so it was built directly on the host against the extracted
headers -- simpler and equally correct, but worth flagging as a deliberate
deviation from "keep their chroot" if that mattered for other reasons (e.g.
matching glibc/toolchain ABI more strictly).

M3 BOOT UNDER NVKVM: PASS, verified inside the guest (via QEMU monitor
sendkey, no sshd in this live/repair image):
  - grep nvkvm /proc/modules -> nvkvm_guest 139264 0 - Live ... (OE)
  - /dev/nvidia0, /dev/nvidiactl, /dev/nvidia-modeset, /dev/nvidia-uvm present
  - /dev/dri: card0 card1 renderD128
  - nvidia-smi: Driver Version 595.84, CUDA 13.2, GeForce RTX 4070, matches host
  - tests/validate.sh NOT run: this live/repair environment has no cc/gcc
    (validate.sh compiles C probes at runtime). Ran manual equivalents instead.
  - required a QEMU rebuild from origin/main first (0010 EFAULT-retry patch);
    without it this exact scenario (GL/KMS desktop) was expected to die in 10-60s.
  - required booting with explicit OVMF pflash drives -- run_test_vm.sh has no
    UEFI firmware by default (fine for the Ubuntu cloud image it was written
    for) and SteamOS's disk is GPT/UEFI-only, so plain SeaBIOS hung at
    "Booting from Hard Disk...".

M4 GAMESCOPE: BLOCKED, root-caused (not just reproduced) in nvkvm itself.
  - gamescope -- steam: "[gamescope] [Error] vulkan: failed to find physical
    device" / "Failed to initialize Vulkan" / "Failed to create backend."
  - Ruled out: DRM render-node permissions (deck was missing from the `render`
    group -- fixed with usermod, no change) and running as root (no change,
    rules out permissions entirely).
  - Isolated with a ctypes-only Vulkan probe (no compiler available in-guest,
    so no C toolchain dependency): vkCreateInstance succeeds (rc=0) --
    loader/ICD-JSON/library resolution is all correct -- but
    vkEnumeratePhysicalDevices returns rc=-3 (VK_ERROR_INITIALIZATION_FAILED),
    count=0.
  - Kernel log for that exact call shows nvkvm accepting/forwarding everything
    (a new RM session mapped OK) with no allowlist DENY, but repeats:
    "nvkvm: RM_ALLOC hClass=0x2081 has no alloc-param size entry; forwarding a
    256-byte window" -- i.e. nvkvm does not know the real alloc-param struct
    size for (at least some sub-class of) NV2081_BINAPI and guesses 256 bytes.
    nvidia-smi's lighter query path apparently doesn't hit the same
    under-sized allocation and works fine; Vulkan's physical-device
    enumeration does and fails.
  - This matches the project's own prior finding in
    docs/internal/mint-guest-desktop.md (a DIFFERENT, already-diagnosed gap --
    NVKMS cmdType=33 denied, needs a virtual-NVKMS implementation) but is NOT
    the same bug: this one is upstream of any NVKMS/display-topology call,
    purely in RM_ALLOC/hClass=0x2081 sizing, and it has no DENY line, so it is
    a sizing/correctness bug rather than an allowlist gap.
  - NOT fixed here: per the repo's own "measure, don't derive" rule for ABI
    tables, guessing a corrected size without cross-checking NVIDIA's
    open-gpu-kernel-modules headers for the 580 profile risks exactly the
    silent-truncation bug the project has been burned by before. This needs
    someone to identify which NV2081_BINAPI sub-command Vulkan's device
    enumeration issues and measure its real struct size.

## Not verified
- steamos-update wrapper / OTA survival (not implemented, not tested)
- tests/validate.sh (no cc in this live image)
- anything past vkEnumeratePhysicalDevices -- no GL/EGL path tried, no actual
  game

## Update 2026-08-23 — NV2081_BINAPI fix (coordinator follow-up)

Coordinator supplied the correct struct (NV2081_ALLOC_PARAMETERS = 4 bytes,
from cl2081.h). Cross-checked against 4 local ogkm clones (550.54.14,
575.51.03, 580.159.04, 610.43.02) -- byte-identical in all four (single
NvU32 field, read directly from source, not compiled/derived -- trivial
enough not to need a probe). Diff in nv2081_fix.diff (src/abi/nvgpu.h +
src/guest/nvkvm_main.c, both switch sites). Rebuilt nvkvm-guest.ko against
the neptune headers (clean), reinstalled into the qcow2 offline, rebooted.

MEASURED result: the fix is real and takes effect -- nvidia-smi's RM session
no longer produces "RM_ALLOC hClass=0x2081 has no alloc-param size entry"
(confirmed absent across two independent post-boot checks). But it did NOT
unblock Vulkan: the ctypes probe still gets vkCreateInstance rc=0,
vkEnumeratePhysicalDevices rc=-3 (VK_ERROR_INITIALIZATION_FAILED), count=0,
identical to before the fix.

Traced further: `journalctl -k -g nvkvm` immediately after two separate
vk_probe.py runs shows ZERO new nvkvm kernel activity for either run -- no
new "session N RING MAPPED" line, no RM_ALLOC warning of any class. Compare
nvidia-smi, which always produces a fresh RING MAPPED line. Conclusion: the
Vulkan failure happens BEFORE the guest ever opens a new RM session, i.e.
upstream of any RM_ALLOC call -- so there is no "chain" of missing
alloc-param sizes to fix here; the 0x2081 gap was real but is not on the
code path that's failing.

Formed and then DISPROVED one hypothesis via source inspection rather than
shipping it as a finding: guest /sys/bus/pci/devices/ only has the identity
device at 0000:00:07.0, while /proc/driver/nvidia/gpus/ (nvkvm's hostfile)
reports the HOST's real bus address 0000:01:00.0 -- looked like a plausible
mismatch. But nvkvm_hostfile.c's own header comment says this is
deliberate and strace-confirmed: libcuda/NVML look up gpus/<bdf>/ using the
BDF *RM itself* reports, not the guest's PCI topology, and BDF was
deliberately changed FROM a hardcoded guest slot TO the host's real BDF for
exactly this reason. So this is correct-as-designed, not the bug.

NOT resolved: what libGLX_nvidia's Vulkan physical-device enumeration
actually fails on before touching the kernel module. No strace, no gdb, no
cc available in this live/repair guest to trace further. This needs either
a guest with a compiler/strace, or an nvkvm-side ioctl trace at a layer
below RM_ALLOC (e.g. the NV_ESC_* dispatch in nvkvm_ioctl.c) to see what
call, if any, is made and rejected before enumeration gives up.

gamescope was not re-tried after this -- the underlying Vulkan failure is
unchanged, so it would reproduce identically.

## Update 2026-08-23 (cont'd) — ICD packaging root cause + full resolution

Coordinator's hypothesis (Vulkan works fine on the Ubuntu nvkvm guest, so this
is an installer/packaging bug, not an nvkvm capability gap) was CORRECT and
is now fully confirmed end-to-end.

### Exact chain of MEASURED root causes (in the order found)

1. `ldconfig -r "$R"` (offline chroot-substitution mode) during the original
   hand-rolled staging did not produce a live cache with any nvidia entries.
   MEASURED: `ldconfig -p | grep nvidia` on the booted guest returned nothing
   before a live `sudo ldconfig`; ran clean afterward and indexed all staged
   libs. This alone did not fix vkEnumeratePhysicalDevices.

2. `VK_LOADER_DEBUG=all` on the ctypes probe (redirected to a file, since
   inline shell quoting through the QEMU-monitor keystroke-injection path is
   fragile) gave the real signal:
     ERROR: libnvidia-glsi.so.595.84: cannot open shared object file: No such file or directory
     ERROR: loader_icd_scan: Failed loading library associated with ICD JSON libGLX_nvidia.so.0. Ignoring this JSON
     ERROR: setup_loader_term_phys_devs: Failed to detect any valid GPUs in the current config
   `ldd /usr/lib/libGLX_nvidia.so.595.84` confirmed three unresolved deps:
   libnvidia-glsi, libnvidia-tls, libnvidia-glcore (glcore itself pulls in
   libnvidia-gpucomp, unresolved too). All four are in the driver .run
   payload and were even named in my own OPTIONAL list -- but did not end up
   on disk. Root cause of *why* not never fully isolated (script logic and
   disk space both looked fine on inspection); superseded by fix below rather
   than chased further.

3. FIX (per coordinator + user's suggestion): stopped hand-picking files
   entirely. Instead, in the offline-mounted rootfs, chroot in and run
   NVIDIA's own installer for userspace only:
     chroot "$R" /tmp/nvidia-install/nvidia-installer \
       --silent --no-kernel-modules --no-kernel-module-source \
       --no-nouveau-check --no-x-check --no-rpms
   rc=0. This installed 69 nvidia-prefixed files (vs. ~19 by hand), including
   every previously-missing lib, the full EGL external-platform JSON set,
   OpenCL ICD, Vulkan ICD JSON, and (unexpectedly, but correctly) the 32-bit
   compat libraries under /usr/lib32 -- entirely absent from my hand list.
   `ldd` on both libGLX_nvidia.so and libnvidia-eglcore.so.595.84 confirmed
   zero unresolved dependencies afterward.

4. MEASURED final probe result (ctypes, same script as before, re-run after
   reboot with this install):
     vkCreateInstance rc = 0
     [Vulkan Loader] linux_read_sorted_physical_devices: [0] NVIDIA GeForce RTX 4070
     vkEnumeratePhysicalDevices rc = 0 count = 1
   VK_SUCCESS, one physical device, the real RTX 4070. This is the fix.

### gamescope / Steam result

- First gamescope+steam attempts as root (`sudo gamescope -- steam`) failed
  two different ways: (a) nested inside the already-running desktop Wayland
  session, UID mismatch broke Wayland client auth outright; (b) from a bare
  VT, `bin_steam.sh: Error: Cannot run as root user` -- Steam's own safety
  check, unrelated to graphics.
- seatd was not running by default in this live image; `systemctl start
  seatd` fixed an earlier "Could not connect to socket /run/seatd.sock"
  failure (a real, separate, cheap fix -- worth enabling by default in the
  installer).
- Running as `deck` (no sudo), on a clean unused VT (tty4/tty5, not nested in
  the desktop session), with seatd running: gamescope selected the RTX 4070,
  detected nvkvm's virtual DRM connector ("Virtual-1 (connected)", mode
  1280x800@60Hz), started its own nested Wayland compositor + Xwayland +
  pipewire, and launched Steam successfully.
- Default $HOME (on the 5 GB rootfs partition, 36 MB free after the full
  nvidia-installer install -- see below) was too small for Steam's own
  bootstrap tarball extraction (`No space left on device`, confirmed via
  `df -h` and `du -xh --max-depth=1 /usr`). Redirecting `HOME=/tmp/steamhome`
  (tmpfs, RAM-backed, 3.8G free) let Steam's bootstrap complete.
- MEASURED via `ps aux` on a separate clean VT (input had been grabbed by
  gamescope's libei emulation on the launching VT, confirming the
  screendumps looked "stuck" when Steam was actually alive and rendering):
  the full Steam stack running -- steam.sh, the real ubuntu12_32/steam
  binary, steamwebhelper (multiple Chromium-derived processes actively
  burning CPU -- this is what renders the UI), Xwayland, gamescopereaper.
  Matches the coordinator's screen-photo transcription exactly: Steam's
  sign-in screen fully rendered (game art background, QR code, sign-in
  fields, Deck-style A/B footer).

**Result: Steam's own UI is rendering end-to-end through nvkvm on SteamOS.**
This satisfies "Steam's own UI counts as a first result." Did not go further
to an actual game in this session (needs real Steam login + a game download,
and the disk-space fix below should be made persistent first).

### Disk space -- not yet fixed persistently

MEASURED: `/usr` alone is 7.6G apparent size on a 5.0G rootfs partition
(4.1G /usr/lib + 2.0G /usr/share + 1.1G /usr/lib32 + 548M /usr/bin);
btrfs compression gets actual disk usage down to 4.3G/5.0G used, 36M free.
The full nvidia-installer payload (64-bit + 32-bit libs) simply does not
leave headroom for Steam's own runtime in this repair image's small rootfs.
`HOME=/tmp/steamhome` (tmpfs) is a session-only workaround, explicitly not a
real fix (RAM-backed, gone on reboot, and will itself fill for a real game
install). Not yet applied: growing the qcow2 (`qemu-img resize`) and
extending a partition (home, vda5, is last on disk and 100% full at 2.0G
independently -- simplest to grow) + filesystem to give Steam persistent,
disk-backed room. Left undone this session to avoid disrupting the
currently-running, visually-confirmed Steam session.

### Process/tooling notes worth keeping

- Once gamescope acquires the seat, it grabs keyboard input via libei even
  though it also runs headless -- QEMU-monitor `sendkey` to that VT stops
  reaching the shell. Diagnosed by switching to an unused VT and running
  `ps aux` there. A real network shell (sshd/dropbear/telnetd) in the image
  would avoid this whole class of friction; not set up this session,
  flagged as a good addition for the *next* debugging pass, not the
  production installer.
- `nvidia-installer -A` for the full flag list; `--no-kernel-modules`
  (plural) is the exact flag, not `--no-kernel-module`.
- Chroot needs proc/sys/dev bind-mounted and the extracted .run payload
  bind-mounted in (not copied) to avoid doubling disk use during install.

## Update 2026-08-22/23 — persistent disk, entire desktop on nvkvm's plane, CAP_SYS_ADMIN gate root-caused

Coordinator-directed session. Goals: (1) persistent disk so tmpfs HOME can go,
(2) the ENTIRE desktop (not just gamescope) on nvkvm's plane, (3) launch a
game if time allows.

### In-guest command channel — `agent.py` (no sshd workaround)

This repair/live image has **no sshd** and no way to get a real shell except
QEMU-monitor `sendkey` keystroke injection, which is too slow/fragile for
anything beyond a few short commands (screendumps had to be OCR'd by eye,
multi-line output was unreadable). Fix, saved this session:

- **`agent.py`** (saved here as `agent.py`, 865 bytes): a stdlib-only Python
  HTTP server, run as the `deck` user inside the guest. `POST /` with a shell
  command as the body; it runs `bash -c <cmd>` and returns
  `stdout + "\n--STDERR--\n" + stderr + "\n--RC=<n>--\n"`. Threaded
  (`socketserver.ThreadingMixIn`), binds `0.0.0.0:5000`.
- **`inject_agent.sh`** (saved here): types `agent.py`'s contents into the
  guest as one base64 line via `type_send.sh` (base64 alphabet is the only
  character set `type_send.sh`'s keysym-per-character loop handles reliably —
  it silently drops `;`, `(`, `)`, and other shell metacharacters, which
  wastes a lot of time if you don't know that going in), decodes it to
  `/tmp/agent.py` in-guest, starts it with `setsid python3 /tmp/agent.py &`
  (must be `setsid`, not just backgrounded — a plain `&` job stays in the
  login shell's process group and gets `SIGTTIN`/job-control-STOPped the
  moment anything touches that tty, e.g. a VT switch; `ps` then shows it in
  state `Tl`, silently dead-in-the-water until `kill -CONT`), then adds a
  QEMU-monitor `hostfwd_add net0 tcp::15000-:5000` so the host can reach it.
- **Use it**: `curl -s -X POST --data-binary '<shell command>' http://127.0.0.1:15000/`
  from the host (through the hostfwd). This is what every measurement and
  fix below actually ran through — no more keystroke injection needed once
  it's up.
- **Caveats**: lives in `/tmp` (tmpfs) in the guest, so it does not survive a
  guest reboot — re-run `inject_agent.sh` after every boot (takes ~15s, most
  of which is the base64 typing). The hostfwd rule also resets on every QEMU
  relaunch. `agent.py` and `inject_agent.sh` themselves are saved on the
  **host** at `/root/steamos-nvkvm/`, so this only needs retyping, not
  re-writing.

### Goal 1: persistent disk — DONE, and now baked into the image

Root cause (from the previous session): the 5 GB rootfs was ~96% full after
the driver install, and `/home` (vda5, 2 GB) was 100% full — Steam's own
bootstrap needed `HOME=/tmp/steamhome` (tmpfs) to extract at all, which is
not durable and can't hold a game.

**Live resize attempt failed, then succeeded offline** — worth recording
since it looks like an nvkvm/QEMU bug at first glance but isn't one:
- `block_resize` on a *running* QEMU (HMP or QMP, any target size from
  +100 MB to +67 GB) failed identically every time:
  `Error: Failed to grow the L1 table: File too large`. Traced into
  `/opt/qemu-src/block/qcow2-cluster.c` — `qcow2_grow_l1_table()`'s only two
  `-EFBIG` returns are sanity caps at `INT_MAX/8` L1 entries and
  `QCOW_MAX_L1_SIZE/8` entries, both far beyond anything a <100 GB resize
  could hit; confirmed by grep against `tests/qemu-iotests/206.out`, which
  reproduces the exact same string only for deliberately-absurd sizes near
  `INT64_MAX`. `strace -f -e trace=truncate,ftruncate,fallocate,pwrite64` on
  the live QEMU process across a `block_resize` call caught **zero** matching
  syscalls — the error fires before any I/O is attempted. Root cause not
  pinned down further (not worth the time once the workaround below existed);
  this reads like a live-resize-specific code path bug, not a real size
  limit. **Not an nvkvm bug** — reproduced with plain upstream qcow2 code,
  no nvkvm patches touch `block/`.
- **Workaround, which is also just the normal/correct way to do this**:
  `systemctl poweroff` the guest, `qemu-img resize file.qcow2 +60G` on the
  *stopped* image (works instantly, `qemu-img check` clean before and after),
  relaunch. Only costs a reboot.
- In-guest: `lsblk` showed the GPT already **auto-grew partition 5 (`home`)**
  to fill the new disk space on first boot after the resize, with no action
  from us — this SteamOS image has a boot-time grow-last-partition unit.
  Only `resize2fs /dev/vda5` was needed (and even that reported "already
  the right size" — the growfs unit had already done it). `/home` went from
  2.0G/100%used/4.4M-free to **61G/60G-free**.
- `/dev/vda3` (rootfs, `/`) is *not* last-on-disk, so it did not grow and is
  still ~96% full (206M free after the full driver install). Not fixed —
  everything that needs room (Steam's library, `HOME=/home/deck`) lives on
  the now-huge `/home`, so this hasn't been a blocker, but note it for
  anyone planning to install large packages system-wide.
- **Baked into the rebuilt image** (see the corruption/rebuild section
  below): the qcow2 is now built at 67.6 GiB from the start, so this is a
  one-time fact about the image, not a per-boot chore.

### Goal 2: entire desktop on nvkvm's plane — DONE, confirmed automatic at boot

**Ground truth (measured, stable across every boot this session):**
`/dev/dri/card0` = nvkvm (`vendor 0x10de device 0x2786`, driver `nvidia`,
PCI `0000:00:07.0`, matches `-device nvkvm-gpu,addr=7`) with render node
`renderD128` under the same PCI device. `/dev/dri/card1` = QEMU's default
emulated VGA (`vendor 0x1234 device 0x1111`, driver `bochs-drm`, PCI
`0000:00:02.0` — this is the `-device VGA` that gets added automatically
because nothing passes `-vga none`). This matches
`docs/internal/mint-guest-desktop.md`'s already-documented finding
one-for-one, including its explicit conclusion **`-vga none` is NOT
required** — keep the emulated VGA (it's what GRUB/early-kernel draw the
boot console on) and select the right DRM node by driver name, not index.

**Blocker #1, root-caused: nvkvm's own `CAP_SYS_ADMIN` gate on the primary
node.** Every Plasma/KWin session, across many boot/restart cycles, opened
only `/dev/dri/card1` (bochs) — either because it flat-out could not open
`card0` (`EACCES`, `kwin_core: Failed to open drm node: "/dev/dri/card0"`),
or — after working around that — because a *second*, separate problem then
surfaced (below). Isolated the open failure with `os.open()` directly:
plain `deck` (uid 1000, in `video` group, with a standing filesystem ACL
`user:deck:rw-` on the device — none of that mattered) got `EACCES`; the
identical call under `sudo` (root) succeeded; the identical call as `deck`
with **`CAP_SYS_ADMIN` retained** (`setpriv --reuid=1000 --ambient-caps=+sys_admin`)
also succeeded. `dmesg`/dnf audit showed nothing — this is a plain DAC-style
check inside nvkvm's own guest module, not logind/udev/cgroups (checked and
ruled out: `DevicePolicy=auto` on both `user-1000.slice` and the session
scope, meaning systemd installs no cgroup-device BPF program at all here).
Coordinator confirmed by name: this is `privileged_modeset`, a runtime
module parameter added to `nvkvm-guest.ko` (commit `4257500` on `main`,
landed the day before this session), default **on**. **MEASURED**, flipping
it live settles the question completely:
```
cat /sys/module/nvkvm_guest/parameters/privileged_modeset   # Y (default) -> deck: EACCES opening card0
echo 0 | sudo tee /sys/module/nvkvm_guest/parameters/privileged_modeset
cat /sys/module/nvkvm_guest/parameters/privileged_modeset   # N -> deck: open() succeeds, fd returned
```
With the gate off, KWin opens `card0` fine as a completely unprivileged
`deck` process — **the gate is not blocking this session once disabled**,
which is itself worth stating as the measured negative the coordinator asked
for. This is a real gap for SteamOS-style direct-compositor sessions
(sddm→kwin_wayland opens the primary node directly, with no root-helper
fd-passing step the way a logind-brokered flow would have) — worth raising
upstream in nvkvm, since the intended security boundary (require a
privileged step to modeset) doesn't fit this class of guest.

**Blocker #2, separate from the gate: KWin auto-detects *both* GPUs and
EGL init fails when it does.** Even with the gate off, KWin's default
"no backend specified, automatically choosing drm" path opened `card0`
*and* `card1` together, and `kwin_scene_opengl: Creating the OpenGL
rendering failed: "Could not initialize egl"` followed. Fix: force
single-GPU with `KWIN_DRM_DEVICES=/dev/dri/card0`. Isolated-process test
(`sudo -u deck env KWIN_DRM_DEVICES=/dev/dri/card0 kwin_wayland --socket
wayland-diag1`) then showed the clean path: `Egl Initialize succeeded`,
`EGL version: 1.5`, `OpenGL compositing has been successfully initialized`,
CRTC/connector assignment, real KDE effect plugins loading (blur, overview,
etc.) — a fully working compositor on `card0` alone.

**Wiring `KWIN_DRM_DEVICES` into the *real* autologin session was its own
side-quest** — two wrong mechanisms tried before finding the right one:
- `~/.config/plasma-workspace/env/*.sh` (the classically-documented KDE
  env-script directory): created, executable, correct syntax — never
  sourced. Not chased further (superseded by the fix below).
- `systemctl --user set-environment KWIN_DRM_DEVICES=...` + `systemctl --user
  restart plasma-kwin_wayland.service`: `show-environment` confirmed the var
  was set in the manager, but the freshly-restarted `kwin_wayland` process's
  own `/proc/<pid>/environ` **did not have it** — `set-environment` on an
  already-running manager does not appear to reliably propagate to a
  unit restarted afterward, at least not in this build. (`kwin_wayland` runs
  as systemd user service `plasma-kwin_wayland.service`, `ExecStart=/usr/bin/
  kwin_wayland_wrapper --xwayland` — it is not a plain child process of
  `startplasma-wayland`, which is why a plain shell-sourced env script or a
  post-hoc env poke both missed it.)
- **What actually works, and is what's baked into the rebuilt image**:
  `~/.config/environment.d/*.conf` (systemd's own per-user environment
  mechanism, imported by `pam_systemd` at *login* time, before any unit —
  including `plasma-kwin_wayland.service` — starts). One file,
  `~/.config/environment.d/nvkvm.conf`:
  ```
  KWIN_DRM_DEVICES=/dev/dri/card0
  ```
  Confirmed end-to-end on a **fresh boot with zero manual steps**:
  `/proc/<kwin_pid>/fd` → only `card0` + `renderD128`; `/proc/<kwin_pid>/
  environ` → `KWIN_DRM_DEVICES=/dev/dri/card0` present.

**MEASURED end state (fresh boot, sddm autologin, no keystrokes typed after
boot beyond re-injecting `agent.py` to go measure it):**
- `cat /sys/module/nvkvm_guest/parameters/privileged_modeset` → `N`
  (this is now the module's *default*, not a runtime toggle — see rebuild
  section).
- `/proc/<kwin_pid>/fd` → `19,20 -> /dev/dri/card0`, `40,48 ->
  /dev/dri/renderD128`. No `card1` fd at all.
- `journalctl -u qemu`-equivalent (QEMU's own stderr, `NVKVM_PRESENT_TIMING=1`):
  ```
  nvkvm present: display mode = GL zero-copy (host UI renders on NVIDIA: native import); host GL renderer: NVIDIA Corporation / NVIDIA GeForce RTX 4070/PCIe/SSE2
  nvkvm disp stats: 60.0 frames/s dropped=0 failed=0 present_mean=0.27ms (total consumed=105 dropped=0 failed=1)
  nvkvm disp stats: 52.9 frames/s dropped=0 failed=0 present_mean=0.41ms (total consumed=209 dropped=0 failed=1)
  ```
  (the single `failed=1` is from one present attempt *before* EGL finished
  initializing, at guest boot — never increments again.) Frame rate settles
  to a few fps once the desktop is idle (no animation happening), as
  expected, not a problem.
- `nvidia-smi` **inside the guest**, run through `agent.py`, no photo needed:
  ```
  GPU 0: NVIDIA GeForce RTX 4070 ... 1894MiB / 12282MiB ... 2% util
  Processes:
    673   systemd-logind      0MiB
    1006  kwin_wayland       11MiB
    1133  Xwayland            3MiB
    1169  ksmserver           2MiB
    1171  kded6               2MiB
    1210  plasmashell        73MiB
    1286  kaccess             2MiB
  ```
  Real GPU memory allocations for the actual desktop session, through nvkvm,
  on the host's real RTX 4070.
- GL errors: **1** occurrence total this boot
  (`kwin_scene_opengl: Invalid framebuffer status: "GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT"`),
  at T+2s during startup, never repeated. Matches
  `src/guest/nvkvm_kms.c`'s documented, named limitation verbatim: *"NVIDIA
  cannot use a LINEAR dma-buf as an EGLImage render target ... LINEAR is
  excluded for the same reason -- see the accept callback, which still
  allows it for cursors."* Consistent with one early hardware-cursor-plane
  attempt failing and KWin falling back cleanly — did not chase further
  with `KWIN_FORCE_SW_CURSOR=1` since the natural (no-workaround) behavior
  is already a single non-fatal event, not the continuous per-frame spam
  seen in earlier, messier test sessions (those spam-y runs turn out to have
  been artifacts of racing two kwin instances for the same DRM master, not
  a real steady-state problem — see below).

**What this is NOT**: this is Plasma (the repair image's own session,
`sddm.conf.d`'s `Session=plasma`), not `gamescope-session`. On a real
deployed SteamOS the actual session is gamescope, which is architecturally
simpler for GPU selection (Vulkan `vkEnumeratePhysicalDevices` + its own
explicit `--drm-device`-equivalent connector pick, no auto-multi-GPU EGL
probe) and was *already* proven working on nvkvm's plane in the previous
session (Steam's sign-in UI, photographed). Both are now confirmed working;
Plasma was the harder of the two to land because of the two blockers above.
A side-quest to make `sddm` boot straight into `gamescope-wayland.desktop`
(which is the *actual* SteamOS default — this repair image's
`/etc/sddm.conf.d/zz-steamos-autologin.conf` and, unexpectedly,
`/usr/lib/sddm/sddm.conf.d/steamos.conf` both override it to `plasma`,
apparently self-reinforced by `/var/lib/sddm/state.conf` after every login)
was abandoned once the direction shifted back to "fix Plasma itself" —
noted here only because the config-precedence maze (three separate files,
in `/etc` *and* `/usr/lib`, plus a state file that appears to get rewritten
after every successful login) cost real time and would trip up anyone else
trying it.

**Things that turned out to be red herrings, worth not re-chasing:**
- `screendump <file> nvkvm0` and `NVKVM_PRESENT_DUMP=<path>` both reliably
  return "no surface" / write nothing **whenever the active present mode is
  GL zero-copy** — this is by design, not a bug: `nvkvm_present_publish()`
  (the only place that populates a `DisplaySurface` or writes the PPM) is
  gated on `p->stage_has_frame`, which the GL-zero-copy path never sets (it
  hands the dma-buf straight to the UI's own GL context, bypassing the CPU
  staging buffer entirely for performance). To get either measurement,
  force `NVKVM_PRESENT_MODE=readback` — **but see the hang below before
  trying that again**.
- `Could not find edid for connector ... Virtual-1` and
  `kwin_core: Failed to open drm node: ""` / `kwin_scene_opengl: couldn't
  find dev node for drm device` are both harmless, cosmetic, and appear on
  every successful boot too — non-fatal secondary lookups (EDID probing on
  a virtual connector with no EDID to find; some KWin internal render-node
  re-derivation that returns empty but isn't on the critical path). Neither
  blocks EGL init or compositing.

### `NVKVM_PRESENT_MODE=readback` hangs the guest at the GRUB handoff — real finding, cost a rebuild

Tried to force readback mode to get a pixel-level `NVKVM_PRESENT_DUMP`
measurement (screendump/dump both need it, see above). Booting with
`NVKVM_PRESENT_MODE=readback NVKVM_PRESENT_DUMP=... NVKVM_PRESENT_TIMING=1`
set: the guest **never got past the same single log line**
(`ChainedLoaderDevicePartUUID: ...`, i.e. right after GRUB is chainloaded,
before GRUB's own screen even draws) for 3+ minutes at ~280% host CPU
(4 vCPUs all busy) — vs. every other boot this session reaching the full
desktop in under 5 seconds. Killed it (`kill -9` on the QEMU process, an
unclean-power-loss equivalent for the guest) and relaunched **without**
`NVKVM_PRESENT_MODE` — it hit the **identical** hang. `qemu-img check` on
the qcow2 came back clean (no container-format corruption), so the hang
itself is reproducible and not an artifact of the kill; but the *guest's*
on-disk state after the forced kill was apparently bad enough that no
subsequent boot got past very-early GRUB, confirmed by trying 3 times
(with/without `NVKVM_PRESENT_MODE`, with a fresh vs. reused `OVMF_VARS.fd`)
with the identical symptom every time — the on-screen state was a single `_`
in the top-left that visibly reset/cleared repeatedly rather than
progressing (per direct user observation of the physical screen).
**Not fully root-caused** — didn't chase whether it's `NVKVM_PRESENT_MODE=
readback` itself pathologically slow/deadlocking during GRUB's own
text-mode console updates (plausible: readback forces a CPU copy on every
frame, and GRUB's frequent small redraws could be a bad case for whatever
the readback path's frame-rate limiting or locking does), or whether the
`kill -9` corrupted something inside the guest filesystem (btrfs/GPT/ESP)
in a way `qemu-img check`'s qcow2-container-level check can't see. Given a
known-working, freshly-rebuilt image was available and the coordinator's
explicit call ("don't use a broken image"), **rebuilt from the pristine
source image rather than debug further** — see next section. Flagging for
whoever touches `NVKVM_PRESENT_MODE=readback` next: reproduce on a
disposable copy, not the working image, and don't `kill -9` a QEMU process
that's mid-boot if avoidable — prefer the monitor's `quit` (still doesn't
graceful-shutdown the *guest*, but at least lets QEMU close the qcow2 file
through its own code path rather than SIGKILL yanking it away with I/O
possibly in flight).

### Rebuilt the guest image from scratch, offline, with the fixes baked in

Source: `/home/ubuntu/Downloads/steamdeck-oobe-repair-20260707.10-3.8.14.img`
(the original pristine repair image — still present, still exactly the file
the very first image was made from). The broken qcow2 is preserved at
`steamos-nvkvm.qcow2.broken` (not deleted, in case someone wants to actually
diagnose the hang later).

```
qemu-img convert -f raw -O qcow2 <pristine .img> steamos-nvkvm.qcow2
qemu-nbd --connect=/dev/nbd0 steamos-nvkvm.qcow2
mount /dev/nbd0p3 mnt2/rootfs && btrfs property set mnt2/rootfs ro false
mount /dev/nbd0p5 mnt2/home
# kernel module (reused the already-built nvkvm-guest-neptune616.ko -- no rebuild needed)
cp nvkvm-guest-neptune616.ko mnt2/rootfs/usr/lib/modules/$KVER/updates/nvkvm-guest.ko
depmod -b mnt2/rootfs $KVER
echo nvkvm-guest > mnt2/rootfs/etc/modules-load.d/nvkvm.conf
# the fix: default the gate OFF, not toggle it live every boot
printf 'options nvkvm_guest privileged_modeset=0\n' > mnt2/rootfs/etc/modprobe.d/99-nvkvm.conf
# userspace (reused the already-extracted 595.84 .run payload -- no re-download/extract)
mount --bind /proc /sys /dev  into the chroot; bind-mount the extracted .run payload to /tmp/nvidia-install
chroot mnt2/rootfs /tmp/nvidia-install/nvidia-installer --silent --no-kernel-modules \
    --no-kernel-module-source --no-nouveau-check --no-x-check --no-rpms
# the other fix: KWIN_DRM_DEVICES via systemd environment.d (see above for why this
# mechanism specifically, not the two that don't work)
mkdir -p mnt2/home/deck/.config/environment.d
echo 'KWIN_DRM_DEVICES=/dev/dri/card0' > mnt2/home/deck/.config/environment.d/nvkvm.conf
chown 1000:1000 (that file and its dir)
# unmount everything, qemu-nbd --disconnect
qemu-img resize steamos-nvkvm.qcow2 +60G   # offline -- no L1-table bug here, see Goal 1
qemu-img check steamos-nvkvm.qcow2         # clean
```

**MEASURED result, this is the whole point of baking it in**: booted the
rebuilt image with **zero manual steps** (no keystroke injection until
*after* boot, purely to go measure the result) — `privileged_modeset` came
up `N` from the module default, `kwin_wayland` opened only `card0` from the
`environment.d` var, `nvidia-smi` inside the guest showed real GPU
allocations for the desktop session, `/home` had 60G free. All of Goal 1 and
Goal 2's fixes are now properties of the image, not of this session's
runtime patches.

### Goal 3: launch a game — not reached

Steam's UI has been confirmed rendering (both via gamescope, previous
session, and now via the full Plasma desktop, this session) but **no Steam
account is logged in** — this repair image has no credentials and none were
provided. Installing/launching an actual game needs a real Steam login,
which needs either interactive credential entry (2FA-gated, can't automate
blind) or a way to inject a `config.vdf`/SSO token, neither attempted. This
remains the one unmet goal — flagging it explicitly rather than presenting
partial progress as done.

### Artifacts added/changed this session

- `agent.py`, `inject_agent.sh` — see above, now on the host filesystem.
- `steamos-nvkvm.qcow2` — rebuilt (see above). `steamos-nvkvm.qcow2.broken`
  — the pre-rebuild image, kept for anyone who wants to root-cause the
  `NVKVM_PRESENT_MODE=readback` hang.
- Baked into the image (not runtime patches any more):
  `/etc/modprobe.d/99-nvkvm.conf` (`privileged_modeset=0`),
  `/etc/modules-load.d/nvkvm.conf`,
  `/home/deck/.config/environment.d/nvkvm.conf` (`KWIN_DRM_DEVICES=/dev/dri/card0`).

### Next steps (not done this session — captured per coordinator/user direction)

The steps above were done by hand, once, against one specific pristine image.
The user wants this turned into a repeatable script (in the spirit of
https://github.com/28allday/steamos-nvidia-installer, which this project has
referenced conceptually before but does not currently vendor a copy of —
searched `/srv/nvkvm-pv`, host filesystem, and shell history, found nothing;
if a local clone existed it's gone now). Requirements as given:

1. Build + install `nvkvm-guest.ko` against **the kernel version actually
   found in the target image** (read it from the image's
   `/usr/lib/modules/` rather than assuming/hardcoding a version — this
   session got lucky that the guest kernel headers already matched a
   pre-built `.ko`; a general script needs to build fresh per-image).
2. Install NVIDIA userspace via the official `.run` installer
   (`--no-kernel-modules --no-kernel-module-source --no-nouveau-check
   --no-x-check --no-rpms`, offline chroot — this part is proven, see
   above). The version is **derived from the host at build time by the
   script itself, then baked into the resulting image as a fixed version**
   — not re-detected on every boot. This session hand-hardcoded `595.84`
   because that's what the host happened to run when doing this by hand; a
   general script should derive it the same way (e.g.
   `nvidia-smi --query-gpu=driver_version --format=csv,noheader` on the
   host at image-build time) and write that resolved version into the
   image, with an override flag available for cross-version bring-up.
3. Ensure the desktop starts on nvkvm's plane, not VGA — this session's two
   fixes (`/etc/modprobe.d/99-nvkvm.conf`: `privileged_modeset=0`;
   `~/.config/environment.d/nvkvm.conf`: `KWIN_DRM_DEVICES=/dev/dri/card0`)
   are the concrete mechanism, proven to work fully automatically from a
   cold boot. Worth hardening before scripting it generally: `card0` is
   this image's *observed* nvkvm minor number, stable across every boot
   this session, but the project's own doc (`mint-guest-desktop.md`)
   explicitly warns not to select DRM nodes by index — select by walking
   `/sys/class/drm/card[0-9]*/device/driver` for `nvidia` instead of
   hardcoding `card0`, the way `run-session.sh` already does for weston.
4. **Open question, explicitly not verified this session — user asked to
   confirm later, not assumed**: does this repair image's own "Repair
   SteamOS Install" / "Wipe Device & Install SteamOS" flow work by `dd`-ing
   a base rootfs image to the real disk (in which case baking these fixes
   into the repair image's *own* rootfs would carry them into any resulting
   real install for free — the user's stated hope), or does it do a
   package-based reinstall from a repo (in which case the fixes would need
   to be re-applied post-install, or shipped as a package)? The repair
   image's login banner references `~/tools/repair_device.sh` and
   `steamos-readonly disable` — that script would be the place to look
   first. Not investigated this session (ran out of time; flagging instead
   of guessing).

If/when this becomes a script, the natural shape given everything proven
this session is: pristine `.img` in, offline `qemu-nbd` mount, kernel-version
probe, module build, `nvidia-installer` chroot run, the two config files
above, `qemu-img resize`, done — i.e. mechanize exactly the "Rebuilt the
guest image from scratch" recipe above, parameterized instead of hand-typed.
Not written this session; captured here so the next person (or agent) has
the proven steps to translate rather than rediscovering them.

### Goal 3 addendum — re-verified on the rebuilt image

Re-tested after the rebuild, same session: launched `gamescope -W 1280 -H
800 -- steam` with `HOME=/home/deck` (the real, persistent, 60G-free home,
not tmpfs). gamescope again selected the RTX 4070 and `Virtual-1` connector;
Steam's full process tree came up (11 `steamwebhelper` processes); `/home`
usage grew from 1.1G to 3.1G as Steam wrote its runtime/config there,
confirming persistent storage is actually being used, not just present.
Stops at the same unauthenticated sign-in screen as before — same blocker,
now on a clean, from-scratch image with both Goal 1 and Goal 2 baked in
rather than runtime-patched.

### Direct visual confirmation (physical screen, not inferred)

User confirmed on the physical PC's own screen, live: the full Plasma
desktop rendered in the QEMU SDL window first (matching the automatic,
zero-manual-steps boot described above), then — when `gamescope -- steam`
was launched afterward — the Steam sign-in screen **replaced** the Plasma
desktop in that same window (gamescope's fullscreen compositor taking over
the `Virtual-1` connector from KWin, both being nvkvm-rendered, consistent
with both compositors opening the same `/dev/dri/card0`). This is
independent, human-observed confirmation on real hardware, not inferred from
logs/fds/`nvidia-smi` alone — though it matches all of that evidence
exactly.
