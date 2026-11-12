#!/usr/bin/env bash
# Drive the real wake classifier with a worker's progress lines beside a done line.
set -eu
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
printf '%s\n' 'progress [at=1700000001]: 1 of 5' 'progress: 2 of 5' 'done [at=1700000009]: ready in branch feature/x' > "$evidence/lines.status"
bash "$root/bin/jg-classify.sh" facts < "$evidence/lines.status" | cut -f1,2,6,7 > "$evidence/facts.tsv"
want=$(printf '0\t0\t0\t1\n0\t0\t0\t1\n1\t1\t0\t1')
[ "$(cat "$evidence/facts.tsv")" = "$want" ]
printf 'Two progress lines are events, are not terminal, are not captain-relevant and are not unrecognized prefixes, so they wake nobody; the done line still wakes.\n' > "$evidence/result.log"
cat > "$evidence/steps.json" <<JSON
{"target":{"version":"$(git -C "$root" rev-parse HEAD)"},
 "start":"A worker appended two progress lines and then a done line to its status file.",
 "steps":["Classify the three lines through the real jg-classify facts command.","Check that each progress line is an event that is neither terminal nor captain-relevant nor an unrecognized prefix.","Check that the done line is still terminal and captain-relevant."],
 "result":"The progress lines wake nobody and the done line still wakes the lead."}
JSON
cat "$evidence/result.log"
