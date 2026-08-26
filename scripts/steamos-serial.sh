#!/usr/bin/env bash
# Attach an interactive terminal to the SteamOS VM's serial console.
#
#   docker compose exec steamos nvkvm-steamos-serial
#
# This is the console that still answers when SSH does not: a wedged network,
# a guest that never reached multi-user, an initramfs prompt, the bootloader.
# It is the same chardev QEMU logs to $STATE_DIR/serial.log, so what you read
# here and what `docker logs` shows are the same stream -- the difference is
# that this one also carries your keystrokes back.
#
# Detach with CTRL-] (socat's escape).  Detaching leaves the guest untouched;
# it is not a logout, and the getty stays as you left it -- so log out first if
# you care.
set -euo pipefail
STATE_DIR="${NVKVM_STEAMOS_STATE_DIR:-/var/lib/nvkvm-steamos}"
SOCK="${NVKVM_STEAMOS_SERIAL_SOCK:-$STATE_DIR/serial.sock}"

command -v socat >/dev/null 2>&1 || {
    echo "socat is not installed in this image; cannot attach to $SOCK." >&2
    exit 1
}
[ -S "$SOCK" ] || {
    echo "No serial socket at $SOCK." >&2
    echo "The VM is not running, or this image predates the serial-socket" >&2
    echo "change (it used to be a write-only -serial file:)." >&2
    exit 1
}

echo "Attaching to $SOCK -- press ENTER for a prompt, CTRL-] to detach." >&2
# raw + echo=0: the guest's getty does its own line editing and echoing, and
# doing it twice gives doubled characters and no working backspace.
exec socat -,raw,echo=0,escape=0x1d "unix-connect:$SOCK"
