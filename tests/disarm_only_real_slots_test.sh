#!/bin/bash
# disarm_only_real_slots_test.sh — the OTA hook must disarm boot SLOTS, and must
# never invent images.
#
# MEASURED on a real OTA (2026-08-29): `steamos-bootconf list-images` returned
#
#     B dev Desktop Documents Downloads Music Pictures Public Templates Videos A
#
# i.e. the XDG directories of /home/deck, passed straight through. `--set` does
# not validate the image name, so the old loop wrote
# /esp/SteamOS/conf/Desktop.conf and eight more, MANUFACTURING bogus images that
# then show up in every later list-images. SteamOS's own chainloader picks from
# those entries -- that is how `set-mode reboot-other` once selected an image
# called 'dev' and left a machine unbootable.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DIR/boot/image/nvkvm-ota.sh"
rc=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# The exact list the field reported, in the order it came back.
REAL_LIST="B dev Desktop Documents Downloads Music Pictures Public Templates Videos A"

# Only A and B have a rootfs partset, which is what makes them slots.
mkdir -p "$work/partsets/A" "$work/partsets/B"
: > "$work/partsets/A/rootfs"; : > "$work/partsets/B/rootfs"

# Stand in for the two bootconf calls and record every image `--set` touches.
mkdir -p "$work/bin"
cat > "$work/bin/steamos-bootconf" <<'STUB'
#!/bin/bash
case "${1:-}" in
  this-image)  echo A ;;
  list-images) echo "$NVKVM_TEST_LIST" ;;
  config)      # --image NAME --set key value
      img=""; for ((i=1;i<=$#;i++)); do [ "${!i}" = "--image" ] && { j=$((i+1)); img="${!j}"; }; done
      echo "$img" >> "$NVKVM_TEST_TOUCHED"
      ;;
esac
STUB
chmod +x "$work/bin/steamos-bootconf"

export PATH="$work/bin:$PATH"
export NVKVM_TEST_LIST="$REAL_LIST"
export NVKVM_TEST_TOUCHED="$work/touched"
: > "$NVKVM_TEST_TOUCHED"

# Run the real function, with the partset root redirected at the fixture.
fn="$(awk '/^disarm_other\(\) \{/,/^\}/' "$HOOK")"
[ -n "$fn" ] || { echo "FAIL: could not extract disarm_other from $HOOK"; exit 1; }
fn="${fn//\/dev\/disk\/by-partsets/$work/partsets}"
log() { :; }
eval "$fn"
disarm_other

touched="$(tr '\n' ' ' < "$NVKVM_TEST_TOUCHED" | sed 's/ *$//')"

if [ "$touched" = "B" ]; then
    echo "ok: disarmed exactly the other real slot (B)"
else
    echo "FAIL: expected to touch only 'B', touched: '${touched:-nothing}'"; rc=1
fi

for bogus in Desktop Documents Downloads Music Pictures Public Templates Videos; do
    case " $touched " in
        *" $bogus "*) echo "FAIL: touched '$bogus' -- this MANUFACTURES a bogus image"; rc=1 ;;
    esac
done
case " $touched " in *" A "*) echo "FAIL: disarmed the running slot"; rc=1 ;; esac

# A slot-shaped name with no partset must still be refused: 'dev' is the one
# that actually broke a machine.
case " $touched " in
    *" dev "*) echo "FAIL: touched 'dev', which has no rootfs partset"; rc=1 ;;
    *) echo "ok: 'dev' refused -- no rootfs partset" ;;
esac

# And the guard must be the partset, not a hardcoded name blocklist: a third
# real slot must still be disarmable.
mkdir -p "$work/partsets/C"; : > "$work/partsets/C/rootfs"
export NVKVM_TEST_LIST="A B C Desktop"
: > "$NVKVM_TEST_TOUCHED"
disarm_other
t2="$(tr '\n' ' ' < "$NVKVM_TEST_TOUCHED" | sed 's/ *$//')"
if [ "$t2" = "B C" ]; then
    echo "ok: a new real slot is still disarmed (not a hardcoded allowlist)"
else
    echo "FAIL: expected 'B C', got '${t2:-nothing}'"; rc=1
fi

exit $rc
