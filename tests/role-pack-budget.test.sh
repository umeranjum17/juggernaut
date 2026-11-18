#!/usr/bin/env bash
# Report each role pack's size against its budget, and the skill descriptions' total. Report only: exits 0
# unless the generator fails or a rule of AGENTS.md has no row in docs/roles/rules.tsv (a row's section
# and text cover the line).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PACK=$ROOT/bin/jg-role-pack.sh
TSV=$ROOT/docs/roles/rules.tsv
rc=0

size() { # <label> <file> <max-lines|-> <max-bytes|->
  local l b v=ok
  l=$(wc -l < "$2"); b=$(wc -c < "$2")
  { [ "$3" != - ] && [ "$l" -gt "$3" ]; } && v=over
  { [ "$4" != - ] && [ "$b" -gt "$4" ]; } && v=over
  echo "$1 $l $b ${3}/${4} $v"
}

tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
for r in all main lead worker critic; do
  "$PACK" "$r" > "$tmp/$r" || { echo "FAIL: generator failed for $r" >&2; rc=1; }
done
cat "$tmp/all" "$tmp/main" > "$tmp/allmain"
size all "$tmp/all" 80 -
size main "$tmp/main" 120 16384
size all+main "$tmp/allmain" 199 24576
size lead "$tmp/lead" 120 -
size worker "$tmp/worker" 80 8000
size critic "$tmp/critic" 60 -

# the descriptions of every skill together, in characters (budget 8000)
chars=0
for f in "$ROOT"/.agents/skills/*/SKILL.md; do
  d=$(awk 'BEGIN{fm=0;in_d=0}
    /^---$/ {fm++; if (fm==2) exit; next}
    fm==1 && /^description:/ { sub(/^description:[ \t]*(>-?|\|-?)?[ \t]*/, ""); in_d=1; if ($0!="") print; next }
    fm==1 && in_d && /^[ \t]/ { sub(/^[ \t]+/, ""); print; next }
    fm==1 { in_d=0 }' "$f")
  chars=$((chars + ${#d}))
done
v=ok; [ "$chars" -gt 8000 ] && v=over
echo "skill-descriptions - $chars 8000 $v"

# every non-blank, non-heading AGENTS.md line is covered by a row of its section
missing=$(awk -F'\t' -v tsv="$TSV" '
  BEGIN { while ((getline line < tsv) > 0) { split(line, c, "\t"); if (c[1] != "id") rows[c[2] SUBSEP c[5]] = 1 } }
  /^# Juggernaut$/ { sec = "Preamble"; next }
  /^## / { sec = substr($0, 4); next }
  /^#/ { next }
  { t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t); sub(/^(- |[0-9]+\. )/, "", t); if (t == "") next
    if (!((sec SUBSEP t) in rows)) { print NR ": " t } }
' "$ROOT/AGENTS.md")
if [ -n "$missing" ]; then echo "FAIL: AGENTS.md lines with no row:" >&2; echo "$missing" >&2; rc=1; fi
exit $rc
