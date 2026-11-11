#!/usr/bin/env bash
# done-done journey: a wait for a ticket ends by itself. A lane blocked `waits-for: A` is steered once, and its blocker
# closes with a resolved line, in the run that lands A, with no owner wake; the ladder's waits-for row takes a wait declared
# after the landing; a wait for a running ticket is quiet and rings once that lane is gone.
# Real core/trunk-landing over real git lanes (tests/jg-wait-next-step.test.sh) and real watcher cycles
# (tests/jg-wait-quiet.test.sh) own the cases.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{ bash "$root/tests/jg-wait-next-step.test.sh" && bash "$root/tests/jg-wait-quiet.test.sh"; } > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a disposable home with a ready lane A, a lane B blocked waits-for A, a lane blocked waits-for another ticket and a lane blocked for no ticket",
 "steps": ["land A through the landing check", "require one steer to B that closes its blocker key and a resolved line, and none to the others", "require no owner wake for B", "run watcher cycles for a lane waiting for a running ticket"],
 "result": "B resumes when A lands with no owner turn; a wait for a running ticket is quiet"}
JSON
exit "$rc"
