# Physical PC — final evidence capture, 2026-08-28

Captured because the machine may become unavailable. Everything here is
irreproducible without that host.

## The headline: the GPU VA-space leak is NOT inherent to running a guest

`boot-table.txt` plus the per-boot counts of `can't alloc VA space`:

| boot | window | duration | VA-exhaustion events |
|---|---|---|---|
| **-3** | Aug 27 17:36 → Aug 28 02:50 | ~9 h | **0** |
| -2 | Aug 28 16:46 → 16:54 | 8 min | **19,321** |
| -1 | Aug 28 16:54 → 18:23 | 89 min | **31,805** |

**Boot -3 contains the two-hour Shadow of the Tomb Raider session** — sustained
80% GPU, 168 W, 3760x2118, plus a full SteamOS install and the QEMU 9.2.0 ->
11.1.1 rebuild — and leaked NOTHING. Two boots later, 19,321 events in eight
minutes.

So the leak was INTRODUCED between those boots, not by ordinary guest
operation. Whatever changed on this host in that window is the lead. Candidates,
none confirmed: nvkvm-kata was installed (its Docker bind-mounts created two
`/etc/vulkan/*.json` paths as DIRECTORIES, since removed), Kata GPU containers
ran concurrently with the VM, and `nvidia-cdi-refresh` began publishing a
daemon-side CDI spec.

## What the leak does

- `NVRM: dmaAllocMapping_GM107: can't alloc VA space for mapping` +
  `NV_ERR_NO_MEMORY` from `reusemappingdbMap()`.
- Once started, `vkCreateDevice` fails with `ERROR_INITIALIZATION_FAILED` for
  every Vulkan client on the HOST and in the guest. The guest's KWin dies with
  `GL_OUT_OF_MEMORY` and never enables its DRM output.
- **Survives everything**: stopping the guest, every `nvkvm_stub` exiting, zero
  containers. Only a reboot clears it.
- **`nvidia-smi` shows nothing wrong throughout** — 333 MiB used, 0%, 43C, no
  Xid. Address space is not memory, and nothing surfaces it.
- Not the present path: the leaking run produced ZERO flips.

## Files

| file | what |
|---|---|
| `boot-table.txt` | journalctl --list-boots, the table above |
| `va-evidence.txt` | boot -1: 76,591 lines of NVRM/VA output |
| `va-boot-2.txt` | boot -2: first 400 NVRM/VA lines |
| `nvrm-boot-3-clean.txt` | boot -3 NVRM lines — the CLEAN control |
| `pc-dmesg.txt` | dmesg after the clearing reboot (boot 0) |
| `pc-nvidia-smi-q.txt` | full `nvidia-smi -q` |
| `pc-uname.txt` | kernel 7.0.0-30-generic |
| `vmm-final.log` / `broker-final.log` | last container logs |
| `install-final.log` | last SteamOS install transcript |
| `pc-backup.tgz` | kata-install-notes.md (host change/undo list), DRM-disabled capture, mint launchers, guest journals |

## Host

RTX 4070, driver 595.84 **open kernel module**, Ryzen 9 7900, kernel
7.0.0-30-generic, Ubuntu. nvkvm-kata was installed here (see
`kata-install-notes.md` inside the tarball for the full change and undo list).

## If the machine is gone

The leak has only ever been observed on this host. Reproducing it elsewhere
needs a GPU box with `/dev/kvm`, an nvkvm guest left running for ~10+ minutes,
and `journalctl -k | grep -c "alloc VA space"` sampled over time. The boot -3
control says a plain guest does NOT leak, so a reproduction attempt should
include whatever else this host had — Kata, concurrent GPU containers,
daemon-side CDI.
