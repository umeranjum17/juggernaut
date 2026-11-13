#!/usr/bin/env bash
# done-done journey: the four delivery words are one list and one lint lists stage-sense "live" used alone in tracked text.
# The real core/stage-words/lint.sh prints the words, lints the repository report-only and under --strict; the behavior test
# (tests/jg-stage-words.test.sh) checks each case against fixture text.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
lint="$root/core/stage-words/lint.sh"
rc=0
{
  bash "$lint" --words || rc=1
  n=$(bash "$lint" | wc -l); echo "report-only: $n tracked lines use live alone, exit status of the lint itself: $(bash "$lint" >/dev/null; echo $?)"
  bash "$lint" --strict >/dev/null; echo "strict exit status on the repository: $?"
  bash "$root/tests/jg-stage-words.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped word list and the tracked files of the repository",
 "steps": ["print the four delivery words", "lint every tracked file report-only", "lint again with --strict", "lint fixture text with live alone, a live test, a live pane, code quotes and names"],
 "result": "the four words print, the report-only lint lists the lines and exits 0, --strict exits 1 on a finding, and the fixture cases list only the stage-sense lines"}
JSON
exit "$rc"
