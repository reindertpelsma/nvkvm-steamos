#!/bin/bash
# wifi_radio_test.sh — the guest must be given a wifi radio, because SteamOS
# assumes one exists and strands NetworkManager when it does not.
#
# Setup sits on "No networks found" forever on a guest whose wired link is up
# and routing fine. steamos-manager's D-Bus SetWifiBackend writes the backend
# config, STOPS NetworkManager, then creates wlan0 on phy0 -- and a VM has no
# phy0, so it fails with `Exited 254` and NM is never restarted.
#
# THE SHELL SCRIPT IS A DECOY. steamos-wifi-set-backend-privileged contains the
# same logic and is the obvious thing to patch. It is NOT the path the OOBE
# takes; patching it changed nothing. The fix supplies the missing hardware --
# mac80211_hwsim, a software 802.11 radio already built for this kernel -- so
# Valve's own code succeeds unmodified.
#
# MEASURED on the PC 2026-08-28, with an UNPATCHED helper and hwsim loaded:
#   phy#0 / Interface wlan0 present, helper exit=0, NetworkManager active.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$DIR/boot/steamos_boot.sh"
rc=0

# 1. the radio is configured to load at boot
grep -q 'modules-load.d/nvkvm-wifi.conf' "$BOOT" \
    && echo "ok: boot.sh installs a modules-load entry for the radio" \
    || { echo "FAIL: no modules-load.d entry for the wifi radio"; rc=1; }
grep -q 'mac80211_hwsim' "$BOOT" \
    && echo "ok: the radio is mac80211_hwsim" \
    || { echo "FAIL: mac80211_hwsim is not referenced"; rc=1; }
grep -q 'options mac80211_hwsim radios=1' "$BOOT" \
    && echo "ok: exactly one radio is requested" \
    || { echo "FAIL: radios=1 is not set -- extra radios clutter the wifi list"; rc=1; }

# 2. it must be conditional: a kernel without the module must SAY so, not fail
#    silently, because the symptom (setup hangs) looks nothing like the cause
grep -q 'modinfo mac80211_hwsim' "$BOOT" \
    && echo "ok: presence of the module is checked before relying on it" \
    || { echo "FAIL: boot.sh assumes mac80211_hwsim exists"; rc=1; }
grep -q 'systemctl start NetworkManager' "$BOOT" \
    && echo "ok: the recovery command is printed when there is no radio" \
    || { echo "FAIL: no recovery instructions for a kernel without hwsim"; rc=1; }

# 3. the regression: we must NOT be patching Valve's shell helper any more.
#    It is not on the OOBE's path, so patching it gives false confidence.
grep -q 'iw phy phy0 interface add wlan0 type station \\|\\| true' "$BOOT" \
    && { echo "FAIL: boot.sh still patches the decoy shell helper"; rc=1; } \
    || echo "ok: boot.sh no longer patches the decoy shell helper"

# 4. the reason must be recorded, or the next person patches the decoy again
grep -q 'steamos-manager' "$BOOT" \
    && echo "ok: the real caller (steamos-manager) is named in the comment" \
    || { echo "FAIL: nothing records WHICH component strands NetworkManager"; rc=1; }

[ $rc -eq 0 ] && echo "PASS: the guest gets a radio, so SteamOS's own wifi setup completes"
exit $rc
