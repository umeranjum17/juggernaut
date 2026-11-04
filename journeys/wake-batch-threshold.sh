#!/usr/bin/env bash
# done-done journey: wake batch threshold. Routine (`batch`) wakes are held and released as ONE wake
# when the count reaches `set digest-count` (default 5) or the oldest has waited `set digest-minutes`
# (default 15), whichever comes first; urgent classes never wait. Runs on fixture homes with no
# config/wake-routing of their own, so the shipped defaults/wake-routing is what is proved.
#   count    four routine rows raise no wake from a real bin/jg-watch.sh cycle; the fifth releases
#            all five as one digest wake; the count starts again from zero.
#   delay    two routine rows are not released at 14 minutes and are released at 16.
#   knob     a home's config/wake-routing `set digest-count 2` releases at two rows; 0 turns the
#            count trigger off.
#   urgent   captain inbox, failed, blocked, needs-decision, done, security and stale events route
#            now, and a blocked status line wakes on its own with routine rows held.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
WAKE_SCHEDULE_ONLY=batch-threshold bash "$root/tests/jg-wake-schedule.test.sh" > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "disposable homes with no config/wake-routing, the shipped defaults/wake-routing in force",
 "steps": ["queue four routine merge notices, run a real watcher cycle and require no wake, queue the fifth and require one digest wake naming five", "queue four more and require no early wake, the fifth releases again", "queue two routine rows with the digest stamp 14 minutes old and require no release, at 16 minutes require one digest wake", "set digest-count 2 in the home's config and require release at two rows, set 0 and require no count release", "route captain, failed, blocked, needs-decision, done, security and stale events as now, then with routine rows held append a blocked status line and require the watcher to wake on it alone, not as a digest"],
 "result": "routine wakes are batched at 5 rows or 15 minutes, the knobs override, and urgent classes bypass the batch"}
JSON
exit "$rc"
