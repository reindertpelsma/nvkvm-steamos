#!/usr/bin/env bash
# A `\`-continued line followed by a comment line ends the command AT the
# comment.  Every later argument is dropped, the command still runs, and
# nothing fails -- so `bash -n` passes and the shell reports success.
#
# This is not hypothetical: an explanatory comment placed between two -virtfs
# arguments in steamos-container-entrypoint.sh truncated QEMU's command line,
# silently discarding the data share, vdagent, audio, QMP, serial, monitor and
# -display.  The VM booted fine and the broker sat at its placeholder forever.
#
# Usage: tests/no_comment_in_continuation.sh [files...]   (default: tracked .sh)
set -uo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -gt 0 ]; then
    files=("$@")
else
    mapfile -t files < <(git ls-files '*.sh' 'scripts/*' 'docker/*' 2>/dev/null \
                         | while read -r f; do
                               [ -f "$f" ] || continue
                               case "$f" in *.sh) echo "$f";; *)
                                   head -c2 "$f" 2>/dev/null | grep -q '^#!' && echo "$f";;
                               esac
                           done)
fi

fail=0
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    awk -v F="$f" '
        # Only a CODE line ending in `\` matters.  A comment line ending in `\`
        # (usage examples in header blocks) continues nothing executable.
        prev !~ /^[ \t]*#/ && prev ~ /\\[ \t]*$/ && $0 ~ /^[ \t]*#/ {
            printf "%s:%d: comment inside a \\-continued command -- everything\n", F, NR
            printf "%s:%d:   after this line is silently dropped from the command.\n", F, NR
            printf "%s:%d:   offending line: %s\n", F, NR, $0
            bad = 1
        }
        { prev = $0 }
        END { exit bad ? 1 : 0 }
    ' "$f" || fail=1
done

if [ "$fail" -ne 0 ]; then
    echo "FAIL: comment(s) found inside line continuations"
    exit 1
fi
echo "ok: no comments inside line continuations ($# given, ${#files[@]} scanned)"
