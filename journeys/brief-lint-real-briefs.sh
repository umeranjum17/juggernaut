#!/usr/bin/env bash
# Drive the real brief lint over the shipped include file and every real brief named in
# JG_BRIEF_LINT_BRIEFS (space-separated paths, read only), keeping each finding and exit code.
# tests/jg-brief-lint.test.sh owns the fixture cases; this journey is the run on real text.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
{
  for brief in "$root/defaults/brief-include.md" ${JG_BRIEF_LINT_BRIEFS:-}; do
    echo "\$ bin/jg-brief-lint.sh $brief"
    "$root/bin/jg-brief-lint.sh" "$brief"
    echo "exit $?"
  done
} > "$evidence/real-briefs.txt" 2>&1
cat "$evidence/real-briefs.txt"
# A finding is exit 1; only a refused input (exit 2) fails the journey.
! grep -qx 'exit 2' "$evidence/real-briefs.txt" || exit 1
cat > "$evidence/steps.json" <<JSON
{"target":{"version":"$(git -C "$root" rev-parse HEAD)"},
 "start":"The shipped rule table and include file, and the real worker briefs named in JG_BRIEF_LINT_BRIEFS.",
 "steps":["Lint the shipped include file defaults/brief-include.md.","Lint each named real brief and keep every finding line and exit code."],
 "result":"Each real brief's disagreeing rules, missing skill names and byte budget are printed with their line numbers, and the exit code says whether there was a finding."}
JSON
