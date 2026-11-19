#!/usr/bin/env bash
# Drives jg-item as a process, the way it is deployed (one process per call, one file per host), in temporary homes:
# identity and place, required sources, one journey, the tick as a watcher check (silent, its clock file, one re-check
# per 15 minutes and its seconds, the expected stamp finding while no log reader exists), a lead's item climbing to Main
# in the one file, ready, a blocker, the checks, run-twice, a failing tick, a dropped trigger found, a release push
# with no source refused, an adapter opening the same file through itemdb, the source and key rules on the adapter
# path, the key contract, two projects in Main's home, and a refused adapter or script write becoming one intake item. Every home runs the tick
# behind the host's lease (d: Main's watcher stopped, a lead home's tick climbs; two homes in the same second tick once).
# The release word through itemdb as the trunk adapter and his channel run it, on a standard and a loose project (r);
# an alert with no holder, a call with no source and any other error each become one intake item (s).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ITEM=$HERE/../jg-item
STORE_DIR=$HERE/..
d=$(mktemp -d) || exit 1
trap 'rm -rf -- "$d"' EXIT
H=$d/main                                   # the main home: no parent binding
L=$d/lead                                   # a Squad Lead home of the same host
mkdir -p "$H/state" "$L/state"
printf 'muxr\n' > "$L/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$L/.jg-squad-lead-parent"
DB=$H/state/item-store/fleet.db
export JG_ITEM_TICK_LEASE_S=0               # every tick runs, until the lease cases below set the real 240 s
fail=0
ok()  { echo "ok $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }
jg() { env -u JG_TASK_ID JG_HOME="$H" "$ITEM" "$@"; }
jl() { env -u JG_TASK_ID JG_HOME="$L" "$ITEM" "$@"; }
want() {   # <label> <expected output> <command...>
  local label=$1 exp=$2 got; shift 2
  got=$("$@" 2>&1); [ "$got" = "$exp" ] && ok "$label" || bad "$label" "got [$got], want [$exp]"
}
clock4() { set -- $(cat "$H/state/item-store/tick-clock"); printf '%s' "${4:-}"; }

# (a) by is never an argument; it is derived from where jg-item runs; the file is the main home's from every home
out=$(jg open k --kind dispatch --home muxr --subject s --owes x --source s:1 --by main 2>&1); rc=$?
[ "$out" = "refused: unknown option --by" ] && [ "$rc" -eq 2 ] && ok a-by-refused || bad a-by-refused "[$out] exit $rc"
want a-whoami-main main jg whoami
want a-whoami-worker-main worker:main/jg-9 env JG_TASK_ID=jg-9 JG_HOME="$H" "$ITEM" whoami
want a-whoami-lead muxr jl whoami
want a-whoami-is-home-id "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import itemdb; print(itemdb.home_id(sys.argv[2]))' "$(dirname "$ITEM")" "$L")" jl whoami
want a-whoami-worker-lead worker:muxr/jg-9 env JG_TASK_ID=jg-9 JG_HOME="$L" "$ITEM" whoami
want a-where-main "$DB" jg where
want a-where-lead "$DB" jl where
jg open k --kind dispatch --home muxr --subject s --owes x >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok a-source-required || bad a-source-required "exit $rc"

# (b) the fixture project's policy row, written in-process as the cut-over would, then the journey one process per move
want b-open open jg open dispatch:muxr/jg-1 --kind dispatch --home muxr --subject jg-1 --owes "start jg-1" --source approve:jg-1
python3 -I - "$STORE_DIR" "$DB" <<'PY' || { bad b-policy "policy write failed"; exit 1; }
import sys, time
sys.path.insert(0, sys.argv[1])
from store import Store
s, t = Store(sys.argv[2], attach=True).as_("owner:registry"), int(time.time()) - 10    # the one cut-over run: one stamp
for pj, lvl in (("muxr", "loose"), ("alpha", "standard"), ("beta", "standard")):
    s.set_policy(t, pj, lvl, "owner:registry", "import:projects.md:" + pj)
PY
want b-close-dispatch done jg close dispatch:muxr/jg-1 done lane:muxr/jg-1 --source spawn:jg-1 \
  --then '[{"key":"work:muxr/jg-1","kind":"work","home":"muxr","subject":"jg-1","lane":"worker:muxr/jg-1","owes":"build jg-1","project":"muxr"}]'
want b-close-work done jg close work:muxr/jg-1 done receipt:abc123 --source st:1 \
  --then '[{"key":"land:muxr/jg-1@abc123","kind":"land","home":"muxr","subject":"jg-1","owes":"land abc123","project":"muxr"},{"key":"cleanup:muxr/jg-1","kind":"cleanup","home":"muxr","subject":"jg-1","owes":"return the copy"}]'
out=$(jg close work:muxr/jg-x done receipt:x --source st:x --then '[{"key":"k","kind":"land","home":"muxr","subject":"s","owes":"o","color":"red"}]' 2>&1); rc=$?
[ "$rc" -eq 2 ] && case $out in *"unknown field color"*) true ;; *) false ;; esac && ok b-then-unknown-field || bad b-then-unknown-field "[$out] exit $rc"
want b-base refs/heads/main jg base muxr

# (c) the tick is a watcher check: silent, its clock line, one re-check per 15 minutes, the re-check's seconds logged
out=$(jg tick 2>&1); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok c-tick-silent || bad c-tick-silent "[$out] exit $rc"
f=$(cat "$H/state/item-store/tick-clock" 2>/dev/null); set -- $f
[ "$#" -eq 4 ] && [ "$4" != - ] && ok c-tick-clock-4-fields || bad c-tick-clock-4-fields "[$f]"
first=$(clock4)
# no log reader exists in slice 1, so the owner-stamped policy row is reported once (store.py stamp_check): expected
grep -q ' stamp policy muxr v1 ' "$H/state/item-store/tick.log" && ok c-stamp-policy-logged || bad c-stamp-policy-logged "no stamp line"
grep -Eq '^[0-9]+ recheck [0-9]+[.][0-9]s$' "$H/state/item-store/tick.log" && ok c-recheck-seconds-logged || bad c-recheck-seconds-logged "no recheck line"
jg board | grep -q 'security:fleet/forged-policy-muxr-v1' && ok c-stamp-security-item || bad c-stamp-security-item "not on the board"
n=0; for i in $(seq 1 15); do out=$(jg tick 2>&1); [ -z "$out" ] || n=$((n + 1)); done
# 16 ticks in one window: the re-check ran at the first only (the 4th field is its time), unless the run crossed a
# 15-minute boundary, when it ran once more
now=$(date +%s)
if [ "$n" -eq 0 ] && { [ "$(clock4)" = "$first" ] || [ $((first / 900)) -ne $((now / 900)) ]; }; then ok c-15-ticks-one-recheck; else bad c-15-ticks-one-recheck "outputs $n, field [$(clock4)] first [$first]"; fi
[ "$(grep -c ' stamp policy muxr v1 ' "$H/state/item-store/tick.log")" -eq 1 ] && ok c-stamp-once || bad c-stamp-once "logged more than once"

# (d) Main's watcher stopped: a lead home's tick climbs a lead's item to Main and Main-down to the owner, in the one
# file; and the lease: in a fresh host, two homes tick in the same second, so the late wait climbs once (one wait for all)
want d-lead-open open jl open wait:muxr/jg-5#review --kind wait --home muxr --subject jg-5 --owes "review jg-5" --named lead --due 1 --source st:jg-5
python3 -I - "$STORE_DIR" "$L" <<'PY' || bad d-main-down-open "see above"
import sys
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "adapter:supervision")
at = itemdb.stamp(st)
st.open(at, "main-down:main/supervision", "main-down", "main", "supervision", "Main's watcher beat is 15 minutes old",
        st.me, source="beat:1", due=1)
PY
H2=$d/main2; L2=$d/lead2; mkdir -p "$H2/state" "$L2/state"
printf 'muxr\n' > "$L2/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$H2" > "$L2/.jg-squad-lead-parent"
env -u JG_TASK_ID JG_HOME="$L2" "$ITEM" open wait:muxr/jg-7#k --kind wait --home muxr --subject jg-7 --owes w --named lead --due 1 --source st:7 >/dev/null
sleep 2
out=$(jl tick 2>&1); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok d-lead-tick-silent || bad d-lead-tick-silent "[$out] exit $rc"
jg board | awk -F'\t' '$4 == "wait:muxr/jg-5#review" {print $2}' | grep -qx main && ok d-climbed-to-main || bad d-climbed-to-main "$(jg board | grep jg-5)"
jg pages main | grep -q 'wait:muxr/jg-5#review' && ok d-main-pages-list-it || bad d-main-pages-list-it "not in Main's pages"
holder=$(jg board | awk -F'\t' '$4 == "main-down:main/supervision" {print $2}')
[ "$holder" = owner ] && ok d-lead-tick-climbs-main-down-to-owner || bad d-lead-tick-climbs-main-down-to-owner "holder [$holder]"
JG_ITEM_TICK_LEASE_S=240 env -u JG_TASK_ID JG_HOME="$L2" "$ITEM" tick
JG_ITEM_TICK_LEASE_S=240 env -u JG_TASK_ID JG_HOME="$H2" "$ITEM" tick
n=$(grep -c ' climb wait:muxr/jg-7#k ' "$H2/state/item-store/tick.log" 2>/dev/null)
r=$(grep -c ' recheck ' "$H2/state/item-store/tick.log" 2>/dev/null)
[ "$n" = 1 ] && [ "$r" = 1 ] && ok d-two-homes-one-tick || bad d-two-homes-one-tick "climbs [$n] re-checks [$r]"

# (e) pages and ack
pg=$(jg pages main); n=$(printf '%s\n' "$pg" | tail -n 1 | sed -n 's/.*ack=\([0-9][0-9]*\)$/\1/p')
[ -n "$n" ] && ok e-pages-count || bad e-pages-count "last line [$(printf '%s\n' "$pg" | tail -n 1)]"
want e-ack ok jg ack main "$n"
case $(jg pages main) in "pages: 0 listed,"*) ok e-pages-empty ;; *) bad e-pages-empty "[$(jg pages main)]" ;; esac

# (f) ready: a critic lane found by its parent link, then the same call again
jg open work:muxr/jg-r --kind work --home muxr --subject jg-r --owes investigate --lane worker:muxr/jg-r --project muxr --source sp:r >/dev/null
jg open work:muxr/jg-c --kind work --home muxr --subject jg-c --owes critique --lane worker:muxr/jg-c --parent work:muxr/jg-r --project muxr --source sp:c >/dev/null
want f-round round jg ready work:muxr/jg-r d1 --source ready:d1
want f-again again jg ready work:muxr/jg-r d1 --source ready:d1

# (g) a blocker leaves the board when its step closes
jg open dispatch:muxr/jg-2 --kind dispatch --home muxr --subject jg-2 --owes "start jg-2" --source ap:2 >/dev/null
jg open red-ci:muxr/jg-2 --kind blocker --home muxr --subject jg-2 --owes "CI red" --parent dispatch:muxr/jg-2 --named lead --source ci:2 >/dev/null
jg board | grep -q red-ci:muxr/jg-2 && ok g-blocker-listed || bad g-blocker-listed "not on the board"
jg close dispatch:muxr/jg-2 done lane:muxr/jg-2 --source sp:2 >/dev/null
jg board | grep -q red-ci:muxr/jg-2 && bad g-blocker-gone "still on the board" || ok g-blocker-gone

# (h) one source, one effect
jg open dispatch:muxr/jg-3 --kind dispatch --home muxr --subject jg-3 --owes "start jg-3" --source ap:3 >/dev/null
want h-first done jg close dispatch:muxr/jg-3 done lane:muxr/jg-3 --source once:1
want h-again again jg close dispatch:muxr/jg-3 done lane:muxr/jg-3 --source once:1

# (i) a failing tick says so once, not every cycle
mkdir "$H/state/item-store/tick-clock.tmp"          # the clock line cannot be written: the tick fails
out1=$(jg tick 2>&1); out2=$(jg tick 2>&1)
rmdir "$H/state/item-store/tick-clock.tmp"
case $out1 in "item-store: "*) [ -z "$out2" ] && ok i-error-once || bad i-error-once "second [$out2]" ;; *) bad i-error-once "first [$out1]" ;; esac
out=$(jg tick 2>&1); [ -z "$out" ] && [ ! -e "$H/state/item-store/tick-error" ] && ok i-error-cleared || bad i-error-cleared "[$out]"

# (j) the checks: clean, then a dropped trigger is found by the schema check
jg recheck >/dev/null && ok j-recheck || bad j-recheck "non-zero"
jg schema-check >/dev/null && ok j-schema-check || bad j-schema-check "non-zero"
python3 -I - "$DB" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
name = con.execute("SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name LIMIT 1").fetchone()[0]
con.execute("DROP TRIGGER " + name); con.commit()
PY
out=$(jg schema-check 2>&1); rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "the store's rules differ from the shipped schema" ] && ok j-dropped-trigger-found || bad j-dropped-trigger-found "[$out] exit $rc"

# (k) the store refuses a release push with no source: a push is keyed by its head, so without one it could repeat
python3 -I - "$STORE_DIR" <<'PY' && ok k-release-push-needs-source || bad k-release-push-needs-source "not refused"
import sys
sys.path.insert(0, sys.argv[1])
from store import Store, Refused
try:
    Store(":memory:").release_push(100, "muxr", "pr1", "h1")
except Refused:
    sys.exit(0)
sys.exit(1)
PY

# (l) an adapter opens the one file through itemdb from a lead home, writes with its fixed stamp, and no other
python3 -I - "$STORE_DIR" "$L" "$DB" <<'PY' && ok l-adapter-opens-one-file || bad l-adapter-opens-one-file "see the lines above"
import sys
sys.path.insert(0, sys.argv[1])
import itemdb, store
assert itemdb.db_path(sys.argv[2]) == sys.argv[3], itemdb.db_path(sys.argv[2])
st = itemdb.open_db(sys.argv[2], "owner:chat")
at = itemdb.stamp(st)
r = st.open(at, "tell:muxr/n1", "tell", "muxr", "n1", "reply to his note", st.me, source="msg:1")
assert r == "open", r
try:
    st.open(at, "tell:muxr/n2", "tell", "muxr", "n2", "reply", "main", source="msg:2")
except store.Refused:
    sys.exit(0)
print("a move stamped main was written by an owner:chat writer")
sys.exit(1)
PY

# (o) the adapter path refuses a move with no source, and a key without its kind's shape or naming another home
python3 -I - "$STORE_DIR" "$L" <<'PY' && ok o-adapter-path-refusals || bad o-adapter-path-refusals "see above"
import sys
sys.path.insert(0, sys.argv[1])
import itemdb, store
st = itemdb.open_db(sys.argv[2], "lead:muxr")
at = itemdb.stamp(st)
for key, src in (("wait:muxr/jg-8#k", None), ("wait:muxr/jg-8", "s:8"), ("wait:crewhouse/jg-8#k", "s:9")):
    try:
        st.open(at, key, "wait", "muxr", "jg-8", "w", st.me, source=src, named="lead")
    except store.Refused as e:
        print("refused as expected:", e)
        continue
    print("written:", key, src); sys.exit(1)
PY

# (p) the key contract: the task record gives the ticket and the project; work in Main's home for two projects (their
# policy rows came with muxr's in (b))
printf 'ticket=jg-a1.2\nproject=/srv/fleet/projects/alpha\n' > "$H/state/jg-a1-2.meta"
want p-key-work "$(printf 'work:main/jg-a1-2\tjg-a1.2\talpha')" jg key work --task jg-a1-2
want p-key-land "$(printf 'land:main/jg-a1.2@c0ffee1\tjg-a1.2\talpha')" jg key land --task jg-a1-2 --head c0ffee1
out=$(jg open work:main/jg-a1-2 --kind work --home main --subject jg-a1.2 --owes build --lane worker:main/jg-a1-2 --source sp:a1 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok p-work-needs-project || bad p-work-needs-project "[$out] exit $rc"
want p-work-in-main open jg open work:main/jg-a1-2 --kind work --home main --subject jg-a1.2 --owes build --lane worker:main/jg-a1-2 --project alpha --source sp:a1
want p-work-second-project open jg open work:main/jg-b1-1 --kind work --home main --subject jg-b1.1 --owes build --lane worker:main/jg-b1-1 --project beta --source sp:b1
st=$(python3 -I -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT stage FROM v_ticket WHERE ticket=?", ("jg-a1.2",)).fetchone()[0])' "$DB")
[ "$st" = work ] && ok p-ticket-read-by-id || bad p-ticket-read-by-id "[$st]"

# (q) a refused adapter write becomes one intake item for Main, once
python3 -I - "$STORE_DIR" "$L" <<'PY' && ok q-refusal-to-intake || bad q-refusal-to-intake "see above"
import sys
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "lead:muxr")
at = itemdb.stamp(st)
for _ in (1, 2):
    r = itemdb.or_intake(st, at, "st:jg-9:close", "muxr", "jg-9", st.close, at, "work:muxr/jg-9", "done", "receipt:x", st.me)
    assert r in ("intake", "again"), r
n = st.one("SELECT count(*) FROM item WHERE kind='intake' AND state='open' AND key LIKE 'intake:muxr/refused-%'")
assert n == 1, n
PY
# ... and so does a script's refused jg-item call with JG_ITEM_OR_INTAKE=1, once for the same source
for i in 1 2; do out=$(JG_ITEM_OR_INTAKE=1 jl close work:muxr/jg-nope done receipt:x --source st:nope 2>&1); rc=$?; done
n=$(jg board | grep -c 'intake:muxr/refused-')
[ "$rc" -eq 0 ] && [ "$out" = again ] && [ "$n" = 2 ] && ok q-cli-refusal-to-intake || bad q-cli-refusal-to-intake "[$out] exit $rc intake items [$n]"

# (r) the release word through itemdb, as the trunk adapter (adapter:trunk) and his word's channel (owner:trunk-word)
# write it: on a standard project his question, his yes, the covered head, a push after his yes asking again, and the
# release closed; on a loose project the step opens with no question. Nothing becomes an intake item.
python3 -I - "$STORE_DIR" "$H" <<'PY' && ok r-release-through-itemdb || bad r-release-through-itemdb "see above"
import sys
sys.path.insert(0, sys.argv[1])
import itemdb
home = sys.argv[2]
tr, ow = itemdb.open_db(home, "adapter:trunk"), itemdb.open_db(home, "owner:trunk-word")
n = [0]
def call(st, src, subj, fn, *a, **kw):     # each step 2 s after the last, so "before his yes" is never the same second
    n[0] += 2
    at = itemdb.stamp(st) + n[0]
    return itemdb.or_intake(st, at, src, "main", subj, fn, at, *a, **kw)
before = tr.one("SELECT count(*) FROM item WHERE kind='intake'")
assert call(tr, "push:h1", "alpha@41", tr.release_push, "alpha", "41", "h1") == "open"           # standard: his question
assert tr.item("question:release:alpha@41")["subject"] == "alpha@41"
assert call(tr, "push:h1", "alpha@41", tr.release_push, "alpha", "41", "h1") == "again"
assert call(ow, "trunk-word:1795000000@h1", "alpha@41", ow.close, "question:release:alpha@41", "done",
            "owner:trunk-word:1795000000@h1 pick=yes", ow.me,
            then=[dict(key="release:alpha@41", kind="release", home="alpha", subject="alpha@41",
                       owes="release pull request 41 of alpha, at h1", project="alpha")]) == "done"
assert tr.item("release:alpha@41") and tr.covered_head("alpha", "41") == "h1"
assert call(tr, "push:h2", "alpha@41", tr.release_push, "alpha", "41", "h2") == "open"           # after his yes: asked again
assert tr.covered_head("alpha", "41") == "h1"
assert call(ow, "trunk-word:1795000100@h2", "alpha@41", ow.close, "question:release:alpha@41", "done",
            "owner:trunk-word:1795000100@h2 pick=yes", ow.me) == "done"
assert tr.covered_head("alpha", "41") == "h2"
assert call(tr, "merged:41@h2", "alpha@41", tr.release_out, "alpha", "41", "h2") == "done"
assert call(tr, "push:h9", "muxr@7", tr.release_push, "muxr", "7", "h9") == "open"               # loose: the step itself
assert tr.item("release:muxr@7") and not tr.item("question:release:muxr@7") and tr.covered_head("muxr", "7") is None
assert call(tr, "merged:7@h9", "muxr@7", tr.release_out, "muxr", "7", "h9") == "done"
after = tr.one("SELECT count(*) FROM item WHERE kind='intake'")
assert after == before, (before, after)
try:
    at = itemdb.stamp(tr) + n[0] + 2
    tr.as_("tick").open(at, "question:release:alpha@42", "question", "alpha", "alpha", "release word: 42?", "tick", source="x:42")
    print("a release question with a ticket's subject was written"); sys.exit(1)
except Exception as e:
    assert "subject" in str(e), e
PY
want r-covered-head-cli h2 jg covered-head alpha 41

# (s) an alert opened with no holder, a call with no source and an error that is not a refusal each become one intake
# item (never lost behind a script's `|| true`); each again writes nothing new
python3 -I - "$STORE_DIR" "$H" <<'PY' && ok s-errors-to-intake || bad s-errors-to-intake "see above"
import sys
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "adapter:alerts")
at = itemdb.stamp(st)
before = st.one("SELECT count(*) FROM item WHERE kind='intake'")
for _ in (1, 2):
    r1 = itemdb.or_intake(st, at, "raise:lost-worker:jg-1@1", "main", "jg-1", st.open, at, "lost-worker:main/jg-1", "alert", "main", "jg-1", "the worker is gone", st.me)
    r2 = itemdb.or_intake(st, at, None, "main", "jg-1", st.open, at, "lost-worker:main/jg-2", "alert", "main", "jg-2", "the worker is gone", st.me, named="main")
    r3 = itemdb.or_intake(st, at, "raise:x@1", "main", "jg-1", st.open, at, "x:main/jg-1", "no-such-kind", "main", "jg-1", "x", st.me)
    assert {r1, r2, r3} <= {"intake", "again"}, (r1, r2, r3)
n = st.one("SELECT count(*) FROM item WHERE kind='intake'") - before
assert n == 3, n
why = " ".join(r[0] for r in st.con.execute("SELECT owes FROM item WHERE kind='intake' ORDER BY id DESC LIMIT 3"))
assert "names its first holder" in why and "source" in why and "KeyError" in why, why
PY
exit "$fail"
