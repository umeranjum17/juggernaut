#!/usr/bin/env bash
# done-done journey: the per-model Claude account map. A Claude lane whose model has a line in
# config/claude-account-by-model launches, records and relaunches on that account; every other model keeps
# the home's pin; a home with no map is unchanged; a malformed map refuses the spawn.
# tests/jg-spawn-account-by-model.test.sh owns the cases (T1 to T4) on one disposable home and project.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-spawn-account-by-model.test.sh" > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a disposable home whose Claude workers are pinned to one account folder, with a map sending claude-sonnet-5-5 to a second folder and a fake terminal that records every launch line",
 "steps": ["spawn a real Claude lane with --model claude-sonnet-5-5 and read its launch line and task record", "relaunch that lane from its record", "spawn a Claude lane with --model claude-opus-5-5", "remove the map and spawn a Sonnet lane", "write a malformed map and spawn a Sonnet lane"],
 "result": "Sonnet runs, records and relaunches on the mapped folder, Opus and a map-less Sonnet keep the pin folder, and a malformed map refuses the spawn with no task record"}
JSON
exit "$rc"
