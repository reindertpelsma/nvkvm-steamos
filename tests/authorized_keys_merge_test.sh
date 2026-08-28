#!/bin/bash
# authorized_keys_merge_test.sh — the boot script must ADD the data share's keys
# and REMOVE NOTHING.
#
# steamos_boot.sh re-runs on every boot, and /root and /home are on the
# PERSISTENT partition (they survive an A/B slot switch). It used to install
# authorized_keys with `cp -f`, so every hand-added key was wiped every boot --
# reported as "I have to constantly re-add my key at every boot".
#
# The share is a set of keys to ENSURE ARE PRESENT, not the authoritative
# contents of the file: a key removed from the share stays on the guest. Keeping
# what a human put there is worth more than tracking the share exactly.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
rc=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

OPERATOR='ssh-ed25519 AAAAOPERATORKEYBODY operator@laptop'
SHARE_A='ssh-ed25519 AAAASHAREKEYONEBODY container@nvkvm'
SHARE_B='ssh-ed25519 AAAASHAREKEYTWOBODY rotated@nvkvm'
# the SAME key as SHARE_A, different trailing comment -- what a re-generated
# host or a re-flashed container produces
SHARE_A_RECOMMENTED='ssh-ed25519 AAAASHAREKEYONEBODY container@nvkvm-rebuilt'

# the install step, as steamos_boot.sh performs it
install_keys() {  # <authorized_keys> <share file>
    local ak="$1" src="$2" _line _body _added=0
    touch "$ak"
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in ''|\#*) continue ;; esac
        _body="$(printf '%s\n' "$_line" | tr ' \t' '\n\n' | grep -m1 '^AAAA' || true)"
        if [ -n "$_body" ]; then
            grep -qF -- "$_body" "$ak" && continue
        else
            grep -qxF -- "$_line" "$ak" && continue
        fi
        printf '%s\n' "$_line" >> "$ak"
        _added=$((_added + 1))
    done < "$src"
    echo "$_added"
}

ak="$work/authorized_keys"
printf '%s\n' "$OPERATOR" > "$ak"           # operator adds a key by hand
printf '%s\n' "$SHARE_A"  > "$work/share"

install_keys "$ak" "$work/share" >/dev/null   # boot 1
install_keys "$ak" "$work/share" >/dev/null   # boot 2
install_keys "$ak" "$work/share" >/dev/null   # boot 3

grep -qF "$OPERATOR" "$ak" \
    && echo "ok: the operator's key survives repeated boots" \
    || { echo "FAIL: the operator's key was destroyed"; rc=1; }
[ "$(grep -c 'AAAASHAREKEYONEBODY' "$ak")" -eq 1 ] \
    && echo "ok: the share's key is present exactly once (idempotent)" \
    || { echo "FAIL: share key appears $(grep -c 'AAAASHAREKEYONEBODY' "$ak") times"; rc=1; }

# same key, different comment -- must NOT be appended again
printf '%s\n' "$SHARE_A_RECOMMENTED" > "$work/share"
install_keys "$ak" "$work/share" >/dev/null
[ "$(grep -c 'AAAASHAREKEYONEBODY' "$ak")" -eq 1 ] \
    && echo "ok: the same key with a new comment is not duplicated" \
    || { echo "FAIL: re-commented key was appended again -- the file will grow every boot"; rc=1; }

# a NEW key on the share is added, and the old one is KEPT (remove nothing)
printf '%s\n' "$SHARE_B" > "$work/share"
n="$(install_keys "$ak" "$work/share")"
grep -qF "$SHARE_B" "$ak" \
    && echo "ok: a new share key is added" \
    || { echo "FAIL: the new share key was not added"; rc=1; }
[ "$n" = 1 ] || { echo "FAIL: reported $n keys added, expected 1"; rc=1; }
grep -qF 'AAAASHAREKEYONEBODY' "$ak" \
    && echo "ok: a key dropped from the share is KEPT on the guest (removes nothing)" \
    || { echo "FAIL: removing a key from the share removed it from the guest"; rc=1; }
grep -qF "$OPERATOR" "$ak" \
    && echo "ok: the operator's key is still there at the end" \
    || { echo "FAIL: the operator's key was lost"; rc=1; }

# the regression itself
grep -qE 'cp -f "\$src" "\$h/\.ssh/authorized_keys"' "$BOOT" \
    && { echo "FAIL: steamos_boot.sh still overwrites authorized_keys with cp -f"; rc=1; } \
    || echo "ok: steamos_boot.sh no longer overwrites authorized_keys"

[ $rc -eq 0 ] && echo "PASS: share keys are ensured present; nothing is ever removed"
exit $rc
