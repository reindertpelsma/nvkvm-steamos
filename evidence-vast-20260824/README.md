# evidence-vast-20260824 — `build_steamos_image.sh`, end to end

Rig: **vast.ai desktop-VM KVM instance**, RTX 4090, host driver **570.133.20**,
30 vCPU / 98 GB, Ubuntu 22.04 host, real `/dev/kvm` (nested). Image:
`steamdeck-oobe-repair-20260707.10-3.8.14`, kernel
`6.16.12-valve24.4-1-neptune-616-gfe145653a794`.

What was run:

```sh
build_steamos_image.sh --src steamdeck-oobe-repair-20260707.10-3.8.14.img \
                       --share /root/nvkvm-pv \
                       --nvidia-run NVIDIA-Linux-x86_64-570.133.20.run
```

with this repo's `boot/` copied into the `nvkvm-pv` checkout (the public
`nvkvm-pv` does not carry `boot/` — see the note in `../boot/TESTING.md`).
Wall time **1m48s**, including the module build and the NVIDIA install.

| file | what |
|---|---|
| `build-tail.txt` | the tail of a full build, through `Part 1 finished (rc=0)` and the image verification |
| `guest-serial-nvkvm.txt` | the produced image booting under **stock** QEMU 6.2 + OVMF, serial console. OVMF loads from the NVMe (so the relocated GPT is good), the planted `nvkvm-boot.service` runs, `nvkvm-recovery.sh` mounts the real 9p share and hands over, and Part 1 converges to `rc=0` on the live system with `module up to date at 252bd44…` |
| `guest-oops.txt` | a **kernel NULL pointer dereference in `nvkvm_send_sync`**, triggered by `ksplashqml` opening the device. Not a fault of the image: this box has no nvkvm virtio device, and `/etc/modules-load.d/nvkvm.conf` loads the guest module anyway. See below. |

## The oops is an nvkvm-pv finding, and it is reproducible

`nvkvm-guest` loads on a machine with **no `virtio-nvgpu`/`nvkvm-gpu` device**,
logs `nvkvm: host GPU discovery failed (-12); assuming 1`, and then NULL-derefs
on the **first open** of its character device:

```
BUG: kernel NULL pointer dereference, address: 0000000000000000
RIP: 0010:nvkvm_send_sync+0xeb/0x240 [nvkvm_guest]
Call Trace:
  simple_req -> nvkvm_virtio_create_isolate -> nvkvm_fd_ctx_open_dev -> nvkvm_open
Comm: ksplashqml
```

Because the image force-loads the module at boot, **any** boot of a provisioned
image on a QEMU without nvkvm's devices oopses as soon as the desktop session
touches the driver — which presents as a black screen with a live cursor, and
then as sshd going unresponsive. Failing the open cleanly when discovery
returned `-12` would make an unsupported QEMU merely useless instead of fatal.

Related, and smaller: `validate()` reported **`validation OK`** on that same
boot. It checks that `/dev/nvidiactl` exists and that `libGLX_nvidia` and the
Vulkan ICD are present — all true here — so it greens a system whose module
oopses on every open.

## What this rig does NOT show

No nvkvm-patched QEMU was built here, so nothing about presentation was
exercised: no `virtio-nvgpu`, no `nvkvm-gpu`, no GL zero-copy, no game. For
those, see [`../evidence-pc-20260823/`](../evidence-pc-20260823/) (bare metal,
RTX 4070).
