#!/usr/bin/env bash
# done-done journey: .done-done.yaml holds each journey key once, and a duplicate is refused with its key named.
# The behavior test (tests/jg-done-yaml-dup-keys.test.sh) reads the shipped config, then a copy with one entry planted twice.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-done-yaml-dup-keys.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped .done-done.yaml of the repository",
 "steps": ["read every journey key of the shipped config and list any key that appears twice", "plant one journey entry a second time in a copy and run the same check on it"],
 "result": "the shipped config lists no duplicate key, and the copy is refused with the planted key and both line numbers named"}
JSON
exit "$rc"
