#!/usr/bin/env bash
# done-done journey: tool models. config/tool-models.json moves a tool's model with a file edit alone.
# tests/jg-tool-models.test.sh runs the real squad lead launch lookup and the supervision engine lookup on a
# disposable home and prints each answer before and after the edit. core/merge-card/tests/merge-card-e2e.sh
# does the same for the done-done judge, with a stub that records which model judged.
# core/pipeline-quota-failover/tests/pi-quota-failover-route.test.sh does it for the no-mistakes review chain.
# core/account-pool/tests/tool-models.test.sh does the same for the default route chain and the pool's default Claude model.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{
  bash "$root/tests/jg-tool-models.test.sh" &&
    bash "$root/core/merge-card/tests/merge-card-e2e.sh" &&
    bash "$root/core/pipeline-quota-failover/tests/pi-quota-failover-route.test.sh" &&
    bash "$root/core/account-pool/tests/tool-models.test.sh"
} > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "disposable homes with the built-in model choice and no config/tool-models.json",
 "steps": ["read the squad lead harness, model and effort through the real bin/jg-harness.sh and record the built-in answer", "write config/tool-models.json naming Sonnet and read again", "rewrite the file naming DeepSeek and read again", "remove the file and read again", "name DeepSeek for the done-done judge and run the real merge-card check against a stub judge route that records the model", "name a model for the voice rewrite, the inbox side-question model and the voice relay and read each through its real script with a fake model command", "name a different route chain and a different pool Claude model, run the real jg-model-pool, then remove the file", "write a bad harness, a bad effort, text that is not JSON and a model the allow-list refuses, and require one plain TOOL_MODELS line and the built-in model each time"],
 "result": "one file edit moves the squad lead to Sonnet then to DeepSeek and moves the done-done judge to DeepSeek, with no code change; removing the file or writing a bad entry gives back the built-in model with a plain reason"}
JSON
exit "$rc"
