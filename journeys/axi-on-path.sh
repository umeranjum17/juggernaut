#!/usr/bin/env bash
# juggernaut-axi on PATH: a clean HOME, the real session-start bootstrap, then the command answers and its migration row reads live.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
bash "$root/tests/jg-axi-link.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a clean throwaway HOME with no juggernaut-axi on PATH and the migration row absent",
 "steps": ["run bin/jg-bootstrap.sh", "run juggernaut-axi --version from PATH", "read the migration row", "run the bootstrap again", "link a second home, delete the first", "place a foreign file at the same path and run the bootstrap", "run install.sh --dry-run"],
 "result": "the command is on PATH and the row is live, a second run changes nothing, two homes each answer for themselves, a foreign file is never replaced, and a dry run writes nothing"}
JSON
exit "$rc"
