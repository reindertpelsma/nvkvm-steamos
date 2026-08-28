#!/bin/bash
# keyring_trust_test.sh — the keyring readiness check must test TRUST, not the
# mere presence of keys.
#
# A freshly written SteamOS A/B slot ships a keyring with ~98 keys, none of them
# locally signed. The old check was `pacman-key --list-keys && return 0`, which
# succeeds on any non-empty keyring, so provisioning skipped the populate step
# and every package install then failed:
#
#   error: spice-vdagent: signature from "GitLab CI Package Builder" is unknown trust
#
# That took out the kernel headers too, so the guest module could not be built,
# and the failure was misreported downstream as a vermagic mismatch.
#
# gpg reports usable keys as full (f) or ultimate (u) validity on the uid.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
rc=0

# the predicate steamos_boot.sh uses, applied to captured gpg colon output
trusted() { grep -q '^uid:[fu]:' "$1"; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# A fresh slot: many keys, none locally signed. Validity codes seen on a real
# post-OTA slot were -, e, m, q, r -- never f or u.
cat > "$work/untrusted" <<'EOF'
uid:-::::::::GitLab CI Package Builder <ci-package-builder-1@steamos.cloud>:
uid:m::::::::Some Arch Developer <dev@archlinux.org>:
uid:e::::::::An Expired Key <old@example.org>:
uid:q::::::::Undefined Trust <q@example.org>:
uid:r::::::::Revoked <r@example.org>:
EOF
# After pacman-key --populate: locally signed, so full/ultimate appear.
cat > "$work/trusted" <<'EOF'
uid:-::::::::Still Unsigned <x@example.org>:
uid:f::::::::GitLab CI Package Builder <ci-package-builder-1@steamos.cloud>:
uid:u::::::::Pacman Keyring Master Key <pacman@localhost>:
EOF

if trusted "$work/untrusted"; then
    echo "FAIL: an unsigned keyring was reported as trusted"; rc=1
else
    echo "ok: a keyring with keys but no local signatures is NOT trusted"
fi
if trusted "$work/trusted"; then
    echo "ok: a populated keyring is trusted"
else
    echo "FAIL: a populated keyring was not recognised as trusted"; rc=1
fi

# marginal alone must not qualify -- it is why the real slot still failed
printf 'uid:m::::::::Marginal Only <m@example.org>:\n' > "$work/marginal"
if trusted "$work/marginal"; then
    echo "FAIL: marginal-only trust accepted"; rc=1
else
    echo "ok: marginal trust alone does not count as usable"
fi

# the regression: boot.sh must not gate on bare --list-keys any more
if grep -qE "in_target sh -c 'pacman-key --list-keys[^']*' && return 0" "$BOOT"; then
    echo "FAIL: boot.sh still returns early on key PRESENCE"; rc=1
else
    echo "ok: boot.sh no longer gates on key presence"
fi
if grep -q 'uid:\[fu\]:' "$BOOT"; then
    echo "ok: boot.sh tests uid validity (full/ultimate)"
else
    echo "FAIL: boot.sh does not test uid validity"; rc=1
fi

[ $rc -eq 0 ] && echo "PASS: keyring readiness is decided by trust, not presence"
exit $rc
