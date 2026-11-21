#!/usr/bin/env bash
# done-done journey: a wake acknowledgement cannot skip an unanswered captain
# note. The real bin/jg-inbox.sh writes and answers the note, the real
# bin/jg-wake-drain.sh presents and acknowledges, the real bin/jg-wake-bus.sh is
# the bus both share, and the real bin/jg-session-start.sh prints the digest.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
echo "journey run $(git -C "$root" rev-parse HEAD) ${RUN_ID:-run}" > "$out"
bash "$root/tests/jg-captain-note-ack-gate.test.sh" >> "$out" 2>&1 || rc=1
# The digest case lives in the session-start suite; run only that one there.
JG_SESSION_START_ONLY=test_captain_notes_lead_the_digest_before_the_lock \
  bash "$root/tests/jg-session-start.test.sh" >> "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture home with a captain inbox note written and acknowledged through the real bin/jg-inbox.sh and bin/jg-wake-drain.sh",
 "steps": ["show the unanswered note leading a drain as a must-answer list",
           "refuse an acknowledgement whose batch still holds the unanswered note",
           "let the acknowledgement through once a reply is recorded",
           "let the acknowledgement through once the note itself is acknowledged",
           "keep a note whose wake row was already retired in front of every later drain",
           "judge an acknowledgement on its own batch, so a later note is presented next time",
           "print the must-answer list at the top of the session digest, and nothing once answered"],
 "result": "no wake acknowledgement retires a batch with an unanswered captain note, and an unanswered note leads every drain and the digest"}
JSON
exit "$rc"
