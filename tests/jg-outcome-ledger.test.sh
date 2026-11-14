#!/usr/bin/env bash
# Journey: the outcome ledger is rebuilt from a fixture home's own records by the real command, bin/jg-outcome-ledger.sh.
# The fixture home holds a git project and the five trunk records. Cases:
# a) a landing with a proof, an in-use row and a release whose rollover shows it merged: built, landed, in-use, released;
# b) a landing whose release is only raised (no rollover yet): release-raised, never released;
# c) a bypassed landing: proof and bypass columns say bypass, and a record that does not hold reads bypass-unverified;
# d) a revert: the reverted commit has a reverted row and the flag reverted on every row; the revert commit is no landing;
# e) a duplicate landing row: one row flagged duplicate, with no later stage;
# f) a landing with no proofs row reads none-recorded and has no built row;
# g) a rerun prints the same rows; a missing source record is named on stderr with exit 2 and the rest still prints.
# Usage: tests/jg-outcome-ledger.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
BIN=$ROOT/bin/jg-outcome-ledger.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
H=$d/home
P=$H/projects/proj
mkdir -p "$H/data" "$H/state" "$H/config" "$P"
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/outcome-ledger.log}
fails=0
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git -C "$P" init -q -b trunk
mkc() { echo "$1" > "$P/$1"; git -C "$P" add "$1"; git -C "$P" commit -q -m "$1"; git -C "$P" rev-parse HEAD; }
A=$(mkc a); B=$(mkc b); C=$(mkc c); R=$(mkc r); E=$(mkc e); F=$(mkc f); G=$(mkc g)
T=1700000000; D1=2023-11-14; D2=2023-11-15; D3=2023-11-16
t() { echo $((T + $1 * 86400)); }   # day offsets from 2023-11-14

# records
printf 'tkA\tproj\t%s\t%s\tfull\n' "$A" "$(t 0)" > "$H/data/trunk-landings.tsv"
{
  printf 'tkB\tproj\t%s\t%s\tfull\n' "$B" "$(t 0)"
  printf 'tkC\tproj\t%s\t%s\tfull\n' "$C" "$(t 0)"
  printf 'revert-tkC\tproj\t%s\t%s\treverts-%s\n' "$R" "$(t 1)" "${C:0:12}"
  printf 'tkDup\tproj\t%s\t%s\tfull\n' "$A" "$(t 1)"
  printf 'tkE\tproj\t%s\t%s\tfull\n' "$E" "$(t 1)"
  printf 'tkF\tproj\t%s\t%s\tfull\n' "$F" "$(t 1)"
  printf 'tkG\tproj\t%s\t%s\tfull\n' "$G" "$(t 1)"
} >> "$H/data/trunk-landings.tsv"
{
  printf 'tkA\tproj\t%s\t%s\treceipt=PASS@abc\tsignature=absent\tmerge-card=present\n' "$A" "$(t 0)"
  printf 'tkC\tproj\t%s\t%s\treceipt=PASS@abc\tsignature=absent\tmerge-card=absent\n' "$C" "$(t 0)"
  printf 'tkE\tproj\t%s\t%s\treceipt=PASS@abc\tsignature=present\tmerge-card=present\n' "$E" "$(t 1)"
  printf 'tkG\tproj\t%s\t%s\treceipt=PASS@abc\tsignature=absent\tmerge-card=absent\n' "$G" "$(t 1)"
} > "$H/data/trunk-landing-proofs.tsv"
# in use at A and at E (so B, C, R, E are contained by E; F and G are not)
printf 'proj\t%s\t%s\tlive\n' "$A" "$(t 0)" > "$H/data/trunk-in-use.tsv"
printf 'proj\t%s\t%s\tlive,waiver=x\n' "$E" "$(t 1)" >> "$H/data/trunk-in-use.tsv"
printf 'proj\t%s\t%s\thook-failed\n' "$G" "$(t 1)" >> "$H/data/trunk-in-use.tsv"
# release of trunk at A, rollover to trunk-v2 at day 2 (so A, and only what A contains, is Released); a later release row on trunk-v2 at G is only raised
printf 'proj\ttrunk\t%s\t1\t%s\thttps://example.test/pull/1\n' "$A" "$(t 1)" > "$H/data/trunk-releases.tsv"
printf 'proj\ttrunk-v2\t%s\t4\t%s\thttps://example.test/pull/2\n' "$G" "$(t 3)" >> "$H/data/trunk-releases.tsv"
printf 'proj\t2\ttrunk-v2\t%s\t%s\n' "$A" "$(t 2)" > "$H/data/trunk-versions.tsv"
# bypass: tkB is genuinely bypassed; tkF has a record that names no bypass row
printf 'bp1\tticket\ttkB\tword1\t0\t-\tstanding\t0\t-\t-\n' > "$H/config/proof-bypass"
. "$ROOT/bin/jg-bypass-record-lib.sh"
jg_bypass_record_write "$H/state" tkB tkB "$B" bp1 ticket word1 "$(t 0)"
jg_bypass_record_write "$H/state" tkF tkF "$F" bpX ticket wordX "$(t 1)"

ledger() { JG_HOME=$H bash "$BIN" build; }
row() { ledger | awk -F'\t' -v t="$1" -v s="$2" -v f="${3:-}" '$2 == t && $5 == s && (f == "" || $8 == f) { print }'; }
field() { printf '%s' "$1" | cut -f"$2"; }

rc=0; ledger >/dev/null 2>"$d/err" || rc=$?
check "a clean fixture exits 0" "$rc" 0
check "a clean fixture names nothing on stderr" "$(cat "$d/err")" ""
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || ledger > "$DONE_DONE_EVIDENCE_ROOT/ledger.tsv"
check "columns line" "$(bash "$BIN" columns)" "$(printf 'date\tticket\tproject\tcommit\tstage\tproof\tbypass\tflag')"

# a) a full life
check "a: built row" "$(row tkA built)" "$(printf '%s\ttkA\tproj\t%s\tbuilt\treceipt+merge-card\t-\t-' "$D1" "${A:0:12}")"
check "a: landed row" "$(row tkA landed -)" "$(printf '%s\ttkA\tproj\t%s\tlanded\treceipt+merge-card\t-\t-' "$D1" "${A:0:12}")"
check "a: in-use row" "$(field "$(row tkA in-use)" 1)" "$D1"
check "a: released row dated by the rollover" "$(row tkA released)" "$(printf '%s\ttkA\tproj\t%s\treleased\treceipt+merge-card\t-\t-' "$D3" "${A:0:12}")"
# b) raised only
check "b: raised release is not released" "$(row tkG released)" ""
check "b: raised release row" "$(field "$(row tkG release-raised)" 5)" "release-raised"
check "b: tkG is not in use (hook-failed)" "$(row tkG in-use)" ""
check "b: tkE is released? no, only in use" "$(row tkE released)" ""
check "b: tkE in use at its own commit" "$(field "$(row tkE in-use)" 1)" "$D2"
# c) bypass
check "c: bypass built row" "$(row tkB built | cut -f5-8)" "$(printf 'built\tbypass\tbypass\t-')"
check "c: bypass landed row" "$(row tkB landed | cut -f6-8)" "$(printf 'bypass\tbypass\t-')"
check "c: unproven record is unverified" "$(row tkF landed | cut -f6-8)" "$(printf 'none-recorded\tbypass-unverified\t-')"
# d) revert
check "d: reverted row" "$(row tkC reverted)" "$(printf '%s\ttkC\tproj\t%s\treverted\t-\t-\trevert:%s' "$D2" "${C:0:12}" "${R:0:12}")"
check "d: landed row of the reverted commit is flagged" "$(row tkC landed | cut -f8)" "reverted"
check "d: the revert commit is no landing" "$(ledger | awk -F'\t' -v r="${R:0:12}" '$4 == r && $5 == "landed"' | wc -l | tr -d ' ')" "0"
# e) duplicate
check "e: duplicate flagged" "$(row tkDup landed | cut -f8)" "duplicate"
check "e: duplicate has no later stage" "$(row tkDup in-use)$(row tkDup released)$(row tkDup built)" ""
check "e: landed rows with no flag" "$(ledger | awk -F'\t' '$5 == "landed" && $8 == "-" { n++ } END { print n + 0 }')" "5"
# f) no proofs row
check "f: no proofs row" "$(row tkF landed | cut -f6)" "none-recorded"
check "f: no built row" "$(row tkF built)" ""
# g) rerun and missing sources
check "g: rerun prints the same rows" "$(ledger | sha256sum)" "$(ledger | sha256sum)"
mv "$H/data/trunk-releases.tsv" "$d/rel.keep"
out2=$(ledger 2>"$d/err2" | wc -l | tr -d ' ') || true
rc=0; JG_HOME=$H bash "$BIN" build >/dev/null 2>"$d/err2" || rc=$?
check "g: a missing record exits 2" "$rc" 2
check "g: a missing record is named" "$(cat "$d/err2")" "jg-outcome-ledger: missing source record: $H/data/trunk-releases.tsv"
check "g: the rest still prints" "$([ "$out2" -gt 0 ] && echo yes)" "yes"
check "g: nothing is released without the release record" "$(row tkA released)" ""
mv "$d/rel.keep" "$H/data/trunk-releases.tsv"
rm "$H/data/trunk-landings.tsv"
rc=0; JG_HOME=$H bash "$BIN" build >"$d/o3" 2>"$d/err3" || rc=$?
check "g: no landings record exits 2 and prints nothing" "$rc:$(wc -c < "$d/o3" | tr -d ' ')" "2:0"
check "g: no landings record is named" "$(cat "$d/err3")" "jg-outcome-ledger: missing source record: $H/data/trunk-landings.tsv"
[ "$fails" -eq 0 ] || { say "$fails check(s) failed"; exit 1; }
say "all checks passed"
