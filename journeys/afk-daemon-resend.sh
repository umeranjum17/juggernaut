#!/usr/bin/env bash
# done-done journey: the afk daemon submits its own unsent text. When a swallowed Enter leaves the daemon's digest typed in the
# supervisor composer, the next try submits it once with Enter only and the next digest follows (fric-composer-resend; crewhouse's
# lead log held 349 of 400 lines "inject deferred: supervisor composer not confirmed-empty").
# The real bin/jg-supervise-daemon.sh runs against a private tmux server (tests/jg-supervise-daemon-resend.test.sh owns the case).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
env -u JG_TASK_ID bash "$root/tests/jg-supervise-daemon-resend.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a private tmux pane that drops every Enter of the daemon's first injection, with the afk daemon running",
 "steps": ["a captain-relevant status is written and the daemon types its digest", "the pane swallows all five Enters", "a second status is written"],
 "result": "the first digest is submitted exactly once on the next try, without retyping, and the second digest follows as its own line"}
JSON
exit "$rc"
