#!/usr/bin/env bash
# done-done journey: host load admission. A fresh lane on a machine whose load has stayed above its limit for the
# window waits queued (exit 75, a deferred: line, no task record), the running lane is untouched, and the lane
# launches once the load is back under the limit. tests/jg-spawn-load-admission.test.sh owns the cases on one
# disposable main home, one lead home and one project.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-spawn-load-admission.test.sh" > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a disposable main home with one running lane, a host load file one over 2 times the cores, and the load alarm's record of the first sample above the limit",
 "steps": ["write a load history 11 minutes above the limit and spawn a real ship", "read its exit code, its deferred: line, its backlog item and the running lane's record", "drop the load to the limit and spawn the deferred lane again", "set config/reaper-load-minutes to 20, then config/reaper-load-factor to 3, then config/reaper-off, and spawn under the same load", "spawn from a lead home bound to the main home, with and without the main home's history"],
 "result": "the loaded spawn exits 75 with the load named, writes no record, leaves its item queued and the running lane's record unchanged; it launches once the load is at the limit; the window and the factor come from config, reaper-off defers nothing; the lead home is deferred by the main home's history"}
JSON
exit "$rc"
