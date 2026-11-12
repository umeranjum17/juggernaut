#!/usr/bin/env bash
# done-done journey: the delivery-style table has one reader. The real jg-delivery-style.sh prints the row of each of today's four
# modes, refuses an unknown mode, and the behavior test (tests/jg-delivery-style.test.sh) runs after it.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
ds="$root/bin/jg-delivery-style.sh"
rc=0
{
  for m in no-mistakes direct-PR local local-only local-trunk; do echo "== $m"; bash "$ds" "$m" || rc=1; done
  for m in no-mistakes direct-PR local local-only local-trunk; do
    echo "== facts $m: local=$(bash "$ds" "$m" local && echo yes || echo no) review=$(bash "$ds" "$m" review && echo yes || echo no) trunk=$(bash "$ds" "$m" trunk && echo yes || echo no)"
  done
  # The mode-branch count of the plan (section 12, M7): lines that branch on a mode word in bin and core outside tests..
  pat='(local-only|local-trunk|direct-PR|no-mistakes)\)|= *"?(local-only|local-trunk|direct-PR|no-mistakes)"? *\]|== *"?(local-only|local-trunk|direct-PR|no-mistakes)'
  echo "== mode branch lines in bin and core: $(git -C "$root" grep -n -E "$pat" -- bin core ':!*test*' | wc -l) (76 on the trunk before this slice, 81 before J7)"
  for m in no-mistakes direct-PR local-only local-trunk; do echo "== knob $m: $(bash "$ds" knob "$m")"; done
  # J8c: these four files read the table too, so the count for them is 0 (it was 10: jg-brief.sh 4, jg-fleet-snapshot.sh 4, jg-backlog-transition-lib.sh 1, jg-project-mode.sh 1).
  j8c=$(git -C "$root" grep -n -E "$pat" -- bin/jg-brief.sh bin/jg-fleet-snapshot.sh bin/jg-backlog-transition-lib.sh bin/jg-project-mode.sh | wc -l)
  echo "== mode branch lines in the J8c files: $j8c (10 before J8c)"; [ "$j8c" -eq 0 ] || rc=1
  echo "== trunk aliases the old note words read from: $(bash "$ds" --trunk-aliases | paste -sd' ' -)"; [ "$(bash "$ds" --trunk-aliases)" = local-trunk ] || rc=1
  echo "== bogus"; bash "$ds" bogus && rc=1
  bash "$root/tests/jg-delivery-style.test.sh" || rc=1
  echo "== per-mode briefs through jg-dod-lib.sh, which reads the table"
  bash "$root/tests/jg-dod-style-brief.test.sh" || rc=1
  bash "$root/tests/jg-local-mode.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped delivery-style table",
 "steps": ["print the row of each of the four modes", "ask for an unknown mode and require a refusal", "run the behavior test, which also checks that no row names a prover", "render the four per-mode briefs through the library that reads the table and require them byte-equal to the recorded golden", "land a lane with the old word and a lane with the new word in a fixture home: with yolo off a lane of mode local waits for a word, with yolo on it lands by itself"],
 "result": "each mode prints its line, what it adds and how it joins main; the two local rows are one row and the old words read as before; an unknown mode is refused; no row names a prover; a lane of mode local waits for a word with yolo off and lands by itself with yolo on"}
JSON
exit "$rc"
