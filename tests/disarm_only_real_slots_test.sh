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

# A, B and the phantom 'dev' have configs; the XDG names do not.
mkdir -p "$work/partsets/A" "$work/partsets/B"
: > "$work/partsets/A/rootfs"; : > "$work/partsets/B/rootfs"

# Only real slots and the phantom 'dev' have configs. The XDG names do NOT --
# that is the whole point: they must never acquire one.
export NVKVM_TEST_CONFDIR="$work/conf"; mkdir -p "$NVKVM_TEST_CONFDIR"
for c in A B dev; do : > "$NVKVM_TEST_CONFDIR/$c.conf"; done

# Stand in for the two bootconf calls and record every image `--set` touches.
mkdir -p "$work/bin"
cat > "$work/bin/steamos-bootconf" <<'STUB'
#!/bin/bash
case "${1:-}" in
  this-image)  echo A ;;
  list-images) echo "$NVKVM_TEST_LIST" ;;
  config)      # --image NAME [--no-create] --set key value
      img=""; nocreate=0
      for ((i=1;i<=$#;i++)); do
          [ "${!i}" = "--image" ] && { j=$((i+1)); img="${!j}"; }
          [ "${!i}" = "--no-create" ] && nocreate=1
      done
      # Model the real CLI: without --no-create it INVENTS the config file.
      if [ ! -e "$NVKVM_TEST_CONFDIR/$img.conf" ]; then
          if [ "$nocreate" = 1 ]; then
              echo "Image config for $img does not exist" >&2; exit 1
          fi
          : > "$NVKVM_TEST_CONFDIR/$img.conf"   # the bug being guarded against
      fi
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
log() { :; }
eval "$fn"
disarm_other

touched="$(tr '\n' ' ' < "$NVKVM_TEST_TOUCHED" | sed 's/ *$//')"

if [ "$touched" = "B dev" ]; then
    echo "ok: disarmed the other real slot AND the phantom 'dev'"
else
    echo "FAIL: expected to touch 'B dev', touched: '${touched:-nothing}'"; rc=1
fi

for bogus in Desktop Documents Downloads Music Pictures Public Templates Videos; do
    case " $touched " in
        *" $bogus "*) echo "FAIL: touched '$bogus' -- this MANUFACTURES a bogus image"; rc=1 ;;
    esac
done
case " $touched " in *" A "*) echo "FAIL: disarmed the running slot"; rc=1 ;; esac

# 'dev' MUST be disarmed. An existing dev.conf with no rootfs behind it is what
# `set-mode reboot-other` selects in preference to the real other slot -- MEASURED,
# and it is what left a machine at a GRUB prompt. A "real slots only" filter would
# skip it and leave the trap armed.
case " $touched " in
    *" dev "*) echo "ok: the phantom 'dev' image is disarmed" ;;
    *) echo "FAIL: 'dev' left armed -- reboot-other will select it over the real slot"; rc=1 ;;
esac

# Nothing may have been conjured into existence.
created=""
for f in "$NVKVM_TEST_CONFDIR"/*.conf; do
    b="$(basename "$f" .conf)"
    case "$b" in A|B|dev) ;; *) created="$created $b" ;; esac
done
if [ -z "$created" ]; then
    echo "ok: no image config was manufactured"
else
    echo "FAIL: manufactured image config(s):$created"; rc=1
fi

# And the guard must be the partset, not a hardcoded name blocklist: a third
# real slot must still be disarmable.
: > "$NVKVM_TEST_CONFDIR/C.conf"
export NVKVM_TEST_LIST="A B C Desktop"
: > "$NVKVM_TEST_TOUCHED"
disarm_other
t2="$(tr '\n' ' ' < "$NVKVM_TEST_TOUCHED" | sed 's/ *$//')"
if [ "$t2" = "B C" ]; then
    echo "ok: any image that really has a config is disarmed (no hardcoded allowlist)"
else
    echo "FAIL: expected 'B C', got '${t2:-nothing}'"; rc=1
fi

exit $rc
