#!/usr/bin/env bash
# Assert the privilege-separation contract after Compose interpolation. Grep on
# docker-compose.yml is insufficient: defaults and short volume syntax can
# resolve to something different from what the source appears to say.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$(mktemp)"
BIND_CONFIG="$(mktemp)"
trap 'rm -f "$CONFIG" "$BIND_CONFIG"' EXIT

docker compose -f "$ROOT/docker-compose.yml" config --format json > "$CONFIG"

python3 - "$CONFIG" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    cfg = json.load(fh)

services = cfg["services"]
assert set(services) == {"broker", "vmm"}, set(services)
broker = services["broker"]
vmm = services["vmm"]

assert set(vmm["cap_drop"]) == {"ALL"}
assert set(vmm["cap_add"]) == {"SETUID", "SETGID", "SETPCAP", "SYS_CHROOT"}
assert vmm["security_opt"] == ["no-new-privileges:true"]
assert vmm["environment"]["NVKVM_ISOLATE_MODE"] == "uid+chroot"
assert not ({"DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY"} & set(vmm["environment"]))
assert vmm["read_only"] is True
assert {d["source"] for d in vmm["devices"]} == {"/dev/kvm"}

assert set(broker["cap_drop"]) == {"ALL"}
assert set(broker["cap_add"]) == {"SETUID", "SETGID"}
assert broker["security_opt"] == ["no-new-privileges:true"]
assert broker["network_mode"] == "none"
assert broker["read_only"] is True
assert not broker.get("devices")
assert not broker.get("deploy")

def mounts(service):
    return {v["target"]: (v["type"], v["source"]) for v in service["volumes"]}

bm = mounts(broker)
vm = mounts(vmm)
assert "/run/host-runtime" in bm and "/tmp/.X11-unix" in bm
assert "/run/host-runtime" not in vm and "/tmp/.X11-unix" not in vm
assert bm["/run/nvkvm"] == ("volume", "broker-socket")
assert vm["/run/nvkvm"] == ("volume", "broker-socket")
assert vm["/var/lib/nvkvm-steamos"] == ("volume", "steamos-state")
assert vm["/data"] == ("volume", "steamos-data")

socket_volume = cfg["volumes"]["broker-socket"]
assert socket_volume["driver"] == "local"
assert socket_volume["driver_opts"]["type"] == "tmpfs"
assert "noexec" in socket_volume["driver_opts"]["o"]

ports = vmm["ports"]
assert len(ports) == 1
assert ports[0]["host_ip"] == "127.0.0.1"
assert ports[0]["target"] == 15022

print("compose_policy_test: PASS")
PY

# The optional data mount must actually resolve as a bind when the operator
# supplies a path, not merely look plausible in Compose's short syntax.
NVKVM_STEAMOS_DATA="$ROOT" \
    docker compose -f "$ROOT/docker-compose.yml" config --format json > "$BIND_CONFIG"
python3 - "$BIND_CONFIG" "$ROOT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    cfg = json.load(fh)
data = next(v for v in cfg["services"]["vmm"]["volumes"] if v["target"] == "/data")
assert data["type"] == "bind", data
assert data["source"] == sys.argv[2], data
PY

# The standalone repository owns SteamOS policy but not nvkvm itself. Pin the
# required fallback contract: absent ./nvkvm, build from the public main branch.
grep -qF 'ARG NVKVM_REPOSITORY=https://github.com/reindertpelsma/nvkvm-pv.git' \
    "$ROOT/Dockerfile"
grep -qF 'ARG NVKVM_REF=main' "$ROOT/Dockerfile"
grep -qF 'nvkvm/scripts/build_qemu.sh' "$ROOT/Dockerfile"
# Broker restart briefly activates QEMU's local fallback while the relay
# reconnects. libepoxy aborts the VMM if neither libGL nor libOpenGL exists.
grep -qF 'libegl1 libgl1' "$ROOT/Dockerfile"
