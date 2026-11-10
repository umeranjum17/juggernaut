#!/usr/bin/env bash
# done-done journey: the Claude 1M context window. A Claude lane on an account the home lists in
# config/claude-1m-accounts launches and records its model's [1m] id, a relaunch keeps it, and an
# id already ending in [1m], an unlisted account and a codex lane stay as chosen.
# tests/jg-spawn-model.test.sh owns the cases (T9 to T11) on one disposable home and project.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-spawn-model.test.sh" > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a disposable home whose Claude workers are pinned to the ordinary account, listed in config/claude-1m-accounts, with a fake terminal that records every launch line",
 "steps": ["spawn a real Claude lane with --model claude-opus-5-5 and read its launch line and task record", "relaunch that lane from its record", "spawn a Claude lane with --model claude-fable-5-2[1m]", "list only another account and spawn a Claude lane with --model claude-sonnet-5-5", "spawn a codex lane with --model gpt-5.6-sol"],
 "result": "the listed-account lane runs and records claude-opus-5-5[1m] and keeps it after the relaunch, the [1m] id is not doubled, and the unlisted-account and codex lanes keep the model as chosen"}
JSON
exit "$rc"
