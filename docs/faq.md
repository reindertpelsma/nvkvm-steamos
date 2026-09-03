# FAQ

Everything people ask about the SteamOS deployment. Measured results and open
gaps live in [`status.md`](status.md); the runtime/deployment path is in
[`container-compose.md`](container-compose.md).

**Is this a VFIO utility that binds the GPU to a VM?**
No. There is no VFIO and no real GPU device is bound to the VM. Your host GPU is
genuinely shared with the guest, similar to CUDA containers. The VM gets access to
your GPU for graphics and compute; the host keeps using it throughout.

**Why nvkvm and not Containers, VFIO, vGPU, VirtIO-gpu, GPU PV?**
Each of the alternatives fails on a different axis:

- **Containers** are not a VM: you cannot boot a full OS in one. There is also a
  hard compatibility problem. Steam's own runtime is already a container
  (pressure-vessel, on bubblewrap) and must create a user namespace, which
  Docker's default seccomp profile denies -- so containerised Steam only runs
  once you weaken the outer container (`docker-steam-headless` ships
  `CAP_SYS_ADMIN`, `seccomp:unconfined`, `ipc: host`, `network_mode: host`).
  Sysbox, built for that nesting problem, supports neither nested user
  namespaces nor GPU passthrough. A VM has no such conflict, which is why our
  own containers keep `cap_drop: ALL`.
- **VFIO** takes the GPU away from the host. If your display output is on that
  card, your host desktop goes with it -- the guest has seized the device.
- **vGPU** is datacenter-only and licensed. `vgpu_unlock` re-enables legacy
  paths on some consumer cards, but it is unreliable, has no open-source
  Ampere support, and still does not forward your display zero-copy. On
  Blackwell it is unavailable: GSP is mandatory and the legacy sharing paths
  are gone.
- **virtio-gpu** in stock QEMU is limited and gives you neither CUDA nor native
  Vulkan in the guest.
- **GPU PV** is Microsoft's, and needs a Windows host. NVIDIA's Linux
  equivalent is vGPU, which is commercially gated -- see above.

**Will my GPU work?**
NVIDIA only, Turing (GTX 16xx / RTX 20xx) or newer. Six architectures are tested,
from GTX 1660 to H100 — see the tested-platforms table in nvkvm-pv. Pascal and
older do not work.

**How much of my GPU does the VM get?**
VRAM and CUDA cores are shared, as in CUDA containers. When the VMM runs in a
container it can only reach what that container was provisioned with.

**How do I go fullscreen, or make my in-game character follow the mouse?**
`CTRL+ALT+F` toggles fullscreen. `CTRL+ALT+G` toggles grab mode, which hands your
keyboard and mouse to the guest until you press it again. Most first- and
third-person games need grab mode, because it delivers real relative mouse motion
(dx/dy) instead of absolute coordinates over the guest window.

**Will my GPU driver work?**
Only the host driver matters. The guest automatically installs the CUDA userspace
matching whatever driver the host runs. Only NVIDIA's official kernel driver is
supported ([open-gpu-kernel-modules](https://github.com/nvidia/open-gpu-kernel-modules));
most distributions preinstall it for Turing and newer. Nouveau is not supported.
nvkvm-pv tracks 216 OGKM tags for ABI, so a wide range of driver versions works,
though not all are equally well tested — see the support matrix in nvkvm-pv.

**Will the VM break when my host driver updates?**
No. At boot the guest asks nvkvm for the host driver version, and on a mismatch it
installs the official NVIDIA runfile for that version before continuing. Your
guest follows your host automatically.

**Does it survive SteamOS updates?**
Yes. During an A/B update the boot script reprovisions the newly updated slot with
nvkvm, libcuda and the CUDA/Vulkan libraries.

**Is headless supported?**
nvkvm-pv supports headless rendering desktops you can connect to remotely, but the
scripts in this repository are not configured for it.

**Which SteamOS images are supported?**
The current official recovery image, whichever that is on the day you install.
The installer resolves Valve's own `steamdeck-repair-latest` alias at install
time (today that is `steamdeck-oobe-repair-20260707.10-3.8.14`) and falls back to
a pinned known-good image only if the alias stops resolving.

Older **plain** `steamdeck-repair-*` images are not tracked. They are in one
sense nicer — they install `VARIANT_ID=steamdeck` directly, with
`steam-jupiter-stable` and none of the OOBE wiping wrapper — but the newest one
Valve published is 3.7.7 from May 2025 and it appears to have stopped being
republished. Following the official alias means we do not depend on a file Valve
may remove, at the cost of getting the OOBE variant. That trade is deliberate,
and it is why the previous answer exists.

You can still point `install_steamos_vm.sh --repair` at any image you like;
nothing rejects one. Only the image the alias resolves to is tested.

**Do I have to update before installing games?**
Yes. Run `sudo steamos-update` first, then install games.

This is SteamOS behaviour, not an nvkvm one. Valve's download button gives an **OOBE
image** (`steamdeck-oobe-repair-*.img`) -- the alias `steamdeck-repair-latest`
resolves to it, the non-OOBE alias 404s -- and on those images
`steam-jupiter-oobe`'s `/usr/bin/steam` runs
`rm -rf --one-file-system "$HOME"/.steam "$HOME"/.local/share/Steam` on every
launch, by design: *"we lack the proper steam overlay/repair code"*, says Valve's
own comment. Any bare-metal SteamOS machine still on an un-graduated OOBE image
does the same. Nobody normally meets it, because setup walks you into the update
before you have a library to lose.

It became reachable here because this project used to force Plasma autologin,
which skipped Valve's setup and parked the guest on an un-graduated image with a
usable desktop. That default is fixed -- first boot now lands in the OOBE
installer, as on bare metal. `NVKVM_STEAMOS_FORCE_PLASMA=1` puts you back outside
that flow, so update before installing anything if you set it. Provisioning also
neutralises the wipe while `VARIANT_ID` is `steamdeck-oobe`, and the patch
self-retires after an OTA.

Graduating *after* installing does not save your games: real SteamOS keeps the
same `rm -rf` behind a guard on `# OOBE Inhibit` in `Steam.cfg`, fires it once,
and backs up `registry.vdf` first -- so your login survives but
`~/.local/share/Steam`, which holds `steamapps`, does not.

**Will anti-cheat work?**
No, and this is a won't-fix. Anti-cheat generally breaks under VMs by design —
strict implementations deliberately require bare metal and full root access, often
via kernel modules. Games that depend on it cannot be meaningfully sandboxed; you
have to trust the vendor to have hardened the client against hostile servers and
players.

**Will DRM-protected games work?**
Most likely. DRM is far less strict than anti-cheat, and Steam authenticates your
account rather than the device.

**Where is my game data, and how do I get more disk space?**
In a qcow2 image containing two fixed-size read-only SteamOS partitions (the A/B
slots, which give atomic updates with fallback to the previous version if a boot
fails) and a home partition at the end holding your files and games, which can
grow. The Compose deployment sizes it to at least 64 GiB and at most 1024 GiB,
targeting 60% of the host's free space. If it is too small, resize the disk and
then the last partition.

**How do I copy and paste?**
Through vdagent (QEMU SPICE) when using the broker. Copy works while the window has
focus; paste requires explicit consent — press `CTRL+V` or `CTRL+SHIFT+V` while
focused, the same model Firefox and Safari use. Pasting from a right-click menu may
therefore not receive the host clipboard: press `CTRL+V` to send it, even if that
shortcut does nothing in the guest application itself.

**Is it safe to give the containers `/dev/kvm`?**
Yes, and it is not comparable to mounting the Docker socket. `/dev/kvm` is
designed for unprivileged use -- QEMU and libvirt run VMs as ordinary users,
and systemd ships the node world-accessible on that basis. Holding it is not
root-equivalent, and a privilege escalation through it would be a Linux kernel
vulnerability rather than a misconfiguration here. The Docker socket, by
contrast, *is* root-equivalent by design.

`/dev/udmabuf` is smaller and less exercised, but not alarming: ~550 lines,
three ioctls, one exploitable escalation in eight years, syzkaller descriptions
written for it, and no capability check has ever existed -- the dma-buf
maintainers signed off on unprivileged local access in 2024, which is why
systemd hands it to the logged-in desktop user. We still record it as an
accepted risk rather than neutral for one reason: it pins host memory no cgroup
accounts for. That is a denial of service on your own machine -- no code
execution, no data access, cleared by a reboot -- and it is granted only for the
zero-copy display path, so headless deployments never receive it at all.

Neither node is ever held by the guest. Both sit with the VMM and broker, so
reaching either needs an escape out of the VM first.

**What does this image weaken compared to nvkvm's defaults?**
Two things, both deliberate, both worth knowing:

- Every image sets `privileged_modeset=0` (`boot/steamos_boot.sh`), which lets
  any process in the guest open the primary DRM node — so an unprivileged guest
  process can drive **and capture** the guest's screen. On SteamOS this changes
  little in practice, because `deck` has passwordless sudo and could take the
  gate down anyway, but it is a real difference from nvkvm-pv's default and it
  was previously documented only as a functional step.
- The compose file pins `NVKVM_ISOLATE_MODE=uid+chroot`, which nvkvm's own docs
  describe as materially weaker than the namespace rung.

Neither affects the host boundary — they are both *inside* the guest. They
matter if you plan to run software in the guest that you do not trust, which is
covered by the next answer.

**Should I run this multi-tenant?**
No. Not because of a known flaw, but because nvkvm has had **no external
security review**. Treat the isolation as untested by anyone but us.

**Why are there three containers — vmm, broker and audio?**
Security, and it is not SteamOS-specific. For native performance the VMM needs the
guest's frames on your display; streaming them headlessly would add latency and
complexity. But mounting your Wayland or X11 socket into the VMM would grant it
full access to your display and every input — close to a host compromise. So the
broker runs in its own container and gives the VMM only the display *contents*,
and input only while the window has focus or grab mode is on. Zero-copy rendering
still works. The audio container applies the same principle to sound.

The effect: most QEMU or nvkvm breakouts land in an unprivileged CUDA container
with most capabilities stripped and nowhere to attach a keylogger. A breakout
through KVM into the host kernel is a far higher bar.

**What is the purpose of this project for nvkvm?**
It is primarily a demonstration of nvkvm's capabilities on a vendor OS that is
not standard Ubuntu, plus an excellent test target for running AAA titles under
nvkvm -- and it is useful in its own right to anyone who wants to run SteamOS in
a VM without giving up their NVIDIA GPU.
