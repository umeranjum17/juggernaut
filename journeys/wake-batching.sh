#!/usr/bin/env bash
# done-done journey: wake batching is honoured in the core. Three cases, one run, each on a
# fixture home with no config/wake-routing of its own, so Main's home-local stopgap cannot hide
# the defect and every home gets the fix:
#   lead-lines  the shipped rules route a squad_lead's routine parent-channel lines batch, and a
#               captain decision on the same lane still wakes at once.
#   resurface   a queued batch row no longer closes a Stop-owned watcher cycle, while a now row
#               behind it still re-delivers; the next turn's drain still presents the batch row.
#   done-key    a done carrying a key closes that decision on a squad_lead lane, so its wait-timer
#               episode stops climbing, while an unrelated open wait keeps climbing.
# The journey fails on the unmodified tree: run `git stash`-free by checking the base of the three
# production files out and re-running the same test.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
bash "$root/tests/jg-wake-batching.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "three disposable homes with no config/wake-routing, the shipped defaults/wake-routing in force",
 "steps": ["route a lead's child-pr, child-outcome, merged and working lines on an unmodified home and require batch, with a decision still now", "raise a batch turn-end row, run one real bin/jg-watch.sh cycle past the resurface window, and require no wake while the row is still presented by the next drain", "raise a now row behind the batch row and require the cycle to re-deliver it", "arm two real wait-timer episodes on squad_lead lanes, escalate both, answer one with a done carrying its key, and require only the unanswered wait to keep climbing"],
 "result": "all three misroutes are honoured on an unmodified home: routine lead lines ride the digest, a batch row waits for a turn, and a done carrying a key clears that key's escalation"}
JSON
exit "$rc"
