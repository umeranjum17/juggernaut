#!/usr/bin/env bash
# done-done journey: the watcher liveness beacon, read the way a lead's supervision check reads
# it. A live watcher stays supervised through a due-check sweep longer than the stale grace - the
# false "the watcher beacon is Ns old and no turn is running" alarm that cost main a turn - a
# killed watcher reads as unsupervised inside the grace window, and an actionable exit leaves the
# home supervised once the hand-off stamp ages out. The proof itself lives in
# tests/jg-watch-beacon.test.sh, which arms the real watcher and owns these cycles; this journey
# records that run for review.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
bash "$root/tests/jg-watch-beacon.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "two throwaway homes on the file wake queue: one registers four slow checks, so every due-check sweep runs twice as long as a 4 s stale grace, and one has a task signal waiting behind a 10 minute old beacon",
 "steps": ["arm the real watcher in the sweep home and sample the supervision read across a whole sweep", "kill the watcher on a fresh beacon and sample the supervision read until it reports unsupervised", "arm the real watcher in the signal home and let it end its cycle on the task signal", "age the hand-off stamp out and take the supervision read"],
 "result": "the live sweep stayed supervised, the killed watcher was reported unsupervised inside the grace window, and the actionable exit left the home supervised"}
JSON
exit "$rc"
