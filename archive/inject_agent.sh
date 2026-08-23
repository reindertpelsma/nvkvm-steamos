#!/bin/bash
# inject_agent.sh — get a command-execution channel into the SteamOS repair-image
# guest, which has no sshd. Types agent.py in over the QEMU monitor's sendkey
# interface (base64-encoded, one line, decoded in-guest), starts it detached,
# and adds a hostfwd so the host can reach it over plain HTTP.
#
# Prerequisites:
#   - A getty login prompt must be the ACTIVE console (switch with e.g.
#     `echo "sendkey ctrl-alt-f4" | socat - UNIX-CONNECT:$MON`), and you must
#     already be logged in as `deck` (passwordless on this repair image) at
#     the shell prompt before running this script.
#   - MON must point at the running VM's monitor socket.
#
# Usage: MON=/root/steamos-nvkvm/mon.sock TYPE_SEND=/root/steamos-nvkvm/type_send.sh \
#        ./inject_agent.sh
set -euo pipefail
MON="${MON:-/root/steamos-nvkvm/mon.sock}"
TYPE_SEND="${TYPE_SEND:-/root/steamos-nvkvm/type_send.sh}"
AGENT_PY="${AGENT_PY:-/root/steamos-nvkvm/agent.py}"
HOSTFWD_PORT="${HOSTFWD_PORT:-15000}"

B64=$(base64 -w0 "$AGENT_PY")

echo "[*] Typing agent.py (base64, $(echo -n "$B64" | wc -c) chars) into the active console..."
"$TYPE_SEND" "echo '$B64' | base64 -d > /tmp/agent.py"

echo "[*] Starting the agent, detached from the controlling tty..."
"$TYPE_SEND" "setsid python3 /tmp/agent.py > /tmp/agent.log 2>&1 < /dev/null &"

echo "[*] Adding hostfwd tcp::$HOSTFWD_PORT -> guest:5000..."
echo "hostfwd_add net0 tcp::${HOSTFWD_PORT}-:5000" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1 || true

sleep 2
echo "[*] Testing..."
curl -s -m 10 -X POST --data-binary 'echo agent_alive' "http://127.0.0.1:${HOSTFWD_PORT}/" && echo "[+] Agent is up."
