#!/usr/bin/env bash
# Drive the real spawn against matching and foreign fixture pool copies.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-spawn-clone-identity.test.sh" > "$out" 2>&1 || rc=$?
cat "$out"
printf '{"target":{"version":"%s"},"start":"fixture clones and leased pool copies","steps":["spawn with a dirty foreign copy and retain it on refusal","spawn with a matching copy"],"result":"foreign clone refused; matching clone launches"}\n' "$(git -C "$root" rev-parse --short HEAD)" > "$DONE_DONE_EVIDENCE_ROOT/steps.json"
exit "$rc"
