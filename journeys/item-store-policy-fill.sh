#!/usr/bin/env bash
# done-done journey: policy.py --import --fill-missing writes version 1 for a registry project with no policy row (jg-6sa2s). The real
# policy adapter, schema and bin/jg-project-mode.sh run in throwaway homes; the item store's own proofs run beside it.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{
  bash "$root/tests/item-store.test.sh" || rc=1
  bash "$root/tests/item-store-registry-switch.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a throwaway main home whose item store already ran the one cut-over import, then a registry that lists two more projects",
 "steps": ["run policy.py --import --fill-missing", "run it again", "run the plain --import", "ask jg-project-mode.sh for a filled local-trunk project", "open a store made by the older schema"],
 "result": "only the two projects with no row get version 1 and the existing row is unchanged, a second run fills nothing, the plain import still refuses, the project reads as local-trunk, and the older store takes the new rule"}
JSON
exit "$rc"
