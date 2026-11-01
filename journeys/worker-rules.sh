#!/usr/bin/env bash
# Journey: the role-scoped instruction surface keeps every rule - the worker-rules test and the
# union check both pass, and the steps record names what was driven.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}
{ git -C "$root" rev-parse HEAD; bash "$root/tests/jg-worker-rules.test.sh"; "$root/bin/jg-worker-rules.sh" check; } > "$out/${RUN_ID:-worker-rules}.log" 2>&1
cat > "$out/steps.json" <<'JSON'
{"target":{"version":"jg-worker-rules.sh"},"start":"a clean checkout with defaults/worker-rules.tsv","steps":["run the worker-rules test","run jg-worker-rules.sh check"],"result":"check prints ok: the roles union equals the surface and every section and skill is read by a named role once"}
JSON
