# archive/ — superseded, kept for reference

Nothing here is on the supported path. `boot/steamos_boot.sh` replaced all of
it — see [`../README.md`](../README.md) for what is current and
[`../TUTORIAL.md`](../TUTORIAL.md) for how to reproduce it.
Kept because the notes and evidence elsewhere in this repo reference these by
name, and because each records a problem that had to be solved before the boot
script existed.

| file | what it did | why it is superseded |
|---|---|---|
| `install_nvkvm_userspace.sh` | hand-picked NVIDIA userspace libs into the image | `steamos_boot.sh` installs the real `.run` matching `/proc/driver/nvidia/version`, and gets every lib the hand-rolled list missed (glsi, tls, glcore, libcuda, libGLX_nvidia, the EGL vendor JSON) |
| `agent.py`, `inject_agent.sh`, `type_send.sh` | typed a command channel into the guest over the QEMU monitor's `sendkey`, because the repair image has no sshd | `steamos_boot.sh` provisions sshd when `data/authorized_keys` exists. It also needed a getty prompt already active with `deck` logged in, so it was never usable unattended |

`inject_agent.sh` is still the only way to reach a guest that has no sshd and no
serial console, so it is worth knowing it exists. It is not part of the install
flow.
