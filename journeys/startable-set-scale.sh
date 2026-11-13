#!/usr/bin/env bash
# done-done journey: the startable set on a real 60,000-row Beads store. It drives the real
# `bin/jg-backlog.sh ready --spawnable` 20 times and saves the answer and each run's time as
# startable-set.txt in the evidence folder, beside the test's own log.
# Expected: only the one startable ticket is named, and the median of 20 runs is under 1 second and the slowest under 2.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${DONE_DONE_EVIDENCE_ROOT:?run through done-done}"
jq -n --arg v "juggernaut $(git -C "$REPO" rev-parse --short HEAD)" '{target: {version: $v}, start: "a real Beads store of 60,000 rows with one startable ticket and five that must stay out",
  steps: ["ask the home for its startable tickets with jg-backlog.sh ready --spawnable", "ask again, 20 runs in a row"],
  result: "only the one startable ticket is named, and the median of 20 runs is under 1 second and the slowest under 2"}' > "$DONE_DONE_EVIDENCE_ROOT/steps.json"
exec bash "$REPO/tests/jg-backlog-spawnable-scale.test.sh"
