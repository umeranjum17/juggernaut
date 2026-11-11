#!/usr/bin/env bash
# done-done journey: a steer is one message with 5 states. The real jg-machine.sh lints the message table and lists its moves, the
# behavior test (tests/jg-machine-message.test.sh) sends real steers through jg-send.sh, reads the ticket and kind from the record
# and replays the inbox corpus against the table.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
jm="$root/bin/jg-machine.sh"
rc=0
{
  bash "$jm" check message || rc=1
  bash "$jm" events message || rc=1
  bash "$root/tests/jg-machine-message.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped message table and real steers sent through jg-send.sh with a stubbed terminal",
 "steps": ["lint the message table", "list its moves", "send three steers and read their ticket and kind from the record", "read each steer as one of five words", "replay the inbox corpus, including a ring that did not land, and refuse a ring after handled"],
 "result": "the table lints with 5 states and 8 moves, steers are counted from records, and the corpus replays with 0 findings"}
JSON
exit "$rc"
