#!/usr/bin/env bash
# done-done journey: the watcher's own-queue observation runs on the bus. The replay folds every
# recorded JG_WAKE event through the Go command and the shell reader it replaced and requires the same
# answer after each one (a corrupted control must fail), then a throwaway server and home prove the
# wake-watcher consumer: its acknowledged counter rises on real raises, the fold equals the read model,
# a restart and a lost fold are recovered, and the real watcher cycle re-delivers a stalled row with the
# queue file unreadable. The live-machine run is the probe: bin/jg-bus.sh probe wake-watcher before and
# after a real wake on a home whose stack is up.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
bash "$root/tests/jg-wake-watcher.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a throwaway accounts server and home, and 241 wake events recorded on this machine's JG_WAKE stream",
 "steps": ["replay every recorded event through the Go fold and the shell reader and compare the rows, the oldest row and the newest host-memory row after each", "replay again with one Go answer corrupted", "start the wake-watcher service and raise real wakes", "read bin/jg-bus.sh probe wake-watcher before and after", "acknowledge a wake, restart the service, delete its fold", "run the real watcher cycle with the queue file unreadable"],
 "result": "the Go fold equals the shell reader on every step, the corrupted control fails, the consumer's acknowledged counter rises with each event, the fold equals the read model, and the watcher re-delivers the stalled row from the service"}
JSON
exit "$rc"
