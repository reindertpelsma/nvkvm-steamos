#!/usr/bin/env bash
# gamescope_start_timeout_test.sh — the SECOND gamescope deadline.
#
# Widening the readiness read inside /usr/lib/steamos/gamescope-session removes
# the FIFO deadlock, but gamescope-session.service ships Type=notify with
# TimeoutStartSec=5 and gamescope must still SIGNAL ready inside it.  The
# fastest cycle measured here came ready in 4s, so the margin is one second and
# a slower host loses it:
#
#     gamescope-session.service: start operation timed out. Terminating.
#     A dependency job for gamescope-session.target failed.
#
# SDDM then exits 1/FAILURE, which looks like a broken display manager rather
# than a timer -- reported by two users on GTX 3060 hosts.  This fixup is
# therefore load-bearing and invisible, so guard it.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
rc=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1"; rc=1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

export NVKVM_STEAMOS_BOOT_SOURCE_ONLY=1
# shellcheck source=../boot/steamos_boot.sh
source "$BOOT" || { echo "SKIP: cannot source $BOOT"; exit 77; }

CONF=/etc/systemd/user/gamescope-session.service.d/10-nvkvm-start-timeout.conf
EXPECTED=$'[Service]\nTimeoutStartSec=120'
fresh() { ROOT="$TMP/root"; rm -rf "$ROOT"; mkdir -p "$ROOT"; }

fresh
LOGS="$(ensure_gamescope_start_timeout 2>&1 >/dev/null)"
[ -f "$ROOT$CONF" ] && ok "writes the drop-in" || bad "no drop-in at $CONF"
[ "$(cat "$ROOT$CONF" 2>/dev/null)" = "$EXPECTED" ] \
    && ok "content is exactly [Service] + TimeoutStartSec=120" \
    || bad "unexpected content: $(cat "$ROOT$CONF" 2>/dev/null)"
grep -q '^\[Service\]$' "$ROOT$CONF" 2>/dev/null \
    && ok "has a [Service] section (systemd ignores the file otherwise)" \
    || bad "no [Service] section, so systemd would ignore it"
# The whole point is that it must exceed the ~4s-to-ready measurement with room.
v="$(sed -n 's/^TimeoutStartSec=//p' "$ROOT$CONF" 2>/dev/null)"
[ "${v:-0}" -ge 60 ] 2>/dev/null \
    && ok "the new deadline (${v}s) is far outside the racing range" \
    || bad "deadline ${v:-unset}s is too close to the 4-5s race this fixes"

before="$(cat "$ROOT$CONF")"
LOGS="$(ensure_gamescope_start_timeout 2>&1 >/dev/null)"
[ "$(cat "$ROOT$CONF")" = "$before" ] && ok "second convergence is byte-identical" \
                                      || bad "second convergence rewrote the file"
case "$LOGS" in *already*) ok "second convergence reports already-done" ;;
                *) bad "second convergence did not say already-done: $LOGS" ;; esac

fresh
LOGS="$(NVKVM_STEAMOS_KEEP_START_TIMEOUT=1 ensure_gamescope_start_timeout 2>&1 >/dev/null)"
[ ! -e "$ROOT$CONF" ] && ok "NVKVM_STEAMOS_KEEP_START_TIMEOUT=1 writes nothing" \
                      || bad "escape hatch still wrote the drop-in"

fresh
mkdir -p "$ROOT/etc/systemd/user"
: > "$ROOT/etc/systemd/user/gamescope-session.service.d"   # file where the dir goes
LOGS="$(ensure_gamescope_start_timeout 2>&1 >/dev/null)"
case "$LOGS" in *WARNING*) ok "an unwritable path warns rather than failing silently" ;;
                *) bad "unwritable path was silent: $LOGS" ;; esac

grep -qE '^\s*ensure_gamescope_start_timeout\s*$' "$BOOT" \
    && ok "wired into convergence" || bad "defined but never called"
# Both halves are needed; neither alone fixes a slow host.
grep -qE '^\s*ensure_gamescope_ready_timeout\s*$' "$BOOT" \
    && ok "the readiness-read fixup is still called alongside it" \
    || bad "the readiness fixup call vanished; this fix alone is not enough"

exit $rc
