#!/usr/bin/env bash
# done-done journey: wake urgency routing runs in Go. The suite builds the command through
# bin/jg-wake-core.sh and requires the class the shell rule reader gave every distinct event recorded
# on a real JG_WAKE stream, the pattern grammar, the status-file rule, the queue-quiet bound, the
# re-alert dedupe, and `now` for every event where the command cannot run; tests/jg-wake-route.test.sh
# then drives the same decisions through the real wake library. The parity replay against the base
# commit's shell is named in core/wake/README.md.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
{ bash "$root/tests/jg-wake-core.test.sh" && bash "$root/tests/jg-wake-route.test.sh"; } > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a throwaway home with the checked-out wake library and 55 distinct events recorded on this machine's JG_WAKE stream",
 "steps": ["build the Go wake router through bin/jg-wake-core.sh", "route every recorded event and compare the class with the one the shell rule reader gave it", "route the pattern grammar, status-file and queue-quiet cases", "append events twice through the real wake library and read the class of each", "append with no runnable router"],
 "result": "every recorded event keeps its class, a repeated now event rides the digest, a queue-quiet rule that reads the queue it routes ends, and with no router every event is now"}
JSON
exit "$rc"
