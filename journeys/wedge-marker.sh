#!/usr/bin/env bash
# done-done journey: the away-mode wedge alarm. A supervisor that cannot deliver an escalation raises one
# alert by the captain channel and keeps a durable marker; the marker is rewritten on every re-alarm and a
# reader that tests it for content must never find it empty.
# tests/jg-bus.test.sh owns the cases, the wedge alert and the marker rewrite race among them.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/bin/jg-test-run.sh" tests/jg-bus.test.sh > "$out" 2>&1 || rc=$?
tail -n 40 "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a disposable home with a fake bus sink and a supervisor target that does not exist",
 "steps": ["raise the wedge alarm twice in one window and require one alert event and one published alert", "rewrite the wedge marker 60 times while a reader tests it for content, and require the reader never sees it empty", "require the marker to hold the alarm text and no temporary marker to remain"],
 "result": "the wedge alarm reaches the captain channel once per window and its marker is always replaced whole"}
JSON
exit "$rc"
