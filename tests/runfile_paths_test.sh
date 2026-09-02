#!/bin/bash
# runfile_paths_test.sh — the guest must look for the NVIDIA .run on BOTH
# public paths.
#
# NVIDIA publishes desktop drivers under XFree86/Linux-x86_64/ and datacenter
# drivers under tesla/, and some versions exist only under the latter.
# MEASURED 2026-09-02: 570.133.20 and 570.124.06 return 404 on XFree86 and 206
# on tesla. locate_or_fetch_run() tried only XFree86, so a host on such a
# driver could not provision at all -- and those are precisely the drivers the
# A100/H100-class parts ship with.
#
# nvkvm-pv's scripts/sweep-driver-availability.tsv probes both for the same
# reason. This test keeps the two from drifting apart.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
rc=0
fn="$(awk '/^locate_or_fetch_run\(\) \{/,/^\}/' "$BOOT")"
[ -n "$fn" ] || { echo "FAIL: could not extract locate_or_fetch_run"; exit 1; }

if printf '%s' "$fn" | grep -q 'XFree86/Linux-x86_64/\${ver}/\${fname}'; then
    echo "ok: tries the XFree86 (desktop) path"
else
    echo "FAIL: the XFree86 path is missing"; rc=1
fi
if printf '%s' "$fn" | grep -q 'tesla/\${ver}/\${fname}'; then
    echo "ok: tries the tesla (datacenter) path"
else
    echo "FAIL: the tesla path is missing -- datacenter-only drivers cannot be fetched"; rc=1
fi

# Trying a second URL is pointless if the first failure returns early.
if printf '%s' "$fn" | grep -qE 'for +url +in'; then
    echo "ok: the paths are tried in a loop"
else
    echo "FAIL: no loop over candidate URLs; a first-path failure likely returns early"; rc=1
fi

# 403 is geo-redirection to NVIDIA's China CDN, not absence. Guard the note so
# nobody "optimises" it into treating 403 as unpublished.
if printf '%s' "$fn" | grep -q '403'; then
    echo "ok: the 403-is-not-absence note survives"
else
    echo "FAIL: the note explaining that 403 != absent was removed"; rc=1
fi
exit $rc
