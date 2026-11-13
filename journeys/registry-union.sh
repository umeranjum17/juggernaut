#!/usr/bin/env bash
# done-done journey: registry files merge by union and the lint keeps each lane to its own block (slice H0). The real git rebase and the real
# bin/jg-registry-lint.sh run in a throwaway repo (tests/jg-registry-union.test.sh), then the real lint reads this repo's own registry files.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{
  bash "$root/tests/jg-registry-union.test.sh" || rc=1
  git -C "$root" check-attr merge .done-done.yaml docs/state-machines.md || rc=1
  bash "$root/bin/jg-registry-lint.sh" --base HEAD || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped .gitattributes and the real jg-registry-lint.sh command, in a throwaway repo and on this repo's own registry files",
 "steps": ["rebase two lanes that each add a journey and a table row", "lint a lane that only adds its own entries", "refuse a lane that edits another journey or row", "read the merge attribute and lint this repo's registry files"],
 "result": "the second lane rebases with no conflict and keeps both entries, the edit of another entry is refused with the entry named, and both registry files report merge: union"}
JSON
exit "$rc"
