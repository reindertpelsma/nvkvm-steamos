#!/bin/bash
# dri_preflight_test.sh — the VMM must say so when the host's DRM nodes are
# absent from the container.
#
# The guest's /dev/dri/card0 is a PROXY: nvkvm_drm_open() forwards to the host's
# DRM render node and returns its errno verbatim. MEASURED on a vast.ai KVM box:
# with no /dev/dri in the container, every compositor in the guest died on
#
#     kwin_core: Failed to open /dev/dri/card0 device (No such file or directory)
#
# while stat(2) reported a character device at 226:0, /proc/devices listed
# "226 drm", /sys/class/drm was fully populated and the module's own probe
# logged "virtual KMS head ready". A module reload reproduced it on fresh nodes.
# Nothing in the guest is wrong, which is why this cost hours to find.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="$DIR/scripts/steamos-container-entrypoint.sh"
OVERRIDE="$DIR/override-dri.yml"
rc=0

# The check must key on the DRM nodes, not on something incidental.
if grep -q '/dev/dri/renderD128' "$ENTRY" && grep -q '/dev/dri/card0' "$ENTRY"; then
    echo "ok: entrypoint preflights the host DRM nodes"
else
    echo "FAIL: entrypoint does not check for /dev/dri"; rc=1
fi

# It must name the remedy. A warning that does not say what to do just relocates
# the confusion.
if grep -q 'override-dri.yml' "$ENTRY"; then
    echo "ok: the warning names the remedy"
else
    echo "FAIL: the warning does not tell the operator what to run"; rc=1
fi

# It must NOT be fatal: the VM still boots and ssh still works without /dev/dri,
# and that is exactly how an operator reaches in to fix it.
blk="$(awk '/no \/dev\/dri in this container/,/^fi$/' "$ENTRY")"
if [ -n "$blk" ] && ! grep -qE '\bdie\b|exit 1' <<<"$blk"; then
    echo "ok: missing /dev/dri warns rather than aborting the container"
else
    echo "FAIL: the /dev/dri check aborts, which would remove the way in to fix it"; rc=1
fi

# The override must exist, must add the DRM nodes, and must keep the devices the
# base file already grants -- a Compose `devices:` list REPLACES, it does not
# merge, so dropping one here would silently take /dev/kvm away.
if [ -f "$OVERRIDE" ]; then
    echo "ok: override-dri.yml exists"
    for d in /dev/dri /dev/kvm /dev/udmabuf; do
        if grep -q "$d:$d" "$OVERRIDE"; then
            echo "ok: override keeps $d"
        else
            echo "FAIL: override-dri.yml drops $d -- devices: REPLACES the base list"; rc=1
        fi
    done
else
    echo "FAIL: override-dri.yml is missing"; rc=1
fi

# And it must not have crept into the base compose, which would break every
# compute-only host that has no /dev/dri at all.
if grep -qE '^\s*-\s*/dev/dri:/dev/dri' "$DIR/docker-compose.yml"; then
    echo "FAIL: /dev/dri is in the base compose; hosts without it cannot start"; rc=1
else
    echo "ok: base compose stays portable to hosts with no /dev/dri"
fi

exit $rc
