#!/usr/bin/env bash
# Journey: the release replay is run by the real command, bin/jg-ledger-reconcile.sh, on a fixture home with a git project, the trunk
# records and two releases. The first release holds a pre-ledger commit, landed commits, a recorded revert, an unrecorded revert, a
# merge and a repeated landing row; the second holds a rebased copy and a stray commit that no record explains. Cases:
# a) every commit of a release lands in one class and the class counts add up to the git total;
# b) the stray commit is printed as unexplained, listed first in the report, and the command exits 1;
# c) a landing whose sha is not in a release reads superseded-sha when a copy of its ticket is released, after-last-release when newer;
# d) without the stray commit the same fixture exits 0 and the report says nothing is unexplained;
# e) a landing row that vanishes leaves its commit unexplained, never dropped;
# f) a missing source record exits 2 and is named; the report lands in data/jg-ledger/reconcile.md.
# Usage: tests/jg-ledger-reconcile.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
BIN=$ROOT/bin/jg-ledger-reconcile.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
H=$d/home
P=$H/projects/proj
mkdir -p "$H/data" "$H/state" "$H/config" "$P"
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/ledger-reconcile.log}
fails=0
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=1700000000
# mkc <file> <subject> <day>: a commit on the current branch, dated by the day offset
mkc() { echo "$1" > "$P/$1"; git -C "$P" add "$1"; GIT_AUTHOR_DATE="@$((T + $3 * 86400)) +0000" GIT_COMMITTER_DATE="@$((T + $3 * 86400)) +0000" git -C "$P" commit -q -m "$2"; git -C "$P" rev-parse HEAD; }
t() { echo $((T + $1 * 86400)); }
git -C "$P" init -q -b trunk
P0=$(mkc p0 "old: before the records" 0)
A=$(mkc a "tkA: a" 2); B=$(mkc b "tkB: b" 2); C=$(mkc c "tkC: c" 2)
R=$(mkc r 'Revert "tkC: c"' 3)
U=$(mkc u 'Revert "hand made: u"' 3)
git -C "$P" checkout -q -b side "$U"
S=$(mkc s "tkS: s" 3)
git -C "$P" checkout -q trunk
GIT_AUTHOR_DATE="@$(t 4) +0000" GIT_COMMITTER_DATE="@$(t 4) +0000" git -C "$P" merge -q --no-ff side -m "Merge pull request #1 from side"
M=$(git -C "$P" rev-parse HEAD)
git -C "$P" checkout -q -b orig "$P0"
KS=$(mkc ks "tkK: as first landed" 5)
git -C "$P" checkout -q trunk
K=$(mkc k "tkK: k" 6)
X=$(mkc x "stray: a hand edit no record names" 7)
L=$(mkc l "tkL: l" 9)

{
  printf 'tkA\tproj\t%s\t%s\tfull\n' "$A" "$(t 2)"
  printf 'tkB\tproj\t%s\t%s\tfull\n' "$B" "$(t 2)"
  printf 'tkC\tproj\t%s\t%s\tfull\n' "$C" "$(t 2)"
  printf 'revert-tkC\tproj\t%s\t%s\treverts-%s\n' "$R" "$(t 3)" "${C:0:12}"
  printf 'tkS\tproj\t%s\t%s\tfull\n' "$S" "$(t 3)"
  printf 'tkADup\tproj\t%s\t%s\tfull\n' "$A" "$(t 3)"
  printf 'tkK\tproj\t%s\t%s\tfull\n' "$KS" "$(t 5)"
  printf 'tkL\tproj\t%s\t%s\tfull\n' "$L" "$(t 9)"
} > "$H/data/trunk-landings.tsv"
: > "$H/data/trunk-landing-proofs.tsv"; : > "$H/data/trunk-in-use.tsv"
printf 'proj\t2\ttrunk-v2\t%s\t%s\n' "$M" "$(t 5)" > "$H/data/trunk-versions.tsv"
rels() { # <second release head>
  printf 'proj\ttrunk\t%s\t6\t%s\thttps://example.test/pull/1\n' "$M" "$(t 4)" > "$H/data/trunk-releases.tsv"
  printf 'proj\ttrunk-v2\t%s\t2\t%s\thttps://example.test/pull/2\n' "$1" "$(t 8)" >> "$H/data/trunk-releases.tsv"
}
rels "$X"

run() { JG_HOME=$H bash "$BIN" 2>"$d/err"; }
rc=0; run > "$d/out" || rc=$?
REPORT=$H/data/jg-ledger/reconcile.md
cell() { awk -F'|' -v r="$1" -v c="$2" '$2 ~ "^ " r " $" { gsub(/ /, "", $c); print $c }' "$d/out"; }   # row <release>, column number of the table line (3 = commits)
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || cp "$d/out" "$DONE_DONE_EVIDENCE_ROOT/reconcile.md"

# a) classes of the first release: 8 commits = 4 landed, 1 revert, 1 unrecorded revert, 1 merge, 1 pre-ledger; 6 landing rows (4 + revert + repeat)
check "a: first release git commits" "$(cell trunk 3)" 8
check "a: first release landing rows" "$(cell trunk 4)" 6
check "a: first release ledger tickets" "$(cell trunk 5)" 4
check "a: first release classes" "$(for c in 6 7 8 9 10 11 12 13; do cell trunk $c; done | tr '\n' ' ')" "4 1 1 0 1 1 1 0 "
# second release: a rebased copy and the stray commit
check "a: second release classes" "$(for c in 3 4 6 7 8 9 10 11 12 13; do cell trunk-v2 $c; done | tr '\n' ' ')" "2 0 0 0 0 1 0 0 0 1 "
# b) unexplained
check "b: exit 1" "$rc" 1
check "b: the stray commit is printed as unexplained" "$(grep -c "commit ${X:0:12} is in no landing row" "$d/out")" 1
check "b: unexplained comes before the table" "$(awk '/^## Unexplained differences/ { u = NR } /^\| release/ { t = NR } END { print (u < t) ? "first" : "late" }' "$d/out")" first
check "b: the unexplained count is in the heading" "$(grep -c '^## Unexplained differences (1)$' "$d/out")" 1
check "b: nothing else is unexplained" "$(grep -c '^- juggernaut\|^- proj' "$d/out")" 1
check "b: the report file equals the printed report" "$(cmp -s "$REPORT" "$d/out" && echo same)" same
# c) landing-side classes
check "c: superseded sha" "$(grep -c "^- superseded-sha: ticket tkK landed as ${KS:0:12}" "$d/out")" 1
check "c: after the last release" "$(grep -c "^- after-last-release: ticket tkL" "$d/out")" 1
# d) the clean variant: the second release ends before the stray commit
rels "$K"; rc=0; run > "$d/out2" || rc=$?
check "d: a clean replay exits 0" "$rc" 0
check "d: nothing unexplained" "$(grep -c '^none: every difference has a class' "$d/out2")" 1
check "d: second release has the copy as its only commit" "$(awk -F'|' '$2 ~ /^ trunk-v2 $/ { gsub(/ /, "", $3); print $3 }' "$d/out2")" 1
check "d: the stray commit is outside every release" "$(grep -c "${X:0:12}" "$d/out2")" 0
# e) a landing record that vanishes: its commit is in the range with no row, and it is unexplained, never dropped
sed -i '1d' "$H/data/trunk-landings.tsv"   # tkA no longer has a landing row (the repeated tkADup row now lands the commit, under its own ticket)
rc=0; run > "$d/out3" || rc=$?
check "e: exit 0 because the repeat row now lands commit A" "$rc" 0
sed -i '1d;/^tkADup/d' "$H/data/trunk-landings.tsv"   # drop tkB too and the repeat: now A and B have no row at all
rc=0; run > "$d/out3" || rc=$?
check "e: commits with no row at all exit 1" "$rc" 1
check "e: each is named" "$(grep -c "commit \(${A:0:12}\|${B:0:12}\) is in no landing row" "$d/out3")" 2
# f) a missing source record
rm "$H/data/trunk-releases.tsv"
rc=0; run > "$d/out4" || rc=$?
check "f: a missing release record exits 2" "$rc" 2
check "f: it is named" "$([ "$(grep -c "missing source record: $H/data/trunk-releases.tsv" "$d/err")" -ge 1 ] && echo named)" named

[ "$fails" -eq 0 ] || { say "$fails check(s) failed"; exit 1; }
say "all checks passed"
