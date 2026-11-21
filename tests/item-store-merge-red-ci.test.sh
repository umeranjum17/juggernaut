#!/usr/bin/env bash
# Merge and red CI in the item store (slice 5c): merge-on-green.sh and red-ci-ticket.sh run for real in temporary homes (the forge, the
# merge command and the evidence lint are stand-ins), and core/item-store/adapters/merge.py records beside today's rule.
# a: a yolo-off pull request approved only in its record merges as on the base, and the leash's refusal is one intake item.
# b: the same after his yes on question:merge: the step opens and the merge closes it `merged:<commit>`; no intake.
# c: a loose project: the step opens with no question and the merge closes it.
# d: a standard local-trunk release pull request: his trunk-word yes, his standing release word (stamped owner:rules, stamp check
#    clean) and neither (one intake item); a release record writes no merge: item.
# e: compare prints nothing after b-d; a merged pull request with no merge item is listed once, exit 1.
# f: a red run on an open merge files a blocker, the merge's close closes it in the same write, a red run after it files nothing;
#    the same red run twice, and the same merge twice, write once. g: red-ci-ticket.sh files the blocker for a pull request's head.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$HERE/.." && pwd -P)
FIX=$HERE/fixtures/item-store-owner-calls
ITEM=$ROOT/core/item-store
AD=$ITEM/adapters
MOG=$ROOT/core/merge-on-green
d=$(mktemp -d) || exit 1
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d STUB_DIR=$d/stub JG_ITEM_TICK_LEASE_S=0
unset JG_TASK_ID JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_ROOT_OVERRIDE
mkdir -p "$HOME" "$STUB_DIR/pr-state"
fail=0
ok()  { echo "ok $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }
want() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "wanted [$2], got [$3]"; fi; }
sql() { python3 -I -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1] + "/state/item-store/fleet.db")
for r in c.execute(sys.argv[2]): print("|".join("" if x is None else str(x) for x in r))' "$1" "$2"; }

# The forge: the merge commit of any pull request, and its state (STUB_DIR/state-<n>, default MERGED).
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *mergeCommit*) echo c0ffee1 ;;
  *" state "*) n=${2##*/}; cat "$STUB_DIR/state-$n" 2>/dev/null || echo MERGED ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/gh"
export PATH=$STUB_DIR:$PATH

mkhome() {   # <dir>: a main home with the store on, the stand-in commands, and the fixture registry's policy imported
  local h=$1
  mkdir -p "$h/state" "$h/config" "$h/data/x" "$h/bin"; : > "$h/config/item-store"
  cp "$FIX/data/projects.md" "$h/data/projects.md"
  printf '#!/usr/bin/env bash\necho "state: done · source: status-log · ready"\n' > "$h/bin/jg-crew-state.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$h/bin/jg-pr-state.sh"
  cat > "$h/bin/jg-pr-merge.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/merge-calls"
echo "merged $2"
STUB
  printf '#!/usr/bin/env bash\necho "checks-lint: PASS: 2 evidence files"\n' > "$STUB_DIR/lint.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$h/bin/jg-trunk.sh"
  chmod +x "$h"/bin/*.sh "$STUB_DIR/lint.sh"
  JG_HOME=$h python3 -I "$AD/policy.py" --import --table "$FIX/rules-main.tsv" >/dev/null
}
task() {   # <home> <task> <ticket> <project> <yolo> <merge> <pr number> [kind] [merge_rule]
  local h=$1 t=$2 head=h$2
  { printf 'ticket=%s\nproject=/p/%s\nyolo=%s\npr=https://github.com/ex/r/pull/%s\npr_head=%s\nspawn_gen=g\n' "$3" "$4" "$5" "$7" "$head"
    [ -z "$6" ] || printf 'merge=%s\n' "$6"; [ -z "${8:-}" ] || printf 'kind=%s\n' "$8"; [ -z "${9:-}" ] || printf 'merge_rule=%s\n' "$9"; } > "$h/state/$t.meta"
  printf '{"verdict":"PASS","head":"%s","spawn_gen":"g"}\n' "$head" > "$h/state/$t.run-receipt.json"
}
mog() { JG_MOG_CHECKS_LINT=$STUB_DIR/lint.sh JG_CHECK_TIMEOUT=60 "$MOG/merge-on-green.sh" check "$1" 2>&1; }
merges() { [ -s "$STUB_DIR/merge-calls" ] && wc -l < "$STUB_DIR/merge-calls" | tr -d ' ' || echo 0; }
own() { JG_HOME=$1 python3 -I "$AD/owner.py" "${@:2}"; }
mrg() { JG_HOME=$1 python3 -I "$AD/merge.py" "${@:2}"; }
ji()  { JG_HOME=$1 "$ITEM/jg-item" "${@:2}"; }

# ------------------------------------------------------------------ a: approved in the record only, no yes of his in the store
A=$d/a; mkhome "$A"; task "$A" ta TA e-pr off approved 7
: > "$STUB_DIR/merge-calls"
out=$(mog "$A")
case $out in *"merged ta https://github.com/ex/r/pull/7"*) ok "a1 merge-on-green merges it exactly as on the base" ;; *) bad "a1 merged" "$out" ;; esac
want "a2 the merge command ran once" 1 "$(merges)"
want "a3 no merge item: the leash refused it" 0 "$(sql "$A" "SELECT count(*) FROM item WHERE kind='merge'")"
want "a4 one intake item names the leash's refusal" "1 1" "$(sql "$A" "SELECT count(*), sum((SELECT why FROM move WHERE key=item.key AND verb='open') LIKE '%leash%') FROM item WHERE kind='intake' AND state='open'" | tr '|' ' ')"
want "a5 the merged call lists no second intake" 1 "$(sql "$A" "SELECT count(*) FROM item WHERE kind='intake'")"

# ------------------------------------------------------------------ b: the same, after his yes; c: a loose project
B=$d/b; mkhome "$B"; task "$B" tb TB e-pr off approved 8; task "$B" tc TC f-pr-yolo on "" 9
ji "$B" open question:merge:main/TB@8 --kind question --home main --subject TB --owes "merge pull request 8 (https://github.com/ex/r/pull/8) at hta? ready" \
  --options 'yes|no' --project e-pr --source b0 >/dev/null
own "$B" answer --channel chat --message-id b1 --key question:merge:main/TB@8 --pick yes >/dev/null
: > "$STUB_DIR/merge-calls"
out=$(mog "$B")
want "b1 both merged as on the base" "2" "$(merges)"
want "b2 his yes opened the step and the merge closed it merged:<commit>" "done|merged:c0ffee1" "$(sql "$B" "SELECT state, outcome FROM item WHERE key='merge:main/TB@8'")"
want "c1 a loose project: the step opened with no question and the merge closed it" "done|merged:c0ffee1|0" \
  "$(sql "$B" "SELECT state, outcome, (SELECT count(*) FROM item WHERE kind='question' AND subject='TC') FROM item WHERE key='merge:main/TC@9'")"
want "b3 no intake item" 0 "$(sql "$B" "SELECT count(*) FROM item WHERE kind='intake'")"
want "b4 the step's opener is the merge adapter and its closer too" "adapter:merge|adapter:merge" "$(sql "$B" "SELECT opened_by, closed_by FROM item WHERE key='merge:main/TC@9'")"

# ------------------------------------------------------------------ d: a standard local-trunk release pull request
push() { JG_HOME=$1 ITEM="$ITEM" python3 -I -c 'import os, sys; sys.path.insert(0, os.environ["ITEM"]); import itemdb
st = itemdb.open_db(os.environ["JG_HOME"], "adapter:trunk"); at = itemdb.stamp(st)
print(st.release_push(at, sys.argv[1], sys.argv[2], sys.argv[3], source="push:" + sys.argv[3]))' "${@:2}"; }
R=$d/r; mkhome "$R"
task "$R" release-b-lt-trunk release-b-lt b-lt off approved 41 release gated:word
sed -i '/^ticket=/d' "$R/state/release-b-lt-trunk.meta"
printf 'b-lt\tword\n' > "$R/data/trunk-gated.tsv"
push "$R" b-lt 41 rh1 >/dev/null
own "$R" answer --channel trunk-word --message-id 100@rh1 --key question:release:b-lt@41 --pick yes >/dev/null
: > "$STUB_DIR/merge-calls"
out=$(mog "$R")
want "d1 the release merged as on the base" 1 "$(merges)"
want "d2 step printed open, no merge: item and no intake item" "open 0 0" "$(mrg "$R" step main release-b-lt-trunk https://github.com/ex/r/pull/41 hrelease-b-lt-trunk --source mergeable:41@x) $(sql "$R" "SELECT count(*) FROM item WHERE kind='merge'") $(sql "$R" "SELECT count(*) FROM item WHERE kind='intake'")"
want "d3 merged on a release record writes nothing" "release 0" "$(mrg "$R" merged main release-b-lt-trunk https://github.com/ex/r/pull/41 c1 --source merged:41@x) $(sql "$R" "SELECT count(*) FROM item WHERE kind='merge' OR kind='intake'")"
# his standing release word: no yes in the store, merge=approved and merge_rule=r1 in the record
task "$R" release-b-lt2-trunk release-b-lt2 b-lt off approved 42 release r1
sed -i '/^ticket=/d' "$R/state/release-b-lt2-trunk.meta"
push "$R" b-lt 42 rh2 >/dev/null
want "d4 the standing word is recorded as his yes, stamped owner:rules, and the step prints open" "open done|owner:rules|1" \
  "$(mrg "$R" step main release-b-lt2-trunk https://github.com/ex/r/pull/42 hrelease-b-lt2-trunk --source mergeable:42@h | tr -d '\n') $(sql "$R" "SELECT state, closed_by FROM item WHERE key='question:release:b-lt@42'" | tr -d '\n')|$(sql "$R" "SELECT count(*) FROM item WHERE key='release:b-lt@42' AND state='open'")"
want "d5 the stamp check finds nothing on his standing word or the adapter's writes" "" "$(ji "$R" stamp-check | grep -e '@42' -e 'owner:rules' -e 'merge:')"
# neither a yes nor a word: one intake item
task "$R" release-b-lt3-trunk release-b-lt3 b-lt off "" 43 release
sed -i '/^ticket=/d' "$R/state/release-b-lt3-trunk.meta"
want "d6 neither: step prints intake and one intake item names the release pull request" "intake 1" \
  "$(mrg "$R" step main release-b-lt3-trunk https://github.com/ex/r/pull/43 h --source mergeable:43@h) $(sql "$R" "SELECT count(*) FROM move WHERE key='intake:main/release-merge-b-lt@43' AND why LIKE '%no yes of his%'")"
want "d7 the same step again writes once" "again 1" \
  "$(mrg "$R" step main release-b-lt3-trunk https://github.com/ex/r/pull/43 h --source mergeable:43@h) $(sql "$R" "SELECT count(*) FROM item WHERE kind='intake' AND subject='b-lt@43'")"

# ------------------------------------------------------------------ e: compare
C=$d/c; mkhome "$C"; task "$C" tb TB e-pr off approved 8; task "$C" tc TC f-pr-yolo on "" 9
cp -r "$B/state/item-store" "$C/state/"; cp -r "$B/data/jg-merge-on-green" "$C/data/"
out=$(mrg "$C" compare "$C"); rc=$?
want "e1 compare prints nothing after b and c" "0|" "$rc|$out"
out=$(mrg "$A" compare "$A"); rc=$?
case $out in *"merge:main/TA@7 merge today=merged store=none"*) want "e2 a merged pull request with no merge item is listed once, exit 1" "1 1" "$rc $(printf '%s\n' "$out" | wc -l | tr -d ' ')" ;; *) bad "e2 compare" "[$out] rc=$rc" ;; esac

# ------------------------------------------------------------------ f: a red run, the merge's close, the same call twice
F=$d/f; mkhome "$F"; task "$F" tf TF f-pr-yolo on "" 12
want "f1 a red run with no open step prints clear and writes nothing" "clear 0" "$(mrg "$F" red main TF run1 --source ci:run1) $(sql "$F" "SELECT count(*) FROM item WHERE kind='blocker'")"
want "f2 the step opens" open "$(mrg "$F" step main tf https://github.com/ex/r/pull/12 htf --source mergeable:12@htf)"
want "f3 a red run on the open merge files a blocker whose parent is the merge, held by Main" "open|merge:main/TF@12|main|adapter:ci" \
  "$(mrg "$F" red main TF run1 --source ci:run1 | tr -d '\n')|$(sql "$F" "SELECT parent, holder, opened_by FROM item WHERE key='blocker:main/TF#ci-run1'")"
want "f4 the same red run twice files one blocker" "again 1" "$(mrg "$F" red main TF run1 --source ci:run1) $(sql "$F" "SELECT count(*) FROM item WHERE kind='blocker'")"
want "f5 the merge's close closes the blocker in the same write" "done|1" \
  "$(mrg "$F" merged main tf https://github.com/ex/r/pull/12 c9 --source merged:12@htf | tr -d '\n')|$(sql "$F" "SELECT count(*) FROM item WHERE key='blocker:main/TF#ci-run1' AND state='done' AND closed_at=(SELECT closed_at FROM item WHERE key='merge:main/TF@12')")"
want "f6 the same merge twice writes once" "again $(sql "$F" "SELECT count(*) FROM move")" "$(mrg "$F" merged main tf https://github.com/ex/r/pull/12 c9 --source merged:12@htf) $(sql "$F" "SELECT count(*) FROM move")"
want "f7 a red run after the merge prints clear and files nothing" "clear 1" "$(mrg "$F" red main TF run2 --source ci:run2) $(sql "$F" "SELECT count(*) FROM item WHERE kind='blocker'")"
want "f8 the stamp check is clean" "" "$(ji "$F" stamp-check)"
want "f9 every write's pair is in the adapter's log" "ok" "$(JG_HOME=$F "$ITEM/logs/adapter-merge" | grep -q "^merged:12@htf	merge:main/TF@12$" && echo ok)"
want "f10 compare prints nothing" "0|" "$(mrg "$F" compare "$F" >/dev/null; echo "$?")|"

# ------------------------------------------------------------------ g: red-ci-ticket.sh files the blocker for a pull request's head
G=$d/g; mkhome "$G"; mkdir -p "$G/projects/r"
printf -- '- r [direct-PR +yolo] - fixture project (ex/r) (added 2026-11-04)\n' > "$G/data/projects.md"
git -C "$G/projects/r" init -q; git -C "$G/projects/r" remote add origin https://github.com/ex/r.git
printf '#!/usr/bin/env bash\nexit 0\n' > "$G/bin/jg-backlog.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$G/bin/jg-alert.sh"; chmod +x "$G"/bin/*.sh
cp "$MOG/tests/fixtures/red-ci-ticket/gh-axi" "$d/gh-axi"; export STUB_FAIL=$d/nofail
JG_HOME=$G python3 -I "$AD/policy.py" --import --table "$FIX/rules-main.tsv" >/dev/null 2>&1   # a second import is refused: the registry is already in
printf 'ticket=TG\nproject=/p/f-pr-yolo\nyolo=on\npr=https://github.com/ex/r/pull/14\npr_head=sha104\n' > "$G/state/tg.meta"
mrg "$G" step main tg https://github.com/ex/r/pull/14 sha104 --source mergeable:14@sha104 >/dev/null
JG_HOME=$G JG_RED_CI_GH=$d/gh-axi JG_CHECK_TIMEOUT=30 "$MOG/red-ci-ticket.sh" check "$G" >/dev/null 2>&1
want "g1 the run on the pull request's head holds its open merge" "blocker:main/TG#ci-14|merge:main/TG@14" "$(sql "$G" "SELECT key, parent FROM item WHERE kind='blocker'")"
want "g2 the run on the default branch, with no pull request, files none" 1 "$(sql "$G" "SELECT count(*) FROM item WHERE kind='blocker'")"

exit $fail
