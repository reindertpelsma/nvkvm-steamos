#!/bin/bash
# driver_version_test.sh — where the NVIDIA driver version comes from.
#
# The rule, in one sentence: --driver-version exists only for the case where the
# running system cannot answer.
#
#   flag absent, --install-only : read /proc/driver/nvidia/version, ABORT if absent.
#                                (The disposable Alpine installer has no module
#                                loaded, which is why the flag exists at all.)
#   flag absent, boot           : load nvkvm FIRST -- that is what makes
#                                /proc/driver/nvidia/version exist -- then read it.
#   flag present                : it WINS, but warn when the running driver
#                                disagrees. A silent override is how userspace
#                                gets built for a driver the host does not have,
#                                and it surfaces much later as an unexplained
#                                CUDA failure.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
rc=0

# 1. install-only with no flag and no /proc must refuse, not guess
# Assert the GATE, not its wording -- the message is allowed to improve.
if grep -q 'if \[ "\$CMD" = install \] && \[ -z "\$(host_driver_version)" \]; then' "$BOOT" \
   && sed -n '/if \[ "\$CMD" = install \] && \[ -z "\$(host_driver_version)" \]; then/,/^fi$/p' "$BOOT" \
      | grep -q 'exit 1'; then
    echo "ok: --install-only refuses rather than guessing a version"
else
    echo "FAIL: nothing stops --install-only running with no version at all"; rc=1
fi
# and the message must point at the module too: on a live system "pass
# --driver-version" is the wrong advice, the operator wants modprobe.
sed -n '/if \[ "\$CMD" = install \] && \[ -z "\$(host_driver_version)" \]; then/,/^fi$/p' "$BOOT" \
    | grep -q 'modprobe' \
    && echo "ok: the refusal names loading the module, not just the flag" \
    || { echo "FAIL: the refusal only suggests --driver-version"; rc=1; }

# 2. the boot path must load the module BEFORE reading the version, because
#    loading it is what creates /proc/driver/nvidia/version
boot_body="$(sed -n '/^do_boot()/,/^}/p' "$BOOT")"
load_at="$(printf '%s' "$boot_body" | grep -n 'load_nvkvm_module' | head -1 | cut -d: -f1)"
val_at="$(printf '%s' "$boot_body" | grep -n 'if validate' | head -1 | cut -d: -f1)"
if [ -n "$load_at" ] && [ -n "$val_at" ] && [ "$load_at" -lt "$val_at" ]; then
    echo "ok: boot loads nvkvm before it needs the version"
else
    echo "FAIL: boot reads the version before loading the module (load=$load_at validate=$val_at)"; rc=1
fi

# 3. an explicit version wins...
hv="$(sed -n '/^host_driver_version()/,/^}/p' "$BOOT")"
printf '%s' "$hv" | grep -q "printf '%s\\\\n' \"\$DRIVER_VERSION\"" \
    && echo "ok: an explicit --driver-version is used as given" \
    || { echo "FAIL: the explicit version is not returned"; rc=1; }

# 4. ...but a disagreement with the running driver is reported
printf '%s' "$hv" | grep -q 'proc/driver/nvidia/version' \
    && echo "ok: the running driver is consulted for comparison" \
    || { echo "FAIL: an explicit version overrides silently"; rc=1; }
printf '%s' "$hv" | grep -q 'DRIVER_VERSION_MISMATCH_WARNED' \
    && echo "ok: the mismatch warning fires once, not per call" \
    || { echo "FAIL: no once-only guard; host_driver_version is called repeatedly"; rc=1; }

# 5. the module is rebuilt when it was built from a different commit
grep -q 'module out of date (built=' "$BOOT" \
    && echo "ok: a module built from another commit is rebuilt" \
    || { echo "FAIL: no commit check before trusting an installed module"; rc=1; }

[ $rc -eq 0 ] && echo "PASS: the version comes from the running system unless it cannot answer"
exit $rc
