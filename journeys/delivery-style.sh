#!/usr/bin/env bash
# done-done journey: the delivery-style table has one reader. The real jg-delivery-style.sh prints the row of each of today's four
# modes, refuses an unknown mode, and the behavior test (tests/jg-delivery-style.test.sh) runs after it.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
ds="$root/bin/jg-delivery-style.sh"
rc=0
{
  for m in no-mistakes direct-PR local-only local-trunk; do echo "== $m"; bash "$ds" "$m" || rc=1; done
  echo "== bogus"; bash "$ds" bogus && rc=1
  bash "$root/tests/jg-delivery-style.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped delivery-style table",
 "steps": ["print the row of each of the four modes", "ask for an unknown mode and require a refusal", "run the behavior test, which also checks that no row names a prover"],
 "result": "each of the four modes prints its line, what it adds and how it joins main; an unknown mode is refused; no row names a prover"}
JSON
exit "$rc"
