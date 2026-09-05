#!/bin/bash
# x11_host_display_test.sh — an X11 host must be able to start the stack, and
# the Wayland escape must not spill onto the audio mounts.
#
# All four of the regressions below were live at once on 2026-09-05 and produced
# a single symptom on the operator's laptop -- "xcb_connect failed (DISPLAY=:1)"
# after a git pull -- which named none of them:
#
#   1. compose declared the Wayland socket mount with create_host_path:false
#      (correct: Docker used to CREATE a root-owned directory there, permanently
#      breaking every later run).  But that makes compose REFUSE to start on any
#      host with no Wayland session, and the documented escape was
#      NVKVM_DESKTOP_RUNTIME_DIR=/dev -- a variable that ALSO backs the PipeWire
#      and Pulse sources, which are short-form mounts.  It would have had Docker
#      create /dev/pipewire-0 and /dev/pulse/native and disabled guest audio.
#   2. the entrypoint's desktop-uid probe used -e, so it stat()ed whatever sat at
#      the socket path and trusted its owner.
#   3. the entrypoint exported WAYLAND_DISPLAY whenever it was set -- and compose
#      always sets it -- sending the broker into a wl_display_connect that could
#      not succeed on an X11 host.
#   4. run_steamos_nvkvm.sh defaulted DISPLAY to :0 twelve lines ABOVE its
#      backend detection, so the headless branch was unreachable.
#
# This test executes the Makefile and the boot script for real against stubs.
# It needs no Docker and no GPU.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$DIR/docker-compose.yml"
ENTRY="$DIR/docker/broker-entrypoint.sh"
BOOT="$DIR/boot/run_steamos_nvkvm.sh"
rc=0

command -v make >/dev/null || { echo "SKIP: make not available"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/rt" "$TMP/empty" "$TMP/work"
cat > "$TMP/bin/xhost" <<'SH'
#!/bin/sh
echo XHOST >> "$LOG"
exit "${XHOST_RC:-0}"
SH
cat > "$TMP/bin/docker" <<'SH'
#!/bin/sh
echo "DOCKER sock=${NVKVM_WAYLAND_SOCKET:-} rt=${NVKVM_DESKTOP_RUNTIME_DIR:-}" >> "$LOG"
exit 0
SH
cat > "$TMP/bin/qemu" <<'SH'
#!/bin/sh
echo "$*" > "$OUT"
exit 0
SH
chmod +x "$TMP/bin/xhost" "$TMP/bin/docker" "$TMP/bin/qemu"
cp "$DIR/Makefile" "$TMP/Makefile"
# A real AF_UNIX socket: -S must actually be true, so a plain file will not do.
python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" \
    "$TMP/rt/wayland-0" 2>/dev/null \
    || { echo "SKIP: cannot create a unix socket to test against"; exit 77; }

ok()   { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; rc=1; }

# ---------------------------------------------------------------- make up
# $1 description, $2 expected socket override, $3 expected xhost count, rest env
mk() {
    local desc="$1" want_sock="$2" want_xhost="$3"; shift 3
    : > "$TMP/log"
    env -i PATH="$TMP/bin:/usr/bin:/bin" LOG="$TMP/log" HOME="$TMP" \
        "$@" make -C "$TMP" up >/dev/null 2>&1
    local got_sock got_xhost
    got_sock="$(sed -n 's/^DOCKER sock=\([^ ]*\).*/\1/p' "$TMP/log" | head -1)"
    got_xhost="$(grep -c '^XHOST$' "$TMP/log")"
    if [ "$got_sock" = "$want_sock" ] && [ "$got_xhost" = "$want_xhost" ]; then
        ok "$desc"
    else
        bad "$desc (socket='$got_sock' want '$want_sock'; xhost=$got_xhost want $want_xhost)"
    fi
}

# A Wayland host must be left completely alone: no override, no xhost.
mk "make up: Wayland session is untouched" "" 0 \
   WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR="$TMP/rt"
# An X11 host must start unattended -- this is the regression.
mk "make up: X11 host escapes to /dev/null and grants xhost" /dev/null 1 \
   DISPLAY=:1 XDG_RUNTIME_DIR="$TMP/empty"
mk "make up: NVKVM_NO_XHOST=1 still escapes, grants nothing" /dev/null 0 \
   DISPLAY=:1 XDG_RUNTIME_DIR="$TMP/empty" NVKVM_NO_XHOST=1
# WAYLAND_DISPLAY set but the socket gone is the poisoned-host shape.
mk "make up: WAYLAND_DISPLAY set but socket absent still escapes" /dev/null 0 \
   WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR="$TMP/empty"

# A failing xhost must WARN, not abort: the stack is still worth starting, and
# the operator can run xhost by hand.
: > "$TMP/log"
env -i PATH="$TMP/bin:/usr/bin:/bin" LOG="$TMP/log" HOME="$TMP" XHOST_RC=1 \
    DISPLAY=:1 XDG_RUNTIME_DIR="$TMP/empty" make -C "$TMP" up >/dev/null 2>&1
if grep -q '^DOCKER' "$TMP/log"; then
    ok "make up: a failing xhost does not stop the stack"
else
    bad "make up: a failing xhost aborted the run"
fi

# ------------------------------------------------------------ compose mount
# The escape must be its OWN variable.  If this reverts to
# NVKVM_DESKTOP_RUNTIME_DIR, escaping the Wayland mount silently redirects the
# PipeWire and Pulse mounts too -- and those are short-form, so Docker creates
# them under /dev.
if grep -q 'source: \${NVKVM_WAYLAND_SOCKET' "$COMPOSE"; then
    ok "compose: the Wayland socket has a dedicated override"
else
    bad "compose: the Wayland mount no longer uses NVKVM_WAYLAND_SOCKET"
fi
if grep -q 'create_host_path: false' "$COMPOSE"; then
    ok "compose: Docker still may not invent the socket path"
else
    bad "compose: create_host_path:false is gone -- Docker will poison the host again"
fi
# The audio sources must keep their own variables, untouched by the escape.
if grep -q 'NVKVM_AUDIO_PW_SOCKET' "$COMPOSE" && grep -q 'NVKVM_AUDIO_PULSE_SOCKET' "$COMPOSE"; then
    ok "compose: audio sockets keep their own overrides"
else
    bad "compose: audio socket overrides changed -- re-check the /dev spill"
fi

# --------------------------------------------------------------- entrypoint
if grep -q '\[ -S "\$uid_probe" \]' "$ENTRY"; then
    ok "entrypoint: only a real socket speaks for the desktop uid"
else
    bad "entrypoint: uid probe no longer requires a socket (-S)"
fi
if grep -q 'unset WAYLAND_DISPLAY' "$ENTRY"; then
    ok "entrypoint: Wayland is not advertised without a socket"
else
    bad "entrypoint: auto may export WAYLAND_DISPLAY with no socket behind it"
fi
# The clipboard default must be resolved once and the LOCAL passed on: the bare
# variable is unset under `set -u` outside compose, and empty inside it.
if grep -q 'clipboard="\${NVKVM_BROKER_CLIPBOARD:-consent}"' "$ENTRY" \
   && ! grep -q -- '--clipboard "\$NVKVM_BROKER_CLIPBOARD"' "$ENTRY"; then
    ok "entrypoint: the clipboard default is resolved once"
else
    bad "entrypoint: the clipboard case head and body can disagree again"
fi

# -------------------------------------------------------------- boot script
: > "$TMP/work/OVMF_VARS.fd"
boot() {
    local desc="$1" want="$2"; shift 2
    local out
    out="$(env OUT="$TMP/qemu.args" QEMU="$TMP/bin/qemu" WORK="$TMP/work" \
             OVMF_VARS="$TMP/work/OVMF_VARS.fd" QCOW="$TMP/fake.qcow2" \
             SHARE="$TMP/share" "$@" bash "$BOOT" 2>&1)"
    if grep -q "detected: $want" <<<"$out"; then
        ok "$desc"
    else
        bad "$desc (wanted detected:$want, got: $(grep -o 'detected: [a-z0-9]*' <<<"$out" | head -1))"
    fi
}
boot "boot: a Wayland socket selects wayland" wayland \
     XDG_RUNTIME_DIR="$TMP/rt" WAYLAND_DISPLAY=wayland-0
boot "boot: a seat DISPLAY selects x11" x11 \
     XDG_RUNTIME_DIR="$TMP/empty" DISPLAY=:1
# The regression: DISPLAY is defaulted to :0 before the detection runs, so this
# case used to be unreachable and answered x11.
boot "boot: neither present keeps the historical wayland default" wayland \
     XDG_RUNTIME_DIR="$TMP/empty"

# The guest's SSH forward must never leave the host by default.
env OUT="$TMP/qemu.args" QEMU="$TMP/bin/qemu" WORK="$TMP/work" \
    OVMF_VARS="$TMP/work/OVMF_VARS.fd" QCOW="$TMP/fake.qcow2" SHARE="$TMP/share" \
    XDG_RUNTIME_DIR="$TMP/empty" DISPLAY=:1 bash "$BOOT" >/dev/null 2>&1
if grep -q 'hostfwd=tcp:127.0.0.1:15022-:22' "$TMP/qemu.args"; then
    ok "boot: the guest SSH forward binds loopback"
else
    bad "boot: the guest SSH forward is not on loopback: $(grep -o 'hostfwd=[^ ,]*' "$TMP/qemu.args" | head -1)"
fi

exit $rc
