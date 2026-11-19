#!/usr/bin/env bash
# The delivery switch (slice 8d): where a home holds the marker config/item-store-decides, the item store's answer decides
# merge-on-green's merge and jg-trunk.sh release's push, and today's rule still has to pass too. Real callers run in temporary
# homes (merge-on-green.sh with a stand-in forge, merge command and lint; bin/jg-trunk.sh over scratch git repositories).
# a: a yolo-off pull request with merge=approved and no yes in the store is not merged and files one intake item; after his yes it merges
#    and the step closes merged:. b: a loose project merges with no question. c: the release word covers its head only: a later landing is
#    refused until his new yes covers it. d: a release pull request through merge-on-green: his word, the standing word, neither.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

ITEM=$ROOT/core/item-store
AD=$ITEM/adapters
FIX=$ROOT/tests/fixtures/item-store-owner-calls
unset JG_TASK_ID
export JG_ITEM_TICK_LEASE_S=0 JG_BEADS_TEST_BD="${JG_BEADS_TEST_BD:-}"
sql() { python3 -I -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1] + "/state/item-store/fleet.db")
for r in c.execute(sys.argv[2]): print("|".join("" if x is None else str(x) for x in r))' "$1" "$2"; }
want() { [ "$3" = "$2" ] || fail "$1: wanted [$2], got [$3]"; pass "$1"; }
own() { JG_HOME=$1 python3 -I "$AD/owner.py" "${@:2}"; }
ji() { JG_HOME=$1 "$ITEM/jg-item" "${@:2}"; }

# ------------------------------------------------------------------ a, b: pull requests through merge-on-green
S=$TMP_ROOT/stub; mkdir -p "$S"
cat > "$S/gh" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *mergeCommit*) echo c0ffee1 ;;
  *" state "*) echo MERGED ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$S/gh"
mkhome() {   # <dir> <decides 0|1>
  local h=$1
  mkdir -p "$h/state" "$h/config" "$h/data/x" "$h/bin"; : > "$h/config/item-store"; [ "$2" = 0 ] || : > "$h/config/item-store-decides"
  cp "$FIX/data/projects.md" "$h/data/projects.md"
  printf '#!/usr/bin/env bash\necho "state: done · source: status-log · ready"\n' > "$h/bin/jg-crew-state.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$h/bin/jg-pr-state.sh"
  # shellcheck disable=SC2016 # the stand-in expands its own arguments
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/merge-calls"\necho "merged $2"\n' "$S" > "$h/bin/jg-pr-merge.sh"
  printf '#!/usr/bin/env bash\necho "checks-lint: PASS: 2 evidence files"\n' > "$S/lint.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$h/bin/jg-trunk.sh"
  chmod +x "$h"/bin/*.sh "$S/lint.sh"
  JG_HOME=$h python3 -I "$AD/policy.py" --import --table "$FIX/rules-main.tsv" >/dev/null
}
task() {   # <home> <task> <ticket> <project> <yolo> <merge> <pr number>
  local h=$1 t=$2
  { printf 'ticket=%s\nproject=/p/%s\nyolo=%s\npr=https://github.com/ex/r/pull/%s\npr_head=h%s\nspawn_gen=g\n' "$3" "$4" "$5" "$7" "$t"
    [ -z "$6" ] || printf 'merge=%s\n' "$6"; } > "$h/state/$t.meta"
  printf '{"verdict":"PASS","head":"h%s","spawn_gen":"g"}\n' "$t" > "$h/state/$t.run-receipt.json"
}
mog() { PATH="$S:$PATH" HOME=$TMP_ROOT JG_MOG_CHECKS_LINT=$S/lint.sh JG_CHECK_TIMEOUT=60 "$ROOT/core/merge-on-green/merge-on-green.sh" check "$1" 2>&1; }
merges() { [ -s "$S/merge-calls" ] && wc -l < "$S/merge-calls" | tr -d ' ' || echo 0; }

A=$TMP_ROOT/a; mkhome "$A" 1; task "$A" ta TA e-pr off approved 7; : > "$S/merge-calls"
out=$(mog "$A")
want "a1 approved in the record only, no yes in the store: not merged" 0 "$(merges)"
case $out in *"NOT merging ta"*) pass "a2 the refusal is named" ;; *) fail "a2: $out" ;; esac
want "a3 one intake item names the leash's refusal, and no merge item" "1 1 0" "$(sql "$A" "SELECT count(*), sum((SELECT why FROM move WHERE key=item.key AND verb='open') LIKE '%leash%'), (SELECT count(*) FROM item WHERE kind='merge') FROM item WHERE kind='intake'" | tr '|' ' ')"
mog "$A" >/dev/null
want "a4 the next sweep files no second intake item" 1 "$(sql "$A" "SELECT count(*) FROM item WHERE kind='intake'")"
ji "$A" open question:merge:main/TA@7 --kind question --home main --subject TA --owes "merge pull request 7 at hta? ready" --options 'yes|no' --project e-pr --source a0 >/dev/null
own "$A" answer --channel chat --message-id a1 --key question:merge:main/TA@7 --pick yes >/dev/null
mog "$A" >/dev/null
want "a5 after his yes on the merge question: merged, the step closed merged:" "1 done|merged:c0ffee1" "$(merges) $(sql "$A" "SELECT state, outcome FROM item WHERE key='merge:main/TA@7'")"
B=$TMP_ROOT/b; mkhome "$B" 1; task "$B" tc TC f-pr-yolo on "" 9; : > "$S/merge-calls"; mog "$B" >/dev/null
want "b1 a loose project merges with no question" "1 done 0" "$(merges) $(sql "$B" "SELECT state FROM item WHERE key='merge:main/TC@9'") $(sql "$B" "SELECT count(*) FROM item WHERE kind='question'")"
N=$TMP_ROOT/n; mkhome "$N" 0; task "$N" tn TN e-pr off approved 8; : > "$S/merge-calls"; mog "$N" >/dev/null
want "a6 without the marker the store records only: merged as on the base" 1 "$(merges)"

# ------------------------------------------------------------------ c: the release push covers its head only
ST() { release_world "$1"; : > "$HOME_D/config/item-store"; : > "$HOME_D/config/item-store-decides"
  JG_HOME="$HOME_D" ITEM="$ITEM" LEVEL="$2" python3 -I -c 'import os, sys; sys.path.insert(0, os.environ["ITEM"]); import itemdb
st = itemdb.open_db(os.environ["JG_HOME"], "owner:registry"); at = itemdb.stamp(st)
st.set_policy(at, "proj", os.environ["LEVEL"], st.me, "test:policy", mode="local-trunk")'
  git init -q "$HOME_D" && git -C "$HOME_D" remote add origin "$(git -C "$PROJ" remote get-url origin)"; }
landed() { lane "$1" "$2" "${3:-work.txt}" >/dev/null; LH=$(git -C "$PROJ" rev-parse "fm/$1")
  ji "$HOME_D" open "land:main/$1@$LH" --kind land --home main --subject "$1" --owes "land $1" --source "done:$1@$LH" --project proj >/dev/null
  for _ in 1 2 3 4 5 6; do sweep >/dev/null; [ "$(sql "$HOME_D" "SELECT state FROM item WHERE key='land:main/$1@$LH'")" = "done" ] && break; done
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "$1 must verify"; }
ST push standard
landed a1 released; H1=$(tip)
trunk word release "$PROJ" "ship a1" >/dev/null 2>&1; trunk release "$PROJ" >"$W/r1.out" 2>&1 || fail "c1 the first push must go: $(cat "$W/r1.out")"
want "c1 his word on h1, a push of h1: released, covered by his yes" "$H1" "$(ji "$HOME_D" covered-head proj 1)"
landed c1 two w1.txt; H2=$(tip); sleep 1
out=$(trunk release "$PROJ" 2>&1) && fail "c2 a later landing with no new word must not go: $out"
trunk word release "$PROJ" "ship c1" >/dev/null 2>&1
out=$(trunk release "$PROJ" 2>&1) && fail "c3 a new word of today's check is not his yes in the store: $out"
case $out in *"release: waiting for the owner's yes on ${H2:0:12}"*) pass "c3 refused: waiting for the owner's yes on the new head" ;; *) fail "c3 message: $out" ;; esac
want "c4 the refusal files the release-disagree intake once, pushes nothing" "1 $H1" "$(sql "$HOME_D" "SELECT count(*) FROM item WHERE key='intake:main/release-disagree-proj@1'") $(git --git-dir="$W/origin.git" rev-parse refs/heads/trunk)"
own "$HOME_D" answer --channel trunk-word --message-id "$(date +%s)@$H2" --key question:release:proj@1 --pick yes >/dev/null || fail "c5 his yes must record"
want "c5 his new yes covers h2" "$H2" "$(ji "$HOME_D" covered-head proj 1)"
trunk release "$PROJ" >"$W/r2.out" 2>&1 || fail "c6 after his yes the push goes: $(cat "$W/r2.out")"
want "c6 h2 is pushed" "$H2" "$(git --git-dir="$W/origin.git" rev-parse refs/heads/trunk)"

# ------------------------------------------------------------------ d: a release pull request through merge-on-green
RID=release-proj-trunk
rmog() { PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="$W/root" JG_STATE_OVERRIDE="$HOME_D/state" JG_DATA_OVERRIDE="$HOME_D/data" \
  JG_CONFIG_OVERRIDE="$HOME_D/config" JG_MOG_CHECKS_LINT="$W/checks-lint" JG_MOG_ALERT="$ROOT/bin/jg-alert.sh" JG_CHECK_TIMEOUT=60 \
  "$ROOT/core/merge-on-green/merge-on-green.sh" check "$HOME_D" 2>&1; }
rm_receipt() { printf '{"schema":1,"task":"%s","mode":"local-trunk","spawn_gen":"","head":"%s","pr":"https://github.com/o/r/pull/1","verdict":"PASS","at":%s}\n' "$RID" "$(tip)" "$(date +%s)" > "$HOME_D/state/$RID.run-receipt.json"; }
mcalls() { [ -s "$W/merge-calls" ] && grep -c . "$W/merge-calls" || echo 0; }
ST word standard; landed d1 released
trunk word release "$PROJ" "ship d1" >/dev/null 2>&1
printf 'proj\t%s\t%s\ttkd\tword\n' "$(tip)" "$(date +%s)" > "$HOME_D/data/trunk-gated.tsv"   # the answer at gated is the merge authority of the record
trunk release "$PROJ" >/dev/null 2>&1 || fail "d1 the release must open"
rm_receipt; rmog >/dev/null
want "d1 his word, then the release: merged, the release step was open and rollover closed it, no intake and no merge: item" "1 done 0 0" "$(mcalls) $(sql "$HOME_D" "SELECT state FROM item WHERE key='release:proj@1'" | head -1) $(sql "$HOME_D" "SELECT count(*) FROM item WHERE kind='intake'") $(sql "$HOME_D" "SELECT count(*) FROM item WHERE kind='merge'")"
ST waiver standard; landed d2 released
trunk word release "$PROJ" "ship d2" >/dev/null 2>&1   # `release` needs a word beside the waiver file; the store's owner:rules path is slice 5c's own test d4
trunk waiver "$PROJ" --rule owner-rule-5f0e638d --release >/dev/null 2>&1; trunk release "$PROJ" >"$W/d2.out" 2>&1 || fail "d2 the release must open: $(cat "$W/d2.out")"
rm_receipt; rmog >/dev/null
want "d2 the standing word: merged, the store holds his yes" "1 owner:trunk-word" "$(mcalls) $(sql "$HOME_D" "SELECT closed_by FROM item WHERE key='question:release:proj@1'")"
ST none standard; landed d3 released
trunk release "$PROJ" >/dev/null 2>&1 && fail "d3 a release with no word must not push"
rm_receipt; rmog >/dev/null
want "d3 neither a word nor the standing word: not merged" 0 "$(mcalls)"
printf 'item-store-delivery-switch: ok\n'
