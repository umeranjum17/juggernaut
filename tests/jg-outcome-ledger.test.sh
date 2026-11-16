#!/usr/bin/env bash
# Journey: the outcome ledger is rebuilt from a fixture home's own records by the real command, bin/jg-outcome-ledger.sh.
# The fixture home holds a git project and the five trunk records. Cases:
# a) a landing with a proof, an in-use row and a release whose rollover shows it merged: built, landed, in-use, released;
# b) a landing whose release is only raised (no rollover yet): release-raised, never released;
# c) a bypassed landing: proof and bypass columns say bypass, and a record that does not hold reads bypass-unverified;
# d) a revert: the reverted commit has a reverted row and the flag reverted on every row; the revert commit is no landing;
# e) a duplicate landing row: one row flagged duplicate, with no later stage;
# f) a landing with no proofs row reads none-recorded and has no built row;
# h) owner involvement from recorded words and waivers only: bypass, captain-word (a gated word, or a captain word whose commit holds the landing),
#    standing-waiver (a gated yolo), none (a proofs row and no word), unknown (no record names the ticket);
# i) the publication timing rows: an automatic and a fallback publication with their times and path, a merged one with minutes, an old release
#    with no publication row reading path unknown, and a missing publications record named;
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

# owner records: tkA has a gated word, tkE a gated yolo, a captain word names C (it covers A, B and C), a spent word at G is no grant
printf 'proj\t%s\t%s\ttkA\tword\n' "$A" "$(t 0)" > "$H/data/trunk-gated.tsv"
printf 'proj\t%s\t%s\ttkE\tyolo\n' "$E" "$(t 1)" >> "$H/data/trunk-gated.tsv"
printf 'proj\tin-use\t%s\t%s\tgo\n' "$C" "$(t 1)" > "$H/data/trunk-words.tsv"
printf 'proj\tspent-in-use\t%s\t%s\tgo\n' "$G" "$(t 1)" >> "$H/data/trunk-words.tsv"
# publications: the release of A went out by the tick (due 6h before the attempt, opened with it); the batch at G by hand, not merged
printf 'proj\ttrunk\t%s\t%s\t%s\t%s\tautomatic\thttps://example.test/pull/1\n' "$A" "$(( $(t 1) - 21600 ))" "$(t 1)" "$(( $(t 1) + 5 ))" > "$H/data/trunk-publications.tsv"
printf 'proj\ttrunk-v2\t%s\t%s\t%s\t%s\tfallback\thttps://example.test/pull/2\n' "$G" "$(( $(t 3) - 7200 ))" "$(t 3)" "-" >> "$H/data/trunk-publications.tsv"

ledger() { JG_HOME=$H bash "$BIN" build; }
row() { ledger | awk -F'\t' -v t="$1" -v s="$2" -v f="${3:-}" '$2 == t && $5 == s && (f == "" || $8 == f) { print }'; }
field() { printf '%s' "$1" | cut -f"$2"; }

rc=0; ledger >/dev/null 2>"$d/err" || rc=$?
check "a clean fixture exits 0" "$rc" 0
check "a clean fixture names nothing on stderr" "$(cat "$d/err")" ""
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || ledger > "$DONE_DONE_EVIDENCE_ROOT/ledger.tsv"
check "columns line" "$(bash "$BIN" columns)" "$(printf 'date\tticket\tproject\tcommit\tstage\tproof\tbypass\tflag\towner')"

# a) a full life
check "a: built row" "$(row tkA built)" "$(printf '%s\ttkA\tproj\t%s\tbuilt\treceipt+merge-card\t-\t-\tcaptain-word' "$D1" "${A:0:12}")"
check "a: landed row" "$(row tkA landed -)" "$(printf '%s\ttkA\tproj\t%s\tlanded\treceipt+merge-card\t-\t-\tcaptain-word' "$D1" "${A:0:12}")"
check "a: in-use row" "$(field "$(row tkA in-use)" 1)" "$D1"
check "a: released row dated by the rollover" "$(row tkA released)" "$(printf '%s\ttkA\tproj\t%s\treleased\treceipt+merge-card\t-\t-\tcaptain-word' "$D3" "${A:0:12}")"
# b) raised only
check "b: raised release is not released" "$(row tkG released)" ""
check "b: raised release row" "$(field "$(row tkG release-raised)" 5)" "release-raised"
check "b: tkG is not in use (hook-failed)" "$(row tkG in-use)" ""
check "b: tkE is released? no, only in use" "$(row tkE released)" ""
check "b: tkE in use at its own commit" "$(field "$(row tkE in-use)" 1)" "$D2"
# c) bypass
check "c: bypass built row" "$(row tkB built | cut -f5-9)" "$(printf 'built\tbypass\tbypass\t-\tbypass')"
check "c: bypass landed row" "$(row tkB landed | cut -f6-9)" "$(printf 'bypass\tbypass\t-\tbypass')"
check "c: unproven record is unverified" "$(row tkF landed | cut -f6-9)" "$(printf 'none-recorded\tbypass-unverified\t-\tunknown')"
# d) revert
check "d: reverted row" "$(row tkC reverted)" "$(printf '%s\ttkC\tproj\t%s\treverted\t-\t-\trevert:%s\t-' "$D2" "${C:0:12}" "${R:0:12}")"
check "d: landed row of the reverted commit is flagged" "$(row tkC landed | cut -f8)" "reverted"
check "d: the revert commit is no landing" "$(ledger | awk -F'\t' -v r="${R:0:12}" '$4 == r && $5 == "landed"' | wc -l | tr -d ' ')" "0"
# e) duplicate
check "e: duplicate flagged" "$(row tkDup landed | cut -f8)" "duplicate"
check "e: duplicate has no later stage" "$(row tkDup in-use)$(row tkDup released)$(row tkDup built)" ""
check "e: landed rows with no flag" "$(ledger | awk -F'\t' '$5 == "landed" && $8 == "-" { n++ } END { print n + 0 }')" "5"
# f) no proofs row
check "f: no proofs row" "$(row tkF landed | cut -f6)" "none-recorded"
check "f: no built row" "$(row tkF built)" ""
# h) owner involvement
check "h: a gated word is a captain word" "$(row tkA landed - | cut -f9)" "captain-word"
check "h: a gated yolo is a standing waiver" "$(row tkE landed | cut -f9)" "standing-waiver"
check "h: a captain word covers the landing it names" "$(row tkC landed | cut -f9)" "captain-word"
check "h: a bypass is a bypass" "$(row tkB landed | cut -f9)" "bypass"
check "h: a proofs row with no word or waiver is none" "$(row tkG landed | cut -f9)" "none"
check "h: a landing no record names is unknown" "$(row tkF landed | cut -f9)" "unknown"
check "h: a duplicate and a revert carry no class" "$(row tkDup landed | cut -f9)$(row tkC reverted | cut -f9)" "--"
# i) publication timing
pubs() { JG_HOME=$H bash "$BIN" publications; }
check "i: the automatic publication row" "$(pubs | awk -F'\t' -v c="${A:0:12}" '$2 == c')" "$(printf 'proj\t%s\tautomatic\t2023-11-15T16:13:20Z\t2023-11-15T22:13:20Z\t2023-11-15T22:13:25Z\t2023-11-16T22:13:20Z\t1800' "${A:0:12}")"
check "i: the fallback publication row, not merged" "$(pubs | awk -F'\t' -v c="${G:0:12}" '$2 == c')" "$(printf 'proj\t%s\tfallback\t2023-11-17T20:13:20Z\t2023-11-17T22:13:20Z\t-\t-\t-' "${G:0:12}")"
printf 'proj\ttrunk\t%s\t9\t%s\thttps://example.test/pull/0\n' "$B" "$(t 1)" >> "$H/data/trunk-releases.tsv"
check "i: an old release with no publication row is path unknown" "$(pubs | awk -F'\t' -v c="${B:0:12}" '$2 == c' | cut -f3-4)" "$(printf 'unknown\t-')"
mv "$H/data/trunk-publications.tsv" "$d/pub.keep"
rc=0; pubs >/dev/null 2>"$d/errp" || rc=$?
check "i: a missing publications record is named" "$rc:$(cat "$d/errp")" "2:jg-outcome-ledger: missing source record: $H/data/trunk-publications.tsv"
mv "$d/pub.keep" "$H/data/trunk-publications.tsv"
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
