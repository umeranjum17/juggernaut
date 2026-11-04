#!/usr/bin/env bash
# done-done journey: a red CI run is never re-run to see if it passes. bin/jg-ci-rerun.sh refuses a red run
# until its root-cause ticket carries a "root-cause:" line, then re-runs it; a green run re-runs freely.
# The real script runs over the real backlog and a recorded forge (tests/jg-ci-rerun.test.sh owns the cases).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/ci-rerun-guard.txt
rc=0
echo "run: $(basename "$DONE_DONE_EVIDENCE_ROOT") at $(git -C "$root" rev-parse --short HEAD)" > "$out"
bash "$root/tests/jg-ci-rerun.test.sh" >> "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a disposable home with a backlog and a recorded forge holding two red runs and one green run",
 "steps": ["ask to re-run a red run with no ticket and require a refusal", "file its ticket without a root-cause line and require a refusal", "add a root-cause line and require one re-run", "re-run a green run and require it passes on", "ask to re-run a second red run and require a refusal"],
 "result": "a red run is re-run only after its ticket names the root cause"}
JSON
exit "$rc"
