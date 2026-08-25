#!/usr/bin/env bash
# Regress first-start and restart behavior of the capability-restricted VMM
# container without downloading a recovery image or requiring KVM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$ROOT/scripts/steamos-container-entrypoint.sh"
INSTALLER="$ROOT/install_steamos_vm.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'container_entrypoint_test: FAIL: %s\n' "$*" >&2
    exit 1
}

# Load only the entrypoint's pure helpers. In particular, do not run the KVM
# and mount-point preflight from this host-side regression test.
export NVKVM_STEAMOS_ENTRYPOINT_SOURCE_ONLY=1
# shellcheck source=../scripts/steamos-container-entrypoint.sh
source "$ENTRYPOINT"
unset NVKVM_STEAMOS_ENTRYPOINT_SOURCE_ONLY

STATE_DIR="$TEST_ROOT/state"
export RECOVERY_BASE="https://invalid.example/recovery"
PINNED_RECOVERY="test-repair.img.bz2"
mkdir -p "$STATE_DIR/recovery"
ARCHIVE="$STATE_DIR/recovery/$PINNED_RECOVERY"
RAW="${ARCHIVE%.bz2}"
printf 'archive bytes\n' > "$ARCHIVE"
printf 'already decompressed\n' > "$RAW"

# First use records a checksum; subsequent use verifies it. Neither operation
# may write status text to stdout because prepare_recovery's stdout is its API.
[ -z "$(record_or_verify_checksum "$ARCHIVE")" ] \
    || fail "initial checksum recording polluted stdout"
[ -z "$(record_or_verify_checksum "$ARCHIVE")" ] \
    || fail "checksum verification polluted stdout"

RECOVERY_IMG="$(prepare_recovery 2>/dev/null)"
[ "$RECOVERY_IMG" = "$RAW" ] \
    || fail "restart selected a contaminated recovery path: $RECOVERY_IMG"
printf 'tampered\n' >> "$ARCHIVE"
if (record_or_verify_checksum "$ARCHIVE" >/dev/null 2>&1); then
    fail "checksum verification accepted a modified archive"
fi

# The container runs as uid 0 but deliberately lacks CAP_CHOWN. Pin the tar
# flag that makes Alpine's uid/gid metadata advisory instead of fatal.
grep -Eq 'tar[[:space:]]+--no-same-owner[[:space:]]+-xzf' "$INSTALLER" \
    || fail "Alpine extraction does not suppress archive ownership restoration"

# Demonstrate the exact capability failure and the selected tar behavior when
# this test itself has enough privilege to drop CAP_CHOWN. Non-root CI still
# exercises the source assertion above.
if [ "$(id -u)" = 0 ] && command -v setpriv >/dev/null 2>&1; then
    mkdir -p "$TEST_ROOT/tar-src/boot" "$TEST_ROOT/tar-bad" "$TEST_ROOT/tar-good"
    printf kernel > "$TEST_ROOT/tar-src/boot/vmlinuz-virt"
    tar --owner=1000 --group=1000 -czf "$TEST_ROOT/netboot.tar.gz" \
        -C "$TEST_ROOT/tar-src" boot/vmlinuz-virt

    if setpriv --bounding-set=-chown --inh-caps=-all --ambient-caps=-all -- \
        tar -xzf "$TEST_ROOT/netboot.tar.gz" -C "$TEST_ROOT/tar-bad" \
            boot/vmlinuz-virt >/dev/null 2>&1; then
        fail "test setup did not reproduce tar's CAP_CHOWN failure"
    fi
    setpriv --bounding-set=-chown --inh-caps=-all --ambient-caps=-all -- \
        tar --no-same-owner -xzf "$TEST_ROOT/netboot.tar.gz" \
            -C "$TEST_ROOT/tar-good" boot/vmlinuz-virt
    [ "$(cat "$TEST_ROOT/tar-good/boot/vmlinuz-virt")" = kernel ] \
        || fail "capability-safe extraction produced the wrong file"
fi

printf 'container_entrypoint_test: PASS\n'
