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
