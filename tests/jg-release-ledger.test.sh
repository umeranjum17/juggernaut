#!/usr/bin/env bash
# The release ledger: a fixture home with real git history and the lander's and the release's own records becomes one dated
# row per landing - Built, Landed, In use, Released and reverted - with an empty column for a stage never reached; a second
# build changes nothing and --dry-run writes nothing.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(jg_test_tmproot jg-release-ledger)
H="$TMP_ROOT/home"; D="$H/data"; P="$H/projects/demo"; OUT="$D/release-ledger.tsv"
LEDGER="$ROOT/core/release-ledger/ledger.sh"
export JG_HOME="$H"
mkdir -p "$D"
jg_git_init_commit "$P"
c() { printf '%s\n' "$1" >"$P/$1"; git -C "$P" add "$1"; git -C "$P" -c user.name=t -c user.email=t@example.invalid commit -qm "$1"; git -C "$P" rev-parse HEAD; }
c a >/dev/null; land1=$(c b)   # lane-1: reaches every stage
c d >/dev/null; land2=$(c e)   # lane-2: landed only
c f >/dev/null; land3=$(c g)   # lane-3: landed, in use, then reverted
live1=$(c h); base1=$(c i)
c j >/dev/null; land4=$(c k)   # lane-4: landed after the cut, never in use
rev3=$(c l)
land() { printf '%s\tdemo\t%s\t%s\tfull\n' "$1" "$2" "$3" >>"$D/trunk-landings.tsv"; }
land lane-1 "$land1" 1100; land lane-2 "$land2" 1200; land lane-3 "$land3" 1300; land lane-4 "$land4" 2000
# done times: lane-1 and lane-4 on the landing proofs, lane-2 only on the older latency rows, lane-3 on neither
printf 'lane-1\tdemo\t%s\t1100\treceipt=PASS@x\tdone=1010\nlane-4\tdemo\t%s\t2000\treceipt=PASS@x\tdone=1950\n' "$land1" "$land4" >"$D/trunk-landing-proofs.tsv"
printf 'task\thead\tcommit\tfirst_done\tready\nlane-2\th\t%s\t1140\t1150\n' "$land2" >"$D/trunk-latency.tsv"
printf 'revert-lane-3\tdemo\t%s\t1700\treverts-%s\n' "$rev3" "${land3:0:12}" >>"$D/trunk-landings.tsv"
printf 'demo\t%s\t1500\tlive\ndemo\t%s\t1450\thook-failed:x\n' "$live1" "$live1" >"$D/trunk-in-use.tsv"
printf 'demo\t1\ttrunk-v1\t%s\t1800\n' "$base1" >"$D/trunk-versions.tsv"

"$LEDGER" build 2>/dev/null || fail "the build failed"
row() { awk -F'\t' -v t="$1" '$1 == t' "$OUT"; }
want() { [ "$(row "$1")" = "$(printf '%s\t' "$1" demo "$2" | sed 's/\t$//')$3" ] || fail "row of $1 is wrong: $(row "$1" | tr '\t' '|')"; }
[ "$(head -1 "$OUT")" = "$(printf 'ticket\tproject\tcommit\tbuilt\tlanded\tin_use\treleased\trelease\treverted\treverted_by')" ] || fail "header is wrong"
# columns after the commit: built landed in_use released release reverted reverted_by
want lane-1 "$land1" "$(printf '\t1010\t1100\t1500\t1800\ttrunk-v1\t\t')"
want lane-2 "$land2" "$(printf '\t1150\t1200\t1500\t1800\ttrunk-v1\t\t')"
want lane-3 "$land3" "$(printf '\t\t1300\t1500\t1800\ttrunk-v1\t1700\t%s' "$rev3")"
want lane-4 "$land4" "$(printf '\t1950\t2000\t\t\t\t\t')"
pass "each landing carries the time of each stage it reached, an empty column for the rest, and its revert"

[ "$(awk 'END { print NR }' "$OUT")" -eq 5 ] || fail "the revert row became a ledger row"
pass "a revert row is a revert, never a landing"

before=$(cksum <"$OUT"); "$LEDGER" build 2>/dev/null || fail "the second build failed"
[ "$(cksum <"$OUT")" = "$before" ] || fail "a second build changed the ledger"
pass "a second build on unchanged records changes nothing"

rm -f "$OUT"; "$LEDGER" build --dry-run >/dev/null 2>&1; [ ! -e "$OUT" ] || fail "--dry-run wrote"
pass "--dry-run writes nothing"

# a new in-use row on a later commit moves nothing already recorded: the first holder keeps the time
live2=$(c m); printf 'demo\t%s\t1600\tlive\n' "$live2" >>"$D/trunk-in-use.tsv"
"$LEDGER" build 2>/dev/null || fail "the third build failed"
[ "$(row lane-1 | cut -f6)" = 1500 ] || fail "a later live row moved the in-use time"
pass "a later in-use row keeps the first time that held the landing"
