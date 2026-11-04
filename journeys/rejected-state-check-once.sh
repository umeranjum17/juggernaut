#!/usr/bin/env bash
# done-done journey: a rejected state check alerts once per file, not once per watcher sweep. The real
# bin/jg-watch.sh runs one cycle at a time over fixture homes: the same rejected file alerts on its first
# sweep and stays silent after, a file whose bytes change alerts again, a second distinct file alerts naming
# only itself, and a file that is bound and then rejected again alerts again.
# tests/jg-rejected-state-check-once.test.sh owns the cases.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
bash "$root/tests/jg-rejected-state-check-once.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "throwaway homes with an executable state/<id>.check.sh that has no trust binding, the file wake queue, and the real bin/jg-watch.sh run for one cycle per sweep",
 "steps": ["sweep a rejected check twice and require one alert and one durable wake row", "rewrite its bytes and require a new alert", "add a second rejected check and require an alert naming only the new file", "register the check, sweep, remove its trust binding, sweep again and require an alert"],
 "result": "each rejected check file alerts once until its content or identity changes or it is fixed and rejected again"}
JSON
exit "$rc"
