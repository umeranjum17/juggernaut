#!/usr/bin/env bash
# done-done journey: a planned wait. A wait on a known future event (a change held for the next release
# branch) names when it clears with `until <UTC time>`. Until that time it raises no wake and no re-ping,
# for a `paused:` line and for a `blocked:` line alike; a blocked wait that names no clearing condition
# still climbs to its owner, and a planned wait whose time has passed is an open blocker again.
# Real watcher and drain cycles run over disposable homes (tests/jg-planned-wait.test.sh owns the cases).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-planned-wait.test.sh" > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a disposable home with four idle lanes: a paused wait and a blocked wait that each name a clearing time three hours ahead, a blocked wait with no clearing condition, and a blocked wait whose named time has passed",
 "steps": ["run real watcher cycles with every lane's wait older than the escalation thresholds", "require no wake and no stale alert for the two planned waits", "require the owner and then Main rung for the open blocker and for the planned wait whose time passed"],
 "result": "a planned wait raises no wake and no re-ping before its clearing time, and a blocked wait with no clearing condition still escalates"}
JSON
exit "$rc"
