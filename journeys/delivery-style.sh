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
  for m in no-mistakes direct-PR local-only local-trunk; do
    echo "== facts $m: local=$(bash "$ds" "$m" local && echo yes || echo no) review=$(bash "$ds" "$m" review && echo yes || echo no) trunk=$(bash "$ds" "$m" trunk && echo yes || echo no)"
  done
  # The mode-branch count of the plan (section 12, M7): lines that branch on a mode word in bin and core outside tests..
  pat='(local-only|local-trunk|direct-PR|no-mistakes)\)|= *"?(local-only|local-trunk|direct-PR|no-mistakes)"? *\]|== *"?(local-only|local-trunk|direct-PR|no-mistakes)'
  echo "== mode branch lines in bin and core: $(git -C "$root" grep -n -E "$pat" -- bin core ':!*test*' | wc -l) (76 on the trunk before this slice, 81 before J7)"
  echo "== bogus"; bash "$ds" bogus && rc=1
  bash "$root/tests/jg-delivery-style.test.sh" || rc=1
  echo "== per-mode briefs through jg-dod-lib.sh, which reads the table"
  bash "$root/tests/jg-dod-style-brief.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped delivery-style table",
 "steps": ["print the row of each of the four modes", "ask for an unknown mode and require a refusal", "run the behavior test, which also checks that no row names a prover", "render the four per-mode briefs through the library that reads the table and require them byte-equal to the recorded golden"],
 "result": "each of the four modes prints its line, what it adds and how it joins main; an unknown mode is refused; no row names a prover"}
JSON
exit "$rc"
