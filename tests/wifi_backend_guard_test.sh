#!/bin/bash
# wifi_backend_guard_test.sh — the wifi-backend switch must not strand
# NetworkManager on a guest with no wifi radio.
#
# Steam's own steamos-wifi-set-backend-privileged runs, under `set -euo pipefail`:
#
#     systemctl stop NetworkManager
#     ...
#     iw phy phy0 interface add wlan0 type station     <-- fails: no radio here
#     systemctl restart NetworkManager                 <-- never reached
#
# leaving NM stopped and the setup wizard on "No networks found" forever, on a
# guest whose wired link is up.  steamos_boot.sh appends `|| true` to that one
# command.  This asserts the BEHAVIOUR, not the text: that the unpatched shape
# really does abort before the restart, and the patched one really does reach it.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
rc=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# The shape of Valve's function, with `iw` guaranteed to fail as it does on a
# machine with no phy0.
make_helper() {
    cat > "$1" <<'EOF'
#!/bin/bash
set -euo pipefail
ensure_default_interface() {
        iw phy phy0 interface add wlan0 type station
        sleep 0s
}
echo STOPPED_NM
ensure_default_interface
echo RESTARTED_NM
EOF
    chmod +x "$1"
}

export PATH="$work/bin:$PATH"
mkdir -p "$work/bin"
printf '#!/bin/sh\nexit 1\n' > "$work/bin/iw"      # no phy0 on this machine
chmod +x "$work/bin/iw"

# 1. the bug reproduces without the guard
make_helper "$work/unpatched.sh"
out="$("$work/unpatched.sh" 2>/dev/null)"
if printf '%s' "$out" | grep -q RESTARTED_NM; then
    echo "FAIL: the unpatched shape reached the restart -- this test proves nothing"
    rc=1
else
    echo "ok: unpatched aborts before restarting NetworkManager (the bug)"
fi

# 2. boot.sh still carries the guard, and it is the `|| true` form
if ! grep -q 'iw phy phy0 interface add wlan0 type station' "$BOOT"; then
    echo "FAIL: steamos_boot.sh no longer patches the wifi-backend helper"
    rc=1
else
    echo "ok: steamos_boot.sh still patches the wifi-backend helper"
fi

# 3. the guarded form actually reaches the restart
make_helper "$work/patched.sh"
sed -i 's|^\([[:space:]]*\)iw phy phy0 interface add wlan0 type station$|\1iw phy phy0 interface add wlan0 type station \|\| true|' \
    "$work/patched.sh"
if ! bash -n "$work/patched.sh" 2>/dev/null; then
    echo "FAIL: the patched helper is not valid bash"
    rc=1
fi
out="$("$work/patched.sh" 2>/dev/null)"
if printf '%s' "$out" | grep -q RESTARTED_NM; then
    echo "ok: guarded form reaches the NetworkManager restart despite iw failing"
else
    echo "FAIL: guarded form STILL does not restart NetworkManager"
    rc=1
fi

# 4. and steamos_boot.sh is applying exactly that guard
if grep -q 'iw phy phy0 interface add wlan0 type station \\|\\| true' "$BOOT"; then
    echo "ok: steamos_boot.sh appends the || true guard"
else
    echo "FAIL: steamos_boot.sh does not append '|| true' to the iw command"
    rc=1
fi

[ $rc -eq 0 ] && echo "PASS: the wifi-backend switch cannot strand NetworkManager"
exit $rc
