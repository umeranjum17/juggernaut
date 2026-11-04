#!/usr/bin/env bash
# done-done journey: the spawn dispatch profile. A spawn resolves its harness, model and effort
# from the dispatch profile and refuses what the profile does not allow before it provisions anything.
# tests/jg-spawn-dispatch-profile.test.sh owns the cases, each on its own disposable home and project;
# the native-Ultra refusals prove an unsupported harness or model is refused with its own message and
# leaves no metadata, no lifecycle wiring and no launched agent.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-spawn-dispatch-profile.test.sh" > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "disposable homes and projects, one per case, with a fake launcher that records every launch",
 "steps": ["run the real bin/jg-spawn.sh for each harness, model, effort and delivery mode the dispatch profile covers", "spawn native Ultra on pi and pi-signed and require the native flag, not a thinking level", "spawn native Ultra on claude, codex, a non-native pi model, the default pi model and an empty native model, each in its own case, and require the native-only refusal, no metadata, no lifecycle wiring and no launched agent"],
 "result": "every spawn launches with the profile it was given or is refused before provisioning, and every refusal case runs"}
JSON
exit "$rc"
