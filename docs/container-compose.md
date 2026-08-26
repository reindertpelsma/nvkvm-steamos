# Two-container SteamOS deployment

This is the default deployment: one untrusted VMM container and one trusted
display-broker container. The VMM never receives the host X11 or Wayland
socket. The broker never receives `/dev/kvm`, the NVIDIA device, the SteamOS
disk, recovery image, source share, or SSH private key. Their only shared mount
is a 1 MiB tmpfs containing the broker Unix socket.

## Quick start

Prerequisites are Docker with the Compose plugin, `/dev/kvm`, a loaded NVIDIA
driver, and NVIDIA Container Toolkit. Run this from the logged-in graphical
user's X11 or Wayland session:

```sh
docker compose build
docker compose up -d
```

The first start downloads the pinned SteamOS recovery image, caches Alpine's
vmlinuz/initramfs/modloop, lets Valve's installer create a genuine dual-slot
A/B qcow2, installs NVIDIA userspace matching the dynamically detected host
driver, builds the nvkvm guest module, generates an SSH key, and boots Plasma.
Subsequent starts reuse all of that state.

The `nvkvm-source` named build context defaults to
`https://github.com/reindertpelsma/nvkvm-pv.git#main`. To build an explicitly
staged checkout instead:

```sh
NVKVM_CONTEXT=./nvkvm docker compose build
```

The parent context excludes `nvkvm/` like every other Git-ignored path, so a
local checkout cannot silently affect a default build. `NVKVM_CONTEXT` may also
name another Git URL/ref when testing a remote fork or review branch. No nvkvm
source is vendored in this repository.

Follow startup:

```sh
docker compose logs -f broker vmm
docker compose ps
```

## Published images and provenance

A pushed `v*` tag builds both runtime targets from scratch on a GitHub-hosted
Ubuntu 24.04 runner and publishes:

- `ghcr.io/reindertpelsma/nvkvm-steamos-vmm:<tag>`
- `ghcr.io/reindertpelsma/nvkvm-steamos-broker:<tag>`

Stable tags also update `latest`; prerelease tags containing `-` do not. Each
image is smoke-tested by digest before its GitHub OIDC provenance attestation
is attached in GHCR. Verify them with:

```sh
gh attestation verify \
  oci://ghcr.io/reindertpelsma/nvkvm-steamos-vmm:<tag> \
  --repo reindertpelsma/nvkvm-steamos
gh attestation verify \
  oci://ghcr.io/reindertpelsma/nvkvm-steamos-broker:<tag> \
  --repo reindertpelsma/nvkvm-steamos
```

The broker auto-selects Wayland when the configured Wayland socket exists,
otherwise X11. It reads the owner of the mounted desktop runtime directory,
drops to that uid/gid, and then executes the broker with no effective
capabilities and `no_new_privs`. Set `NVKVM_BROKER_BACKEND=wayland` or `x11` to
make selection explicit. `CTRL+ALT+G` toggles the input grab.

`CAP_SETUID`/`CAP_SETGID` are the sole exception: they stay *inheritable* across
that first `setpriv` so the broker can drop a second time once its window is up.
`NVKVM_BROKER_DROP_UID` (empty by default, meaning `--drop-user auto`) makes the
broker become an unowned uid after the display connection exists, keeping the
window and input it already holds while losing all reach into the desktop user's
files. It picks the uid itself because only it can read `/proc/self/uid_map`,
which matters under `dockerd --userns-remap` or sysbox-runc; pin a number to
override. It clears the whole capability set immediately after the transition.

## SSH and shared data

SSH is published only on host loopback. The shortest route is:

```sh
./steamos-ssh
# equivalent:
make ssh
```

Extra arguments are a guest command, for example:

```sh
./steamos-ssh nvidia-smi -L
./steamos-ssh sh -lc 'pgrep -a "kwin_wayland|plasmashell"'
```

The private key stays in the state volume. Its public half is installed for
root and the interactive SteamOS account through the separate data share.
Password authentication remains disabled.

Guest `~/data` is a named volume by default. To bind a host directory instead:

```sh
NVKVM_STEAMOS_DATA="$HOME/SteamOS-data" docker compose up -d
```

Keep that variable set on later Compose commands so Compose continues using
the same source.

## Durable and ephemeral state

| mount | lifetime | contents |
|---|---|---|
| `nvkvm-steamos-state` | persistent | qcow2, compressed and expanded recovery image, Alpine kernel/initramfs/modloop, OVMF vars, logs, SSH private key |
| `nvkvm-steamos-data` or `NVKVM_STEAMOS_DATA` | persistent | guest `~/data`, public SSH keys |
| `nvkvm-steamos-broker-socket` | tmpfs | `steamos.sock` only |

The socket is a tmpfs-backed named volume so both containers see a replacement
inode after broker restart. Binding the socket file itself would strand the VMM
on an unconnected old inode.

## Security boundary

The VMM root filesystem is read-only and receives no display-server mount. It
drops every container capability and restores only `SETUID`, `SETGID`,
`SETPCAP`, and `SYS_CHROOT`. Those four are not general convenience grants:
they are required for nvkvm's per-isolate uid separation, bounding-set drop,
and chroot. `NVKVM_ISOLATE_MODE=uid+chroot` is explicit, so missing authority
is a startup failure rather than a silent fallback to seccomp-only.

Docker's built-in seccomp allowlist remains active for the VMM. Each nvkvm
isolate additionally installs nvkvm's 20-syscall TSYNC filter after loading its
ELF and before processing guest requests. `no-new-privileges` is set at the
container boundary and again by the isolate.

The broker's socket is mode 0666 only inside the private shared tmpfs; this
avoids hardcoding a desktop group number on a fresh PC. The broker still checks
kernel-supplied `SO_PEERCRED` and admits only uid 0, which is the VMM's uid in
its container. No unrelated container has the socket volume mounted.

You can inspect the resolved policy without starting anything:

```sh
bash tests/compose_policy_test.sh
docker compose config
```

## Configuration

Common overrides:

| variable | default | purpose |
|---|---|---|
| `NVKVM_CONTEXT` | public nvkvm-pv `main` | named build context: Git URL/ref or explicit local checkout |
| `STEAMOS_VM_MEM` | `12G` | guest RAM |
| `STEAMOS_VM_SMP` | `8` | guest vCPUs |
| `NVKVM_STEAMOS_DISK_SIZE` | `64G` | sparse SteamOS disk and games budget |
| `NVKVM_STEAMOS_HOST_SSH_PORT` | `15022` | loopback SSH port |
| `NVKVM_STEAMOS_DATA` | named volume | optional host data bind mount |
| `NVKVM_BROKER_SIZE` | `1280x800` | initial broker window size |
| `NVKVM_BROKER_FULLSCREEN` | `0` | start broker fullscreen when set to `1` |
| `NVKVM_BROKER_LINEAR_ONLY` | `0` | `1` advertises only LINEAR, forcing the VMM's readback path |
| `NVKVM_BROKER_PRESENT_MODE` | empty (`auto`) | `auto`, `native`, `linear` or `shm`: which rung of the presentation ladder to offer |
| `NVKVM_BROKER_DROP_UID` | empty (`auto`) | uid the broker becomes after its window is up; empty lets the broker pick an unowned one |

The NVIDIA driver version is intentionally not a configuration value. The VMM
container reads the version supplied by NVIDIA Container Toolkit from
`/proc/driver/nvidia/version`, passes it into the disposable Alpine installer,
and the boot script later rechecks the version nvkvm exposes to SteamOS.
