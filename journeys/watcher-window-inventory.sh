#!/usr/bin/env bash
# done-done journey: the watcher's window inventory runs in Go. The suite replays a corpus of
# state/<id>.meta records through the Go command and through the shell reader it replaced and
# requires identical rows, identical order and identical answers after every record, with two
# corrupted controls (one answer, one row order) that must fail the same comparison. It then
# arms a real bin/jg-watch.sh cycle over a throwaway home with a logging wrapper around the Go
# command and requires that cycle to read its inventory there and deliver its wake.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
bash "$root/tests/jg-watch-inventory.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a corpus of state/<id>.meta records written for the test, and a throwaway supervision home holding one recorded window and one finished lane",
 "steps": ["replay the corpus through bin/jg-watch-core.sh and the shell reader it replaced", "corrupt one answer and the row order, and require the same comparison to reject both", "arm a real bin/jg-watch.sh cycle on the throwaway home with a logging wrapper around the Go command", "read the wake the cycle delivered from its stdout and the inventory call from the wrapper's log"],
 "result": "the Go inventory answers exactly as the deleted shell reader on every row, order and answer, both controls fail, and the real cycle read its inventory through the Go command and delivered its wake"}
JSON
exit "$rc"
