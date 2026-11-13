#!/usr/bin/env bash
# done-done journey: one fleet budget (H30c). The real core/lane-scale/fleet.sh `budget` and `slot take` add the slots of usable runners and keep a paid runner to the ledger cap; fixture
# runner records and health rows (tests/jg-fleet-budget.test.sh).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-fleet-budget.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a home with one own runner of 3 slots and one paid runner of 4 slots, both probed ok",
 "steps": ["paid cap 0: the budget is 5 slots and the paid runner is capped", "cap raised to 60 minutes: 9 slots", "60 paid minutes recorded: 5 slots again", "a sixth heavy run waits"],
 "result": "heavy slots are the sum of the host and the usable runners, and a paid runner counts only inside the daily cap"}
JSON
exit "$rc"
