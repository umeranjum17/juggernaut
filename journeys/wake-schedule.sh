#!/usr/bin/env bash
# done-done journey: the wake schedule. A supervisor wakes at once only for what needs a person;
# everything else rides one digest at most every 30 minutes. Each case runs on a fixture home with
# no config/wake-routing of its own, so the shipped defaults/wake-routing is what is proved:
#   routine    a routine item raises no wake from a real watcher cycle, appears in the next digest,
#              the digest is sent once per window, and never when nothing waits.
#   heartbeat  an away-mode heartbeat over an unchanged fleet raises no wake; a changed fleet does.
#   done-key   a done carrying a key closes that key's wait, so it never re-pings
#              (tests/jg-wake-batching.test.sh, run beside the schedule test).
#   planned    a pause naming its future event raises no wake and no re-ping; a block with no
#              clearing condition still escalates.
#   immediate  a captain answer, a red gate, a host alarm, a stuck worker and a finished
#              deliverable still wake at once, even with the digest due.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{ bash "$root/tests/jg-wake-schedule.test.sh" && bash "$root/tests/jg-wake-batching.test.sh"; } > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "disposable homes with no config/wake-routing, the shipped defaults/wake-routing in force",
 "steps": ["raise a routine ready-work item, run a real bin/jg-watch.sh cycle and require no wake, rewind the digest stamp past 30 minutes and require one digest wake, then require no second digest in the window and none on an empty queue", "record the fleet fingerprint, run an away-mode heartbeat cycle over the unchanged fleet and require no wake, add a status line and require the heartbeat to wake", "answer a keyed wait with a done and require its escalation to stop climbing", "route a pause that names a future time as batch (status line, stale recheck, timer) and a blocked wait with no clearing condition as now, then require a real cycle over the planned wait to raise no wake", "route a captain inbox note, a failed check, a host alarm, a stale worker and ready/done status lines and require now, then raise a captain note with the digest due and require its own wake"],
 "result": "routine items ride one digest, an unchanged fleet is silent, a done closes its key, and every urgent class still wakes at once"}
JSON
exit "$rc"
