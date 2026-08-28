#!/bin/bash
# authorized_keys_merge_test.sh — the boot script must not destroy keys the
# operator added by hand.
#
# steamos_boot.sh re-runs on every boot, and /root and /home are on the
# PERSISTENT partition (they survive an A/B slot switch). It used to install
# authorized_keys with `cp -f`, so every hand-added key was wiped every boot --
# reported as "I have to constantly re-add my key at every boot".
#
# The managed keys still have to track the data share exactly: a key removed
# from the share must disappear from the guest. So this is a marked-block merge,
# and both halves are asserted here.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
rc=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

OPERATOR='ssh-ed25519 AAAAOPERATORKEY operator@laptop'
SHARE_A='ssh-ed25519 AAAASHAREKEYONE container@nvkvm'
SHARE_B='ssh-ed25519 AAAASHAREKEYTWO rotated@nvkvm'

# the merge, lifted from steamos_boot.sh's _install_authkeys
merge() {  # <authorized_keys> <share file>
    local h="$1" src="$2"
    {
        if [ -f "$h" ]; then
            sed '/^# BEGIN nvkvm-managed$/,/^# END nvkvm-managed$/d' "$h"
        fi
        echo "# BEGIN nvkvm-managed"
        cat "$src"
        echo "# END nvkvm-managed"
    } > "$h.new"
    mv -f "$h.new" "$h"
}

ak="$work/authorized_keys"
printf '%s\n' "$OPERATOR" > "$ak"          # operator adds a key by hand
printf '%s\n' "$SHARE_A"  > "$work/share"

merge "$ak" "$work/share"                   # boot 1
merge "$ak" "$work/share"                   # boot 2 -- must be idempotent

if grep -qF "$OPERATOR" "$ak"; then
    echo "ok: the operator's key survives repeated boots"
else
    echo "FAIL: the operator's key was destroyed"; rc=1
fi
if [ "$(grep -c '^# BEGIN nvkvm-managed$' "$ak")" -eq 1 ]; then
    echo "ok: exactly one managed block after two runs (idempotent)"
else
    echo "FAIL: managed blocks accumulate: $(grep -c '^# BEGIN nvkvm-managed$' "$ak")"; rc=1
fi

# the share rotates: the old managed key must GO, the operator's must stay
printf '%s\n' "$SHARE_B" > "$work/share"
merge "$ak" "$work/share"
if grep -qF "$SHARE_B" "$ak" && ! grep -qF "$SHARE_A" "$ak"; then
    echo "ok: managed keys still track the data share exactly"
else
    echo "FAIL: rotating the share did not replace the managed key"; rc=1
fi
if grep -qF "$OPERATOR" "$ak"; then
    echo "ok: operator key still present after a share rotation"
else
    echo "FAIL: share rotation destroyed the operator's key"; rc=1
fi

# and the regression itself: no plain overwrite of authorized_keys in boot.sh
if grep -qE 'cp -f "\$src" "\$h/\.ssh/authorized_keys"' "$BOOT"; then
    echo "FAIL: steamos_boot.sh still overwrites authorized_keys with cp -f"; rc=1
else
    echo "ok: steamos_boot.sh no longer overwrites authorized_keys"
fi

[ $rc -eq 0 ] && echo "PASS: hand-added keys survive; managed keys track the share"
exit $rc
