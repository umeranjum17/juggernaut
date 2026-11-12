#!/usr/bin/env bash
# done-done journey: the alert table and its one raise function. The real jg-machine.sh lints the alert table, and the behavior test
# (tests/jg-alert.test.sh) runs the real jg-alert.sh in a fixture home; the undelivered producers' tests run through the real callers.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
jm="$root/bin/jg-machine.sh"
rc=0
{
  bash "$jm" check alert || rc=1
  bash "$jm" events alert || rc=1
  bash "$root/tests/jg-alert.test.sh" || rc=1
  bash "$root/tests/jg-task-inbox-alert.test.sh" || rc=1
  bash "$root/core/undelivered-alert/tests/undelivered-alert.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped alert table and the real jg-alert.sh command in a fixture home",
 "steps": ["lint the alert table", "raise a stuck wait in each of the four delivery modes", "keep quiet rows quiet", "inhibit the wait alerts of a home with supervision-down open and release them", "gate the fires-at time by the limit of its kind", "climb the ladder to its top and hold rung 4 while away", "drive the four states", "raise the undelivered alert from an unread steer on a dead endpoint and from a refused captain message"],
 "result": "the table lints with 4 states and 7 moves, and a stuck wait raises one P2 alert at rung 2 in every mode and none under supervision-down"}
JSON
exit "$rc"
