#!/usr/bin/env bash
# done-done journey: a board answer reaches the task that asked. An answer to a card with no route file lands in the inbox of the task
# its card names (longest task-id prefix) in one pass and Main gets nothing; a card posted with bin/jg-question-card.sh always writes
# its route file (10 Nov 2026: the answer to fable-why-no-landing-wave1 reached no task and cost 1 hour 40 minutes).
# The real bin/jg-board-answers.sh and bin/jg-question-card.sh run in a fixture home (tests/jg-board-answers-route.test.sh owns the cases).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
env -u JG_TASK_ID bash "$root/tests/jg-board-answers-route.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture home with a question card whose route file is missing, and a card that names no task",
 "steps": ["the answer to the route-less card is read by the board-answers check", "the answer to a card naming no task is read", "a card is posted for a task and for Main"],
 "result": "the first answer lands in the owning task's inbox and Main gets nothing; the second still wakes Main; both posted cards have a route file"}
JSON
exit "$rc"
