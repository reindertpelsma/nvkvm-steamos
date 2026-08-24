#!/usr/bin/env bash
# revert_validate.sh — build a tree whose validate() is the OLD one, so
# test/run_tests.sh can be shown failing without the fix.
#
#   ./test/revert_validate.sh <base-commit> <output-dir>
#   ./test/run_tests.sh --tree <output-dir>
#
# WHY THIS EXISTS RATHER THAN JUST `git archive <base>`.
#
# The old validate() reads /proc/modules and /dev/nvidiactl as literals, so on
# a machine with no nvkvm it cannot be driven at all — pointed at an unmodified
# old tree the validate tests SKIP, and a skip is not a proof. This produces the
# old LOGIC with only those literals redirected, so the same tests drive it.
#
# The substitution is mechanical and is printed in full at the end: what you see
# is what was tested. It changes only where the old function looks, never what
# it concludes — no check is added, removed or reordered.

set -euo pipefail

BASE="${1:?usage: revert_validate.sh <base-commit> <output-dir>}"
OUT="${2:?usage: revert_validate.sh <base-commit> <output-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rm -rf "$OUT"; mkdir -p "$OUT"
git -C "$HERE" archive HEAD | tar -x -C "$OUT"

OLD="$(git -C "$HERE" show "$BASE:boot/steamos_boot.sh")"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$OLD" > "$tmp/old.sh"

python3 - "$tmp/old.sh" "$OUT/boot/steamos_boot.sh" <<'PY'
import re, sys

old_path, new_path = sys.argv[1], sys.argv[2]
old = open(old_path, encoding="utf-8").read()
new = open(new_path, encoding="utf-8").read()

# Pull the historical validate() out verbatim: from its banner to the Part 2 banner.
m = re.search(r"# ── Validation.*?(?=# ── Part 2 ─)", old, re.S)
assert m, "could not find the old validate() block"
old_validate = m.group(0)

# Redirect ONLY the literals, so the same fake machine can drive it.
subs = [
    ('grep -qw "$MODULE_MOD" /proc/modules', 'grep -qw "$MODULE_MOD" "$PROC_MODULES"'),
    ('[ -e /dev/nvidiactl ]', '[ -e "$DEV_NVIDIACTL" ]'),
    ('[ -e /etc/vulkan/icd.d/nvidia_icd.json ] || [ -e /usr/share/vulkan/icd.d/nvidia_icd.json ]',
     'for icd in $VULKAN_ICD_PATHS; do [ -e "$icd" ] && break; done; [ -e "${icd:-/nonexistent}" ]'),
]
for a, b in subs:
    assert a in old_validate, "expected literal not in the old validate(): " + a
    old_validate = old_validate.replace(a, b)

# The old code had no VALIDATE_UNVERIFIED and no validate_verified_summary;
# supply inert definitions so the harness's reporting still runs.
old_validate = ('VALIDATE_UNVERIFIED=""\n'
                'validate_verified_summary() { printf \'(old validate: no summary)\\n\'; }\n\n'
                + old_validate)

# Splice it in, replacing the new one.
m2 = re.search(r"# ── Validation.*?(?=# ── Part 2 ─)", new, re.S)
assert m2, "could not find the new validate() block"
new = new[:m2.start()] + old_validate + new[m2.end():]

# ...and put the old success message back.
old_msg = 'validate && { log "validation OK -- handing over to the desktop"; return 0; }'
assert old_msg in old, "old success message not found in the base commit"
m3 = re.search(r"    if validate; then\n.*?\n    fi\n", new, re.S)
assert m3, "could not find the new do_boot success block"
new = new[:m3.start()] + "    " + old_msg + "\n" + new[m3.end():]

open(new_path, "w", encoding="utf-8").write(new)
print("=== the validate() that will be tested ===")
print(old_validate)
PY

bash -n "$OUT/boot/steamos_boot.sh"
echo "reverted tree: $OUT"
