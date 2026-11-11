#!/usr/bin/env bash
# Real cleanup and brief creation with local-only landed work and a backlog larger than argv allows.
set -eu
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}
head=$(git -C "$root" rev-parse HEAD)
bash "$root/tests/jg-teardown.test.sh" --local-trunk > "$out/$head-cleanup.log" 2>&1
bash "$root/tests/jg-teardown-core.test.sh" > "$out/$head-core.log" 2>&1
bash "$root/core/owner-rules/tests/owner-rules.test.sh" "$root" > "$out/$head-owner-rules.log" 2>&1
# A missing fixture dependency must not turn this proof into a successful skip.
grep -q 'local trunk cleanup: held' "$out/$head-cleanup.log"
grep -q 'all jg-teardown-core tests passed' "$out/$head-core.log"
grep -q 'PASS owner-rules' "$out/$head-owner-rules.log"
cat > "$out/steps.json" <<JSON
{"target":{"version":"$head"},
 "start":"isolated homes, real task records, real Git repositories with a bare origin and no release ref, and a real Beads backlog",
 "steps":["run unforced cleanup for a clean local-only task whose HEAD is on its recorded local trunk",
 "try unlanded work, pushed but unlanded work, dirty work and a non-trunk project: each refuses and retains the copy and task record",
 "clean a landed task held for the captain: the unanswered question remains open",
 "clean a landed task after trunk rollover with no original trunk branch",
 "run the shared landed and safety commands against real Git histories",
 "create instructions through the real brief command with a small backlog",
 "import 5160 real backlog rows with IDs whose JSON exceeds 128 KiB, then create instructions for an existing parent near the end",
 "try a missing parent and a missing owner ask with that large backlog: both refuse without writing instructions"],
 "result":"clean landed trunk tasks close without a release push; unlanded and dirty work and unanswered questions stay protected; brief creation accepts valid parents beyond the argv limit and keeps its refusal rules"}
JSON
printf 'PASS trunk cleanup and large-backlog brief creation at %s\n' "$head"
