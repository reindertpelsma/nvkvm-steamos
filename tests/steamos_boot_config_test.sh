#!/usr/bin/env bash
# Regression guard for the desktop policy shared by fresh provisioning, normal
# boot convergence, and SteamOS A/B update provisioning.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT_SCRIPT="$REPO_ROOT/boot/steamos_boot.sh"
INSTALLER_GUEST="$REPO_ROOT/vm/guest-init.sh"
CONTAINER_ENTRYPOINT="$REPO_ROOT/scripts/steamos-container-entrypoint.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'steamos_boot_config_test: FAIL: %s\n' "$*" >&2
    exit 1
}

export NVKVM_STEAMOS_BOOT_SOURCE_ONLY=1
# shellcheck source=../boot/steamos_boot.sh
source "$BOOT_SCRIPT"

# The version handoff must stay data-driven. An explicit installer value wins;
# normal boot remains able to discover the value from nvkvm's procfs bridge.
# shellcheck disable=SC2034  # read by host_driver_version() from sourced script
DRIVER_VERSION=999.123
[ "$(host_driver_version)" = 999.123 ] \
    || fail "host_driver_version did not return its explicit argument"

ROOT="$TEST_ROOT"
export PROFILE=steamos
mkdir -p "$ROOT/usr/share/wayland-sessions"
: > "$ROOT/usr/share/wayland-sessions/plasma.desktop"
write_sddm_session_config

OVERRIDE="$ROOT/etc/sddm.conf.d/zz-nvkvm-plasma.conf"
[ -f "$OVERRIDE" ] || fail "SteamOS provisioning did not create the SDDM override"
EXPECTED=$'[Autologin]\nSession=plasma.desktop'
[ "$(cat "$OVERRIDE")" = "$EXPECTED" ] \
    || fail "the SDDM override does not select plasma.desktop exactly"

# A profile switch must remove policy that no longer belongs to this image.
PROFILE=compute
write_sddm_session_config
[ ! -e "$OVERRIDE" ] || fail "compute convergence left a stale SteamOS override"

# Do not write a session name the target image cannot resolve.
PROFILE=steamos
rm -f "$ROOT/usr/share/wayland-sessions/plasma.desktop"
write_sddm_session_config
[ ! -e "$OVERRIDE" ] || fail "provisioning selected an absent Plasma session"

# Pin the setup call chain: the disposable Alpine builder must provision the
# newly installed root through the same --install-only implementation tested
# above. A manual post-boot edit would not satisfy this assertion.
grep -qF '/run/nvkvm/boot/steamos_boot.sh --install-only --root "$TARGET_MNT"' \
    "$INSTALLER_GUEST" \
    || fail "fresh-image setup no longer calls steamos_boot.sh --install-only --root"
# The step must still RUN in do_install. Its failure is deliberately not fatal
# any more -- provisioning fails only when the guest would have no working GPU,
# and a desktop tweak that did not apply is a warning. Asserted on the call, not
# on the rc handling, so that policy can change without lying about coverage.
sed -n '/^do_install()/,/^}/p' "$BOOT_SCRIPT" | grep -q 'write_desktop_config' \
    || fail "do_install no longer converges desktop configuration"
grep -qF -- '--profile "$PROFILE" --driver-version "$DRIVER_VERSION"' \
    "$INSTALLER_GUEST" \
    || fail "the Alpine installer no longer passes its detected driver version"
grep -qF -- '--driver-version "$DRIVER_VERSION"' "$CONTAINER_ENTRYPOINT" \
    || fail "the container first-run path no longer passes its detected driver version"

printf 'steamos_boot_config_test: PASS\n'

# SPACE: a slot written by an A/B update can be too full for the NVIDIA
# userspace -- measured 2026-08-29, 408M free against a 395M install, and
# nvidia-installer died with "Received signal SIGBUS" (a write to an mmap'd
# file on a full filesystem, which does not read like a disk-full error at
# all). SteamOS ships ~350M of firmware for hardware a VM does not have, and
# the guest module needs none of it.
grep -q 'reclaiming .* of device firmware a VM cannot use' "$BOOT_SCRIPT" \
    || fail "provisioning no longer reclaims firmware when short of space"
sed -n '/RECLAIM .usr.lib.firmware BEFORE GIVING UP/,/^    fi$/p' "$BOOT_SCRIPT" \
    | grep -q 'free_kb" -lt "$need_kb"' \
    || fail "the firmware reclaim is not gated on actually being short of space"
