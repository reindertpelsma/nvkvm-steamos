#!/usr/bin/env bash
# run_tests.sh — host-side tests for the parts of this repo that can be tested
# without a GPU, a SteamOS image or a VM.
#
# Everything here asserts a PROPERTY of the filesystem or of a return code —
# never that a particular log line was printed. A test that greps for a message
# passes the moment someone reproduces the message, which is the opposite of
# what a regression test is for.
#
#   ./test/run_tests.sh                 # test this checkout
#   ./test/run_tests.sh --tree DIR      # test a different checkout
#
# --tree is how the "does it fail with the fix reverted?" proof is done, and it
# is deliberately the ONLY knob: point it at a tree extracted from an older
# commit (`git archive <commit> | tar -x -C /tmp/pre`) and the same tests run
# unchanged against that tree's real files. There is no second copy of the code
# under test and no include path that could resolve to the wrong directory —
# every test reads out of $TREE and nowhere else.
#
# Exit 0 = all passed, 1 = something failed.

set -uo pipefail

TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [ $# -gt 0 ]; do
    case "$1" in
        --tree) TREE="$(cd "$2" && pwd)" || exit 2; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

BOOT_SH="$TREE/boot/steamos_boot.sh"
BUILD_SH="$TREE/build_steamos_image.sh"
VERIFY_SH="$TREE/boot/verify_image.sh"
IMAGE_DIR="$TREE/boot/image"
for f in "$BOOT_SH" "$BUILD_SH" "$IMAGE_DIR"; do
    [ -e "$f" ] || { echo "not a nvkvm-steamos tree (missing $f): $TREE" >&2; exit 2; }
done
echo "tree under test: $TREE"

PASS=0 FAIL=0 SKIP=0
FAILED_NAMES=""
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; printf '  \033[31mFAIL\033[0m %s\n      %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m %s\n      %s\n' "$1" "$2"; }

# ── Loading the functions out of steamos_boot.sh ─────────────────────────────
# The script ends in an argument parser that runs a mode, so it cannot simply be
# sourced. Cut it at its own entry-point banner and source the definitions.
# HARD failure if the banner is not there: silently sourcing the whole file, or
# silently sourcing nothing, are both ways to "pass" without testing anything.
BOOT_LIB="$(mktemp)"
trap 'rm -f "$BOOT_LIB"' EXIT
if ! grep -q '^# ── Entry point' "$BOOT_SH"; then
    echo "cannot find the '# ── Entry point' banner in $BOOT_SH — refusing to guess" >&2
    exit 2
fi
sed '/^# ── Entry point/,$d' "$BOOT_SH" > "$BOOT_LIB"
grep -q '^install_stub()' "$BOOT_LIB" || { echo "install_stub() not in the sourced part of $BOOT_SH" >&2; exit 2; }

# ── A fake share and a fake image root ───────────────────────────────────────
# The share half is the real boot/image/ out of $TREE, so the tests copy the
# same bytes install_stub copies in production.
make_share() {   # <dir>
    mkdir -p "$1/boot/image"
    cp "$IMAGE_DIR"/nvkvm-recovery.sh "$IMAGE_DIR"/nvkvm-boot.service \
       "$IMAGE_DIR"/nvkvm-plant-stub.path "$IMAGE_DIR"/nvkvm-plant-stub.service "$1/boot/image/"
}

# Everything install_stub touches besides the filesystem, neutralised.
stub_environment() {
    steamos_unlock() { :; }
    in_target()      { :; }
    log()  { :; }
    warn() { :; }
    err()  { printf 'ERR: %s\n' "$*" >>"${TEST_ERRLOG:-/dev/null}"; }
}

echo
echo "== plant_file / install_stub =========================================="

# 1. The happy path has to actually be happy, or every negative test below is
#    vacuous.
t_plant_intact() {
    local n=plant_file_copies_the_source_byte_for_byte
    ( set +e
      # shellcheck disable=SC1090
      . "$BOOT_LIB"; stub_environment
      type plant_file >/dev/null 2>&1 || exit 90
      d="$(mktemp -d)"
      plant_file "$IMAGE_DIR/nvkvm-recovery.sh" "$d/root/usr/local/sbin/nvkvm-recovery.sh" 0755 || { rm -rf "$d"; exit 1; }
      cmp -s "$IMAGE_DIR/nvkvm-recovery.sh" "$d/root/usr/local/sbin/nvkvm-recovery.sh" || { rm -rf "$d"; exit 2; }
      [ -x "$d/root/usr/local/sbin/nvkvm-recovery.sh" ] || { rm -rf "$d"; exit 3; }
      rm -rf "$d" )
    case $? in
        0)  ok "$n" ;;
        90) skip "$n" "this tree has no plant_file() — nothing to test" ;;
        1)  bad "$n" "plant_file returned non-zero on a good source" ;;
        2)  bad "$n" "the planted file differs from the source" ;;
        3)  bad "$n" "the planted file is not executable" ;;
        *)  bad "$n" "unexpected status" ;;
    esac
}

# 2. THE bug. install(1) opens the destination O_CREAT|O_TRUNC before it has
#    written a byte, so a failure mid-copy leaves a real, correctly-named,
#    ZERO-LENGTH file. execve() on an empty file is ENOEXEC, which systemd
#    reports as `203/EXEC` — on every single boot, while `ls` says the file is
#    right there. Assert on the filesystem: after a failed plant there must be
#    no zero-length file at the destination.
t_plant_enospc() {
    local n=plant_leaves_no_zero_length_file_when_the_rootfs_is_full
    local d img mnt
    d="$(mktemp -d)"; img="$d/fs.img"; mnt="$d/mnt"; mkdir -p "$mnt"
    dd if=/dev/zero of="$img" bs=1k count=1024 status=none 2>/dev/null
    if ! mkfs.ext2 -q -F -b 1024 "$img" 2>/dev/null || ! mount -o loop "$img" "$mnt" 2>/dev/null; then
        rm -rf "$d"; skip "$n" "cannot loop-mount a scratch filesystem here (needs root + loop devices)"; return
    fi
    mkdir -p "$mnt/usr/local/sbin"
    dd if=/dev/urandom of="$mnt/filler" bs=1k count=4000 status=none 2>/dev/null
    # Sanity: the filesystem really is full, or this test proves nothing.
    if dd if=/dev/zero of="$mnt/probe" bs=1k count=8 status=none 2>/dev/null; then
        rm -f "$mnt/probe"; umount "$mnt"; rm -rf "$d"
        bad "$n" "could not fill the scratch filesystem — test would be vacuous"; return
    fi
    local dst="$mnt/usr/local/sbin/nvkvm-recovery.sh"
    ( set +e
      # shellcheck disable=SC1090
      . "$BOOT_LIB"; stub_environment
      if type plant_file >/dev/null 2>&1; then
          plant_file "$IMAGE_DIR/nvkvm-recovery.sh" "$dst" 0755
      else
          # the pre-fix code path, verbatim
          install -D -m 0755 "$IMAGE_DIR/nvkvm-recovery.sh" "$dst"
      fi ) 2>/dev/null
    local rc=$?
    local left="absent"
    [ -e "$dst" ] && left="$(wc -c <"$dst") bytes"
    umount "$mnt"; rm -rf "$d"
    if [ "$rc" -eq 0 ]; then
        bad "$n" "the copy reported success on a full filesystem"
    elif [ "$left" != absent ]; then
        bad "$n" "a failed plant left $dst behind ($left) — systemd would fail it 203/EXEC on every boot"
    else
        ok "$n"
    fi
}

# 3. A zero-length source on the share must never become a zero-length plant.
#    install(1) copies it happily and exits 0, which is how a 0-byte executable
#    ships with nothing complaining anywhere.
t_plant_empty_source() {
    local n=an_empty_source_never_becomes_an_empty_plant
    local d; d="$(mktemp -d)"
    : > "$d/empty.sh"
    local dst="$d/root/usr/local/sbin/nvkvm-recovery.sh"
    ( set +e
      # shellcheck disable=SC1090
      . "$BOOT_LIB"; stub_environment
      if type plant_file >/dev/null 2>&1; then
          plant_file "$d/empty.sh" "$dst" 0755
      else
          install -D -m 0755 "$d/empty.sh" "$dst"
      fi )
    local rc=$?
    local exists=no; [ -e "$dst" ] && exists=yes
    local sz=-1; [ -e "$dst" ] && sz="$(wc -c <"$dst")"
    rm -rf "$d"
    if [ "$rc" -eq 0 ]; then
        bad "$n" "planting a zero-length source reported success"
    elif [ "$exists" = yes ] && [ "$sz" -eq 0 ]; then
        bad "$n" "a zero-length file was left at the destination"
    else
        ok "$n"
    fi
}

# 4. install_stub as a whole: all four files, byte-identical, recovery.sh
#    executable, rc 0.
t_install_stub_ok() {
    local n=install_stub_plants_all_four_files_byte_identical
    local d; d="$(mktemp -d)"; make_share "$d/share"; mkdir -p "$d/root"
    ( set +e
      # shellcheck disable=SC1090
      . "$BOOT_LIB"; stub_environment
      NVKVM_SHARE_MNT="$d/share"; ROOT="$d/root"
      install_stub )
    local rc=$?
    local err=""
    [ "$rc" -eq 0 ] || err="install_stub returned $rc"
    local pair
    for pair in usr/local/sbin/nvkvm-recovery.sh:nvkvm-recovery.sh \
                etc/systemd/system/nvkvm-boot.service:nvkvm-boot.service \
                etc/systemd/system/nvkvm-plant-stub.path:nvkvm-plant-stub.path \
                etc/systemd/system/nvkvm-plant-stub.service:nvkvm-plant-stub.service; do
        cmp -s "$IMAGE_DIR/${pair##*:}" "$d/root/${pair%%:*}" \
            || err="$err; /${pair%%:*} does not match the share"
    done
    [ -x "$d/root/usr/local/sbin/nvkvm-recovery.sh" ] || err="$err; recovery.sh not executable"
    rm -rf "$d"
    [ -z "$err" ] && ok "$n" || bad "$n" "$err"
}

# 5. install_stub with a broken share must fail AND must not leave a
#    zero-length /usr/local/sbin/nvkvm-recovery.sh in the image.
t_install_stub_broken_share() {
    local n=install_stub_fails_and_plants_nothing_when_the_share_file_is_empty
    local d; d="$(mktemp -d)"; make_share "$d/share"; mkdir -p "$d/root"
    : > "$d/share/boot/image/nvkvm-recovery.sh"          # the broken bit
    ( set +e
      # shellcheck disable=SC1090
      . "$BOOT_LIB"; stub_environment
      NVKVM_SHARE_MNT="$d/share"; ROOT="$d/root"
      install_stub )
    local rc=$?
    local dst="$d/root/usr/local/sbin/nvkvm-recovery.sh"
    local left="absent"; [ -e "$dst" ] && left="$(wc -c <"$dst") bytes"
    rm -rf "$d"
    if [ "$rc" -eq 0 ]; then
        bad "$n" "install_stub reported success with a zero-length source on the share"
    elif [ "$left" != absent ]; then
        bad "$n" "left $left at /usr/local/sbin/nvkvm-recovery.sh — that is the 203/EXEC artifact"
    else
        ok "$n"
    fi
}

# 6. Part 1's exit status must reflect a failed plant. It used to be discarded
#    with `|| true`, so an image with no working nvkvm-boot.service still
#    reported `Part 1 finished (rc=0)` and the builder shipped it.
t_do_install_propagates() {
    local n=part1_returns_nonzero_when_install_stub_fails
    run_do_install() {   # <install_stub-return-code>
        local _want_stub_rc="$1"
        ( set +e
          # shellcheck disable=SC1090
          . "$BOOT_LIB"
          # Neutralise everything do_install does EXCEPT install_stub, so the
          # return code can only be coming from the thing under test.
          log() { :; }; warn() { :; }; err() { :; }
          capture_ro_state() { :; };  restore_ro_state() { :; }
          pkgs_snapshot() { :; };     mount_9p_share() { return 0; }
          target_kver() { echo k; };  repo_commit() { echo c; }
          built_commit() { echo c; }; remove_added_packages() { :; }
          host_driver_version() { echo 1.0; }
          installed_userspace_version() { echo 1.0; }
          in_target() { :; };         prune_run_cache() { :; }
          write_desktop_config() { return 0; }
          configure_ssh() { return 0; }
          install_stub() { return "$_want_stub_rc"; }
          do_install >/dev/null 2>&1 )
    }
    local good bad_rc
    run_do_install 0 >/dev/null 2>&1; good=$?
    run_do_install 1 >/dev/null 2>&1; bad_rc=$?
    if [ "$good" -ne 0 ]; then
        bad "$n" "do_install returned $good even with install_stub succeeding — the stubs are wrong, not the code"
    elif [ "$bad_rc" -eq 0 ]; then
        bad "$n" "install_stub failed but Part 1 still returned 0"
    else
        ok "$n"
    fi
}

t_plant_intact
t_plant_enospc
t_plant_empty_source
t_install_stub_ok
t_install_stub_broken_share
t_do_install_propagates

echo
echo "== build_steamos_image.sh gates ======================================="

# A share good enough for the preflight to get past its own checks.
make_full_share() {   # <dir>
    make_share "$1"
    mkdir -p "$1/src/guest"; : > "$1/src/guest/Makefile"
    chmod +x "$1/boot/image/nvkvm-recovery.sh"
    # the preflight resolves --boot-script under the share
    mkdir -p "$1/boot"; cp "$BOOT_SH" "$1/boot/steamos_boot.sh"; chmod +x "$1/boot/steamos_boot.sh"
}

# 7. The preflight must refuse a share carrying a zero-length boot/image file,
#    BEFORE the ~2 minute module build and NVIDIA install, and it must not be
#    possible to reach the build with one.
t_preflight_rejects_empty_share_file() {
    local n=preflight_refuses_a_zero_length_boot_image_file_on_the_share
    if [ "$(id -u)" != 0 ]; then skip "$n" "preflight requires root"; return; fi
    local d; d="$(mktemp -d)"; make_full_share "$d/share"
    : > "$d/share/boot/image/nvkvm-recovery.sh"
    chmod +x "$d/share/boot/image/nvkvm-recovery.sh"
    # Stand in for host tools the preflight only checks the presence of.
    mkdir -p "$d/bin"
    local t
    for t in losetup sgdisk btrfs unshare blkid findmnt chroot modinfo mkfs.ext4 numfmt; do
        command -v "$t" >/dev/null 2>&1 && continue
        printf '#!/bin/sh\nexit 0\n' > "$d/bin/$t"; chmod +x "$d/bin/$t"
    done
    dd if=/dev/zero of="$d/src.img" bs=1k count=64 status=none 2>/dev/null
    local out rc
    out="$(PATH="$d/bin:$PATH" bash "$BUILD_SH" --src "$d/src.img" --share "$d/share" \
             --out "$d/out.img" --no-qcow2 --grow 0 2>&1)"
    rc=$?
    rm -rf "$d"
    # Preflight's own order is: 2 usage, 3 missing tool, 5 bad --src, 6 SHARE,
    # 11 host driver, 4 space. So 2/3/5 mean it stopped BEFORE the share block
    # and this test could not run; anything at or after 6 is a real verdict, and
    # "it got as far as 11" is precisely the bug — it walked past a zero-length
    # nvkvm-recovery.sh without a word. A SKIP here would hide exactly that.
    case "$rc" in
        6)       ok "$n" ;;
        2|3|5)   skip "$n" "preflight stopped at exit $rc, before the share checks; last line: $(printf '%s' "$out" | tail -1)" ;;
        0)       bad "$n" "the build accepted a share with a zero-length nvkvm-recovery.sh" ;;
        *)       bad "$n" "preflight got past the share checks (exit $rc) with a zero-length nvkvm-recovery.sh on the share; last line: $(printf '%s' "$out" | tail -1)" ;;
    esac
}

# 8-11. The post-provision gate — boot/verify_image.sh, which is what step 8b
#       calls — exercised against hand-built fake image roots.
fake_image_root() {   # <root> <share>
    local r="$1" s="$2"
    mkdir -p "$r/usr/lib/modules/6.1.0-test/updates" "$r/usr/lib" \
             "$r/etc/modules-load.d" "$r/etc/modprobe.d" \
             "$r/etc/systemd/system" "$r/usr/local/sbin"
    echo x > "$r/usr/lib/modules/6.1.0-test/vmlinuz"
    echo x > "$r/usr/lib/modules/6.1.0-test/updates/nvkvm-guest.ko"
    local l
    for l in libnvidia-glcore libnvidia-glsi libnvidia-tls libGLX_nvidia; do echo x > "$r/usr/lib/$l.so.1"; done
    echo nvkvm-guest > "$r/etc/modules-load.d/nvkvm.conf"
    echo options    > "$r/etc/modprobe.d/99-nvkvm.conf"
    install -m 0755 "$s/boot/image/nvkvm-recovery.sh"        "$r/usr/local/sbin/nvkvm-recovery.sh"
    install -m 0644 "$s/boot/image/nvkvm-boot.service"       "$r/etc/systemd/system/nvkvm-boot.service"
    install -m 0644 "$s/boot/image/nvkvm-plant-stub.path"    "$r/etc/systemd/system/nvkvm-plant-stub.path"
    install -m 0644 "$s/boot/image/nvkvm-plant-stub.service" "$r/etc/systemd/system/nvkvm-plant-stub.service"
}

verify_supported() { [ -x "$VERIFY_SH" ]; }
run_verify() { bash "$VERIFY_SH" "$1" "$2" >/dev/null 2>&1; }

t_verify_good() {
    local n=verify_image_accepts_a_correctly_provisioned_image
    if ! verify_supported; then skip "$n" "this tree has no boot/verify_image.sh"; return; fi
    local d; d="$(mktemp -d)"; make_share "$d/share"; fake_image_root "$d/root" "$d/share"
    run_verify "$d/root" "$d/share"
    local rc=$?; rm -rf "$d"
    [ "$rc" -eq 0 ] && ok "$n" || bad "$n" "a good image was rejected (exit $rc) — every negative test below would be vacuous"
}

t_verify_zero_length() {
    local n=verify_image_rejects_a_zero_length_planted_recovery_script
    if ! verify_supported; then skip "$n" "this tree has no boot/verify_image.sh"; return; fi
    local d; d="$(mktemp -d)"; make_share "$d/share"; fake_image_root "$d/root" "$d/share"
    : > "$d/root/usr/local/sbin/nvkvm-recovery.sh"          # the shipped artifact
    chmod 0755 "$d/root/usr/local/sbin/nvkvm-recovery.sh"
    run_verify "$d/root" "$d/share"
    local rc=$?; rm -rf "$d"
    [ "$rc" -ne 0 ] && ok "$n" || bad "$n" "a 0-byte /usr/local/sbin/nvkvm-recovery.sh passed verification"
}

t_verify_truncated() {
    local n=verify_image_rejects_a_truncated_but_nonempty_planted_script
    if ! verify_supported; then skip "$n" "this tree has no boot/verify_image.sh"; return; fi
    local d; d="$(mktemp -d)"; make_share "$d/share"; fake_image_root "$d/root" "$d/share"
    # Non-empty, executable, plausible — and wrong. A size>0 test passes this.
    head -c 400 "$d/share/boot/image/nvkvm-recovery.sh" > "$d/root/usr/local/sbin/nvkvm-recovery.sh"
    chmod 0755 "$d/root/usr/local/sbin/nvkvm-recovery.sh"
    run_verify "$d/root" "$d/share"
    local rc=$?; rm -rf "$d"
    [ "$rc" -ne 0 ] && ok "$n" || bad "$n" "a truncated /usr/local/sbin/nvkvm-recovery.sh passed verification"
}

t_verify_not_executable() {
    local n=verify_image_rejects_a_planted_script_that_is_not_executable
    if ! verify_supported; then skip "$n" "this tree has no boot/verify_image.sh"; return; fi
    local d; d="$(mktemp -d)"; make_share "$d/share"; fake_image_root "$d/root" "$d/share"
    chmod 0644 "$d/root/usr/local/sbin/nvkvm-recovery.sh"
    run_verify "$d/root" "$d/share"
    local rc=$?; rm -rf "$d"
    [ "$rc" -ne 0 ] && ok "$n" || bad "$n" "a non-executable nvkvm-recovery.sh passed verification"
}

t_preflight_rejects_empty_share_file
t_verify_good
t_verify_zero_length
t_verify_truncated
t_verify_not_executable

echo
printf 'TOTAL %d   PASS %d   FAIL %d   SKIP %d\n' "$((PASS+FAIL+SKIP))" "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED:%s\n' "$FAILED_NAMES"
    exit 1
fi
exit 0
