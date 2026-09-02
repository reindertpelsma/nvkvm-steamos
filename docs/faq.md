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

- **Containers** are not a VM. You cannot boot a full OS inside one the way you
  can on bare metal or KVM, which is the whole point here.
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

**Does Steam delete my games on every launch?**
Not here, but it would without a fix, and it is worth knowing why. Valve's
official download button gives you an **OOBE image**
(`steamdeck-oobe-repair-*.img`) — that is what this project installs, because it
is the current, maintained one — and its `/usr/bin/steam` runs

```
rm -rf --one-file-system "$HOME"/.steam "$HOME"/.local/share/Steam
```

**unconditionally on every launch** — login, library index and installed games.
Valve's own comment explains it: *"On OOBE images we want to always start with a
fresh steam per boot as we lack the proper steam overlay/repair code."* That is
fine for the handful of boots before a real Steam Deck's first update graduates
it to normal SteamOS; it is catastrophic on a machine anyone actually uses.

Provisioning detects this and disables that line, so **your data is safe**. But an
OOBE image genuinely lacks Steam's repair machinery, so a Steam install that does
break will not self-heal. To move to real SteamOS, run inside the guest:

```sh
sudo steamos-update      # several GB; reboots into the other A/B slot
```

After that the guest is `VARIANT_ID=steamdeck` with the normal launcher, and our
patch stops applying by itself.

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
