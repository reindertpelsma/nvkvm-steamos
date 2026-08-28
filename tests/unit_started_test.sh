#!/bin/bash
# unit_started_test.sh — enabling a unit does not start it.
#
# steamos_boot.sh runs from nvkvm-boot.service, which is WantedBy
# multi-user.target. By the time it enables anything, systemd has already pulled
# in everything that target wanted, so a newly enabled unit gets its wants
# symlink and then sits INACTIVE until the next boot.
#
# OBSERVED on a fresh install 2026-08-28: sshd enabled, wants symlink present,
# multi-user.target active, sshd never ran. `systemctl show` reported
# ConditionResult=no, which reads like a failed condition but only means the
# unit was never attempted -- sshd.service has no conditions at all. That field
# cost real diagnosis time, so it is written down here.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
rc=0

# sshd must be started, not merely enabled, when running against the live system
if grep -qE 'systemctl start sshd\.service' "$BOOT"; then
    echo "ok: boot.sh starts sshd, not just enables it"
else
    echo "FAIL: boot.sh only enables sshd -- it will not run until the next boot"; rc=1
fi

# ...and that start must be guarded on ROOT=/ : a chroot has no running systemd
block="$(sed -n '/ENABLING IS NOT STARTING/,/^    fi$/p' "$BOOT")"
if printf '%s' "$block" | grep -q '\[ "\$ROOT" = "/" \]'; then
    echo "ok: the start is guarded on operating against the live system"
else
    echo "FAIL: the start is not guarded on ROOT=/ -- it would run inside a chroot"; rc=1
fi

# it must not start something already running (noise, and a needless restart risk)
if printf '%s' "$block" | grep -q 'is-active --quiet'; then
    echo "ok: it skips the start when sshd is already active"
else
    echo "FAIL: no is-active check before starting"; rc=1
fi

# a failed start must warn rather than abort provisioning: ssh is not worth
# failing an install over, but a silent failure is what caused this report
if printf '%s' "$block" | grep -q 'warn "ssh: sshd could not be started'; then
    echo "ok: a failed start warns and says it will come up next boot"
else
    echo "FAIL: a failed start is silent"; rc=1
fi

[ $rc -eq 0 ] && echo "PASS: units enabled at provisioning time are also started"
exit $rc
