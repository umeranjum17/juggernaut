#!/usr/bin/env bash
# done-done journey: parked and finished lanes stop ringing. A pause parked to the placeholder date and a
# finished Recon whose owner call waits on its owner raise no timer wake over two hours of test clock; a blocked
# lane and a working lane under an open decision still ring.
# Real watcher and drain cycles run over disposable homes (tests/jg-wait-quiet.test.sh owns the cases).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-wait-quiet.test.sh" > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a disposable home with a lane paused to the placeholder date, a Recon with a done line over an open owner call, a working lane under an open decision, a blocked lane, and a pause whose real date has passed",
 "steps": ["run real watcher cycles while the test clock moves two hours", "require no episode and no timer wake for the parked lane and the finished Recon", "require the owner rung for the blocked lane, the working lane under a decision and the pause past its date"],
 "result": "parked and finished lanes raise no timer wake, and a blocked lane still rings"}
JSON
exit "$rc"
