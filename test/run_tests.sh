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
echo "== validate(): its claims must match its evidence ====================="

# A fake machine that validate() should be perfectly happy with. Every negative
# test below turns exactly one thing off, so if this one ever stops passing the
# rest prove nothing — which is why it is asserted first.
#
# The failures being pinned here were both REAL and both reported success:
#   - the guest module oopsing in nvkvm_send_sync on every open of the device,
#     while validate() returned 0 because the module was in /proc/modules;
#   - kwin crash-looping with no desktop at all, while the caller printed
#     "validation OK -- handing over to the desktop".
make_healthy_fake() {   # <dir>  -> echoes the env prefix to use
    local d="$1"
    mkdir -p "$d/proc" "$d/dev" "$d/sys/class/drm/card0/device" "$d/bin" "$d/etc/vulkan/icd.d"
    printf 'nvkvm_guest 262144 0 - Live 0x0000000000000000 (OE)\n' > "$d/proc/modules"
    : > "$d/dev/nvidiactl"                     # openable regular file
    mkdir -p "$d/drivers/nvidia"
    ln -sfn "$d/drivers/nvidia" "$d/sys/class/drm/card0/device/driver"
    : > "$d/etc/vulkan/icd.d/nvidia_icd.json"
    # dmesg: a clean boot, and ldconfig: a complete GL stack.
    printf '#!/bin/sh\necho "[    1.0] nvkvm: NVIDIA GPU passthrough guest module loaded"\n' > "$d/bin/dmesg"
    printf '#!/bin/sh\necho "\tlibGLX_nvidia.so.0 (libc6,x86-64) => /usr/lib/libGLX_nvidia.so.0"\n' > "$d/bin/ldconfig"
    chmod +x "$d/bin/dmesg" "$d/bin/ldconfig"
}

# Run validate() out of $TREE against a fake machine. The ICD path is absolute
# in the script, so the fake supplies one of the two real locations by way of a
# temporary override only where the script allows it; everything else is
# redirected through the script's own path variables.
run_validate() {   # <fakedir> [extra shell to eval after sourcing]
    local d="$1" extra="${2:-}"
    ( set +e
      PATH="$d/bin:$PATH"
      export NVKVM_PROC_MODULES="$d/proc/modules"
      export NVKVM_DEV_NVIDIACTL="$d/dev/nvidiactl"
      export NVKVM_DRM_CLASS_DIR="$d/sys/class/drm"
      export NVKVM_VULKAN_ICD_PATHS="$d/etc/vulkan/icd.d/nvidia_icd.json"
      # shellcheck disable=SC1090
      . "$BOOT_LIB"
      log() { :; }; warn() { :; }; err() { :; }
      [ -n "$extra" ] && eval "$extra"
      validate
      printf 'RC=%d UNVERIFIED=%s\n' "$?" "$([ -n "$VALIDATE_UNVERIFIED" ] && echo yes || echo no)" >&3
    ) 3>&1 >/dev/null 2>&1
}

validate_testable() {
    grep -q '^PROC_MODULES=' "$BOOT_LIB" && grep -q '^DEV_NVIDIACTL=' "$BOOT_LIB"
}

t_validate_healthy() {
    local n=validate_passes_a_healthy_fake_machine
    if ! validate_testable; then skip "$n" "this tree's validate() reads hardcoded paths; use test/revert_validate.sh to make an old validate() testable"; return; fi
    local d; d="$(mktemp -d)"; make_healthy_fake "$d"
    local out; out="$(run_validate "$d")"
    rm -rf "$d"
    case "$out" in
        "RC=0 "*) ok "$n" ;;
        *) bad "$n" "a healthy fake machine did not pass: $out — every case below would be vacuous" ;;
    esac
}

# THE regression. Module loaded, device node present, userspace complete, DRM
# node bound to nvidia — and the kernel has already oopsed inside the module.
# The old validate() returned 0 for this, and the caller announced the desktop.
t_validate_oops() {
    local n=validate_fails_when_the_kernel_has_faulted_inside_the_module
    if ! validate_testable; then skip "$n" "this tree's validate() reads hardcoded paths; use test/revert_validate.sh to make an old validate() testable"; return; fi
    local d; d="$(mktemp -d)"; make_healthy_fake "$d"
    cat > "$d/bin/dmesg" <<'EOF'
#!/bin/sh
cat <<'DM'
[   55.303161] BUG: kernel NULL pointer dereference, address: 0000000000000000
[   55.309736] Oops: Oops: 0000 [#1] SMP NOPTI
[   55.321576] RIP: 0010:nvkvm_send_sync+0xeb/0x240 [nvkvm_guest]
[   55.349698] Call Trace:
[   55.364220]  nvkvm_open+0xb1/0x1e0 [nvkvm_guest 657351842df4c49ea6eec8e0fec6848fe1867552]
DM
EOF
    chmod +x "$d/bin/dmesg"
    local out; out="$(run_validate "$d")"
    rm -rf "$d"
    case "$out" in
        "RC=0 "*) bad "$n" "validate() reported success on a system that had already oopsed in nvkvm_send_sync" ;;
        *)        ok "$n" ;;
    esac
}

# The other half of the same false pass: the node exists, and opening it — the
# first thing every GL/CUDA client does — fails.
t_validate_unopenable() {
    local n=validate_fails_when_the_device_node_exists_but_cannot_be_opened
    if ! validate_testable; then skip "$n" "this tree's validate() reads hardcoded paths; use test/revert_validate.sh to make an old validate() testable"; return; fi
    local d; d="$(mktemp -d)"; make_healthy_fake "$d"
    chmod 000 "$d/dev/nvidiactl"
    local out
    if [ "$(id -u)" = 0 ]; then
        # root ignores mode bits, so make the open fail for a reason it cannot
        # override: replace the node with a dangling symlink.
        rm -f "$d/dev/nvidiactl"; ln -s "$d/dev/does-not-exist" "$d/dev/nvidiactl"
        # ...but [ -e ] follows symlinks, so ALSO prove the CLASS-4 branch is not
        # what is firing: use a real file whose open is refused by a stub.
        rm -f "$d/dev/nvidiactl"; : > "$d/dev/nvidiactl"
        out="$(run_validate "$d" 'can_open_device() { return 1; }')"
    else
        out="$(run_validate "$d")"
    fi
    rm -rf "$d"
    case "$out" in
        "RC=0 "*) bad "$n" "validate() reported success although the device node could not be opened" ;;
        *)        ok "$n" ;;
    esac
}

# A compositor opens a DRM node, not /dev/nvidiactl. With none bound to the
# nvidia driver the session lands on the emulated VGA — everything else green.
t_validate_no_drm() {
    local n=validate_fails_when_no_drm_node_is_bound_to_the_nvidia_driver
    if ! validate_testable; then skip "$n" "this tree's validate() reads hardcoded paths; use test/revert_validate.sh to make an old validate() testable"; return; fi
    local d; d="$(mktemp -d)"; make_healthy_fake "$d"
    mkdir -p "$d/drivers/bochs-drm"
    ln -sfn "$d/drivers/bochs-drm" "$d/sys/class/drm/card0/device/driver"
    local out; out="$(run_validate "$d")"
    rm -rf "$d"
    case "$out" in
        "RC=0 "*) bad "$n" "validate() reported success with no nvidia DRM node — the desktop could not be on nvkvm" ;;
        *)        ok "$n" ;;
    esac
}

# Finding nothing in a log you cannot read is not the same as finding nothing in
# a clean one. The run may still pass, but it must not pretend it checked.
t_validate_unreadable_dmesg() {
    local n=validate_records_that_it_could_not_read_the_kernel_log
    if ! validate_testable; then skip "$n" "this tree's validate() reads hardcoded paths; use test/revert_validate.sh to make an old validate() testable"; return; fi
    local d; d="$(mktemp -d)"; make_healthy_fake "$d"
    printf '#!/bin/sh\nexit 1\n' > "$d/bin/dmesg"; chmod +x "$d/bin/dmesg"
    local out; out="$(run_validate "$d")"
    rm -rf "$d"
    case "$out" in
        *"UNVERIFIED=yes") ok "$n" ;;
        *) bad "$n" "the kernel log was unreadable and the run did not record it as unverified: $out" ;;
    esac
}

# This one asserts on the wording, deliberately: the defect IS the claim. The
# success path must state what it did not check, and must not assert that the
# desktop is fine — it is ordered before display-manager.service and cannot know.
t_do_boot_claim() {
    local n=the_success_message_does_not_claim_the_desktop
    if ! validate_testable; then skip "$n" "this tree's validate() reads hardcoded paths; use test/revert_validate.sh to make an old validate() testable"; return; fi
    local d; d="$(mktemp -d)"; make_healthy_fake "$d"
    local out
    out="$( ( set +e
        PATH="$d/bin:$PATH"
        export NVKVM_PROC_MODULES="$d/proc/modules" NVKVM_DEV_NVIDIACTL="$d/dev/nvidiactl" \
               NVKVM_DRM_CLASS_DIR="$d/sys/class/drm" \
               NVKVM_VULKAN_ICD_PATHS="$d/etc/vulkan/icd.d/nvidia_icd.json"
        # shellcheck disable=SC1090
        . "$BOOT_LIB"
        do_install() { return 0; }
        modprobe()   { return 0; }
        validate()   { return 0; }
        do_boot ) 2>&1 )"
    rm -rf "$d"
    local why=""
    case "$out" in
        *"handing over to the desktop"*) why="it still says 'handing over to the desktop'" ;;
    esac
    case "$out" in
        *"NOT CHECKED"*) : ;;
        *) why="${why:+$why; }it does not say what it did not check" ;;
    esac
    [ -z "$why" ] && ok "$n" || bad "$n" "$why"
}

t_validate_healthy
t_validate_oops
t_validate_unopenable
t_validate_no_drm
t_validate_unreadable_dmesg
t_do_boot_claim

echo
printf 'TOTAL %d   PASS %d   FAIL %d   SKIP %d\n' "$((PASS+FAIL+SKIP))" "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED:%s\n' "$FAILED_NAMES"
    exit 1
fi
exit 0
