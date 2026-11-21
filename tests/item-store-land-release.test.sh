#!/usr/bin/env bash
# The trunk adapter of the item store (slice 5b): landings, release pushes and his release word are recorded in the store beside today's
# records, which still decide. Real lanes land through core/trunk-landing/trunk-landing.sh and real releases run through bin/jg-trunk.sh
# (tests/jg-trunk-fixture.sh: scratch git repositories, a local origin, a gh-axi stand-in), against core/item-store of this checkout.
# a: a landing closes its land item with the landed commit, once; a re-cut commit is read once the stamp check passed; a lane rebased after its done line closes the item it opened with. b: a standard project's
# word and release (his yes, the covered head, no intake). c: a push after his yes asks again, today's output is unchanged, and `agree` lists
# the difference. d: rollover closes the release and opens the update items of the homes. e: compare. f: the stamp check reads the word.
# g: release-daily after his no. h: a loose project releases with no question.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

ITEM=$ROOT/core/item-store
FIX=$(dirname "${BASH_SOURCE[0]}")/fixtures/item-store-land-release
unset JG_TASK_ID
export JG_ITEM_TICK_LEASE_S=0

ji()  { env JG_HOME="$HOME_D" "$ITEM/jg-item" "$@"; }
tr_() { env JG_HOME="$HOME_D" python3 -I "$ITEM/adapters/trunk.py" "$@"; }
own() { env JG_HOME="$HOME_D" python3 -I "$ITEM/adapters/owner.py" "$@"; }
sql() { python3 -I -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1] + "/state/item-store/fleet.db")
for r in c.execute(sys.argv[2]): print("|".join("" if x is None else str(x) for x in r))' "$HOME_D" "$1"; }
want() { [ "$3" = "$2" ] || fail "$1: wanted [$2], got [$3]"; pass "$1"; }

# store_world <name> <standard|loose> [<main home origin>]: a release world with the store switched on and the project's policy row.
store_world() {
  release_world "$1"
  : > "$HOME_D/config/item-store"
  JG_HOME="$HOME_D" ITEM="$ITEM" LEVEL="$2" python3 -I -c 'import os, sys; sys.path.insert(0, os.environ["ITEM"]); import itemdb
st = itemdb.open_db(os.environ["JG_HOME"], "owner:registry"); at = itemdb.stamp(st)
st.set_policy(at, "proj", os.environ["LEVEL"], st.me, "test:policy", mode="local-trunk")'
  # The main home is a clone of the project's origin (or of another), as Main's checkout is.
  git init -q "$HOME_D" && git -C "$HOME_D" remote add origin "${3:-$(git -C "$PROJ" remote get-url origin)}"
  git -C "$HOME_D" remote get-url origin >/dev/null || fail "fixture: the main home needs an origin"
}
# store_land <id> <content> [<file>]: a lane with an open land item, landed by the real landing check; the item must close.
store_lane() {  # <id> <content> [<file>]: a lane with an open land item; sets LANDHEAD
  lane "$1" "$2" "${3:-work.txt}"; LANDHEAD=$(git -C "$PROJ" rev-parse "fm/$1")
  ji open "land:main/$1@$LANDHEAD" --kind land --home main --subject "$1" --owes "land $1" --source "done:$1@$LANDHEAD" --project proj >/dev/null || fail "the land item of $1 must open"
}
store_landed() {  # <id> <head>: sweeps of the landing check until the lane's land item closes
  for _ in 1 2 3 4 5 6; do sweep >/dev/null; [ "$(sql "SELECT state FROM item WHERE key='land:main/$1@$2'")" = "done" ] && return 0
  done
  fail "the land item of $1 must close"
}
store_land() { store_lane "$@"; store_landed "$1" "$LANDHEAD"; }
rec() {  # <pull request number> the question and release step as "question release", each its state or -
  printf '%s %s' "$(sql "SELECT coalesce(max(state),'-') FROM item WHERE key='question:release:proj@$1'")" "$(sql "SELECT coalesce(max(state),'-') FROM item WHERE key='release:proj@$1'")"
}
intakes() { sql "SELECT count(*) FROM item WHERE kind='intake' AND key LIKE '$1%'"; }
# release_flow <name> <store 0|1>: a project with one landed lane, the word, the release; sets REL and prints nothing.
release_flow() {
  store_world "$1" standard; [ "$2" = 1 ] || rm -f "$HOME_D/config/item-store"
  if [ "$2" = 1 ]; then store_land a1 released; else lane a1 released; sweep >/dev/null; fi
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "a1 must verify"
  trunk word release "$PROJ" "ship a1" >/dev/null 2>&1 || fail "the word must record"
  trunk release "$PROJ" >"$W/release-1.out" 2>&1 || fail "the release must open: $(cat "$W/release-1.out")"
  REL=$(tip)
}

# ---------------------------------------------------------------- a: a landing closes its land item
store_world land standard
store_lane la one a.txt; HA=$LANDHEAD
store_lane lb two b.txt; HB=$LANDHEAD   # both lanes start on the same tip, so the second is rebased onto the first's commit
store_landed la "$HA"; store_landed lb "$HB"
ca=$(sql "SELECT outcome FROM item WHERE key='land:main/la@$HA'"); cb=$(sql "SELECT outcome FROM item WHERE key='land:main/lb@$HB'")
want "a1 each landing closes its land item with a trunk: proof" "trunk: trunk:" "$(printf '%s %s' "${ca%%[0-9a-f]*}" "${cb%%[0-9a-f]*}")"
want "a2 the item names the commit that stands on the trunk" "$(awk -F'\t' '$1 == "lb" { c = $3 } END { print c }' "$HOME_D/data/trunk-landings.tsv")" "${cb#trunk:}"
git -C "$PROJ" merge-base --is-ancestor "${cb#trunk:}" trunk || fail "a2b the landed commit is on the trunk"
[ "${cb#trunk:}" != "$HB" ] || fail "a3 the lane's commit was re-cut by the lander, so the item must name another hash"
pass "a3 the lander re-cut the commit (same patch, new hash) and the land item names the landed one"
want "a4 before the stamp check has passed the landing reads as nothing" "" "$(ji landed lb)"
ji stamp-check >/dev/null || :
want "a5 once the stamp check has passed, jg-item landed answers the landed commit" "${cb#trunk:}" "$(ji landed lb)"
n=$(sql "SELECT count(*) FROM move")
tr_ landed main lb "$HB" "${cb#trunk:}" --source "land:lb@${cb#trunk:}" >/dev/null
want "a6 the same landing again writes nothing" "$n" "$(sql "SELECT count(*) FROM move")"
# A lane rebased onto the newer trunk after its land item opened is landed at its new head: the item opened at the old head closes, with no refused write.
store_lane lc three c.txt; HC=$LANDHEAD
relane lc four; HC2=$(git -C "$PROJ" rev-parse fm/lc)
[ "$HC2" != "$HC" ] || fail "a7 the rebase must move the lane's head"
for _ in 1 2 3 4 5 6; do sweep >/dev/null; [ "$(sql "SELECT state FROM item WHERE key='land:main/lc@$HC'")" = "done" ] && break; done
want "a7 the land item opened at the old head closes when the rebased lane lands" "done" "$(sql "SELECT state FROM item WHERE key='land:main/lc@$HC'")"
want "a8 no land item is opened or refused for the new head" "0" "$(sql "SELECT count(*) FROM item WHERE key LIKE 'land:main/lc@$HC2' OR key LIKE 'intake:main/refused-%'")"

# ---------------------------------------------------------------- b, c, f: the release word on a standard project
release_flow word 1
want "b1 his word closes the release question and opens the release step" "done open" "$(rec 1)"
want "b2 the yes is stamped owner:trunk-word" "owner:trunk-word" "$(sql "SELECT closed_by FROM item WHERE key='question:release:proj@1'")"
want "b3 covered-head prints the pushed head" "$REL" "$(ji covered-head proj 1)"
want "b4 no intake item" "0" "$(sql "SELECT count(*) FROM item WHERE kind='intake'")"
want "b5 covered prints the same" "$REL" "$(tr_ covered proj 1)"
fail_out=$(ji stamp-check 2>&1 | grep -c 'trunk-word' || true)
want "f1 the stamp check names no finding for the word (its reader lists it)" "0" "$fail_out"
tr_ pushed proj 7 h7 --source push:h7 >/dev/null
own answer --channel trunk-word --message-id 99@h7 --key question:release:proj@7 --pick yes >/dev/null
ji stamp-check 2>&1 | grep -q 'trunk-word:99@h7' || fail "f2 a word move with no row in data/trunk-words.tsv must be found"
pass "f2 the stamp check finds a word move with no row in data/trunk-words.tsv"

# c: a second landing pushed after his yes; today's check passes by an answer at gated, with no word
store_land c1 two w1.txt
trunk verify "$PROJ" >/dev/null 2>&1 || fail "c1 must verify"
printf 'proj\t%s\t%s\ttkc\tword\n' "$(tip)" "$(date +%s)" > "$HOME_D/data/trunk-gated.tsv"
sleep 1   # the store orders his yes and a push by the second
echo closed > "$W/pr-state-1"   # the first pull request reads as closed for this one call, so today's check does not refuse the push on the standing answer; the forge's create gives the same URL
trunk release "$PROJ" >"$W/release-2.out" 2>&1 || fail "the second release push must pass today's check: $(cat "$W/release-2.out")"
rm -f "$W/pr-state-1"
want "c1 a push after his yes asks again" "open open" "$(rec 1)"
want "c2 today's check passed and the store's yes does not cover the head: one release-disagree intake" "1" "$(intakes intake:main/release-disagree-proj@1)"
want "c3 his yes still covers the first head" "$REL" "$(ji covered-head proj 1)"
norm() { sed "s|$TMP_ROOT/[A-Za-z0-9_-]*/|W/|g" "$1"; }   # the two worlds differ in their path only
SECOND=$(norm "$W/release-2.out")
# the same flow without the store gives today's output and exit for the same steps
release_flow plain 0
lane c1 two w1.txt; sweep >/dev/null; trunk verify "$PROJ" >/dev/null 2>&1
printf 'proj\t%s\t%s\ttkc\tword\n' "$(tip)" "$(date +%s)" > "$HOME_D/data/trunk-gated.tsv"
echo closed > "$W/pr-state-1"; trunk release "$PROJ" >"$W/release-2.out" 2>&1; rc=$?
want "c4 jg-trunk.sh release prints and exits as it does with no store" "0 $SECOND" "$rc $(norm "$W/release-2.out")"

# ---------------------------------------------------------------- d, e: rollover, update items, compare
for variant in same other; do
  if [ "$variant" = same ]; then store_world "roll-$variant" standard; else store_world "roll-$variant" standard "$W/elsewhere.git"; fi
  mkdir -p "$W/leadhome"; sed "s|@LEADHOME@|$W/leadhome|" "$FIX/data/squad_leads.md" > "$HOME_D/data/squad_leads.md"
  store_land r1 released; trunk verify "$PROJ" >/dev/null 2>&1 || fail "r1 must verify"
  trunk word release "$PROJ" "ship r1" >/dev/null 2>&1; trunk release "$PROJ" >/dev/null 2>&1 || fail "the release must open"
  R=$(tip); git -C "$PROJ" fetch -q origin main
  M=$(git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit-tree "$(git -C "$PROJ" rev-parse "$R^{tree}")" -p origin/main -p "$R" -m "Merge pull request #1")
  git -C "$PROJ" push -q origin "$M:refs/heads/main"; echo merged > "$W/pr-state-1"
  trunk rollover "$PROJ" >/dev/null 2>&1 || fail "the merged release must roll over"
  if [ "$variant" = same ]; then
    want "d1 rollover closes the release step and no release question stays open" "done done" "$(rec 1)"
    want "d2 it opens one update item for main and one for the lead, and none for the remote lead" "update:lead@$R update:main@$R" \
      "$(sql "SELECT key FROM item WHERE kind='update' ORDER BY key" | paste -sd' ')"
    n=$(sql "SELECT count(*) FROM move"); trunk rollover "$PROJ" >/dev/null 2>&1 || :; tr_ released proj 1 "$R" --project-dir "$PROJ" --source "merged:1@$R" >/dev/null
    want "d3 the same rollover twice opens nothing more" "$n" "$(sql "SELECT count(*) FROM move")"
    out=$(tr_ compare proj); rc=$?
    want "e1 compare prints nothing on the fixture, and exits 0" "0|" "$rc|$out"
    printf 'ghost\tproj\t%s\t%s\tgate\n' "$(printf 'f%.0s' $(seq 1 40))" "$(date +%s)" >> "$HOME_D/data/trunk-landings.tsv"
    out=$(tr_ compare proj); rc=$?
    want "e2 a landings row with no land item is listed once" "1 1" "$(printf '%s\n' "$out" | grep -c ghost) $rc"
  else
    want "d4 a project with another origin opens no update item" "done 0" "$(sql "SELECT state FROM item WHERE key='release:proj@1'") $(sql "SELECT count(*) FROM item WHERE kind='update'")"
  fi
done

# ---------------------------------------------------------------- g: release-daily after his no
store_world daily standard
store_land d1 released; trunk verify "$PROJ" >/dev/null 2>&1 || fail "d1 must verify"
printf 'proj\ttrunk\t%s\t1\t%s\thttps://github.com/o/r/pull/1\n' "$(tip)" "$(date +%s)" >> "$HOME_D/data/trunk-releases.tsv"   # pushed into release pull request 1, nobody said yes
tr_ pushed proj 1 "$(tip)" --source "push:$(tip)" >/dev/null
trunk release-daily >/dev/null 2>&1
want "g1 an open release pull request with his question open opens no intake" "0" "$(intakes intake:main/release-proj@1)"
own answer --channel trunk-word --message-id 1@no --key question:release:proj@1 --pick no >/dev/null
trunk release-daily >/dev/null 2>&1
want "g2 after his no the open release pull request is listed once" "1" "$(intakes intake:main/release-proj@1)"
trunk release-daily >/dev/null 2>&1
want "g3 a second run opens none" "1" "$(intakes intake:main/release-proj@1)"

# ---------------------------------------------------------------- h: a loose project
store_world loose loose
store_land l1 released; trunk verify "$PROJ" >/dev/null 2>&1 || fail "l1 must verify"
trunk word release "$PROJ" "ship l1" >/dev/null 2>&1; trunk release "$PROJ" >/dev/null 2>&1 || fail "the loose release must open"
want "h1 a loose project releases with no question" "- open" "$(rec 1)"
want "h2 and no intake item" "0" "$(sql "SELECT count(*) FROM item WHERE kind='intake'")"
printf 'item-store-land-release: ok\n'
