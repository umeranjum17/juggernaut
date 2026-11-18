#!/usr/bin/env bash
# The lane adapter of the item store (core/item-store/adapters/lane.py) and the scripts that call it: every status line, steer and
# Recon handoff also writes the store, by the replay's word table (rows 0 to 15). Temporary homes only: a main home with two projects
# (alpha standard, beta tight, ticket ids that differ from the task ids) and a lead home bound to it. One fixture line per row,
# read one line at a time, each giving exactly its row's move, holder and proof; then run-twice, the guarded append, the outside wait,
# resolved, waits-for, jg-send and jg-delivery, the Recon critic link, import, compare, a refused write, the store-answered
# jg_wait_is_open on 1,000 and 100,000 lines, and the wiring dry run.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
FIX=$ROOT/tests/fixtures/item-store-lane-lines
LANE=$ROOT/core/item-store/adapters/lane.py
ITEM=$ROOT/core/item-store/jg-item
W=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf -- "$W"' EXIT
fail=0
ok()  { echo "ok $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2], want [$3]"; fi; }

# ---- homes
mkhome() {   # <dir> <tag>: a home with the fixture's task records, bin and core linked, the item-store switch on
  local h=$1 tag=$2 f
  mkdir -p "$h/state" "$h/config" "$h/projects/alpha" "$h/projects/beta" "$h/data"
  ln -sn "$ROOT/bin" "$h/bin"; ln -sn "$ROOT/core" "$h/core"; : > "$h/config/item-store"
  for f in "$FIX/$tag"/state/*.meta; do [ -e "$f" ] && sed "s#@D@#$W#g" "$f" > "$h/state/$(basename "$f")"; done
}
policy() {   # <home>: the cut-over's one run: alpha standard, beta tight
  python3 -I - "$ROOT/core/item-store" "$1" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "owner:registry")
t = int(time.time()) - 10
for pj, lvl in (("alpha", "standard"), ("beta", "tight")):
    st.set_policy(t, pj, lvl, "owner:registry", "import:projects.md:" + pj, lanes=16)
PY
}
H=$W/main; L=$W/lead
mkhome "$H" main; mkhome "$L" lead
printf 'crewhouse\n' > "$L/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$L/.jg-squad-lead-parent"
policy "$H"
DB=$H/state/item-store/fleet.db
sq() { python3 -I -c 'import sqlite3,sys
c = sqlite3.connect(sys.argv[1])
for r in c.execute(sys.argv[2]): print("|".join("" if x is None else str(x) for x in r))' "$DB" "$1"; }
item() { sq "SELECT state,kind,holder,holder_id,subject,coalesce(project,'-'),coalesce(outcome,'-') FROM item WHERE key='$1' ORDER BY gen DESC LIMIT 1"; }
due()  { sq "SELECT due_at-opened_at FROM item WHERE key='$1' ORDER BY gen DESC LIMIT 1"; }
nmoves() { sq "SELECT count(*) FROM move"; }
lastmove() { sq "SELECT verb,coalesce(why,'') FROM move WHERE key='$1' ORDER BY seq DESC LIMIT 1"; }
UNTIL=$(date -u -d '+3 days' +%Y-%m-%dT%H:%MZ)
UNTIL_EPOCH=$(date -u -d "$UNTIL" +%s)
mkdir -p "$W/n"
feed() {   # <home> <tag> <task>: append the fixture's next line to the status file and read it
  local home=$1 tag=$2 task=$3 n line
  n=$(( $(cat "$W/n/$tag.$task" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$W/n/$tag.$task"
  line=$(sed -n "${n}p" "$FIX/$tag/state/$task.status" | sed "s/@UNTIL@/$UNTIL/")
  printf '%s\n' "$line" >> "$home/state/$task.status"
  python3 -I "$LANE" read "$home/state/$task.status"
}
SA=work:main/ship-a

# ---- row 2, 14 and 8: the first line opens the work (project and ticket from the record), then the line's own row
feed "$H" main ship-a
eq row2-work-opens "$(item $SA)" "open|work|worker|worker:main/ship-a|TA-1|alpha|-"
eq row14-note-on-work "$(lastmove $SA)" "note|starting the slice"
feed "$H" main ship-a
eq row8-own-wait-is-a-note "$(lastmove $SA)" "note|thinking it over"
n0=$(nmoves); feed "$H" main ship-a
eq row7-no-holder-writes-no-move "$(nmoves)" "$n0"
if grep -qP 'status:main/ship-a@\d+\trefused: no wait holder$' "$H/state/item-store/status-written.log"; then ok row7-counted-as-refused; else bad row7-counted-as-refused "no refused line in the log"; fi

# ---- row 9: a wait with no holder named goes to Main (this is the main home); a second line is a note
feed "$H" main ship-a
eq row9-wait-opens "$(item "wait:main/ship-a#q1")" "open|wait|main|main|TA-1|-|-"
eq row9-wait-due-one-hour "$(due "wait:main/ship-a#q1")" "3600"
feed "$H" main ship-a
eq row9-second-line-is-a-note "$(lastmove "wait:main/ship-a#q1")" "note|still need a word from main"
eq row9-one-wait-item "$(sq "SELECT count(*) FROM item WHERE key='wait:main/ship-a#q1'")" "1"
# paused with wait=outside and an until time: due at that time
feed "$H" main ship-a
eq row9-outside-wait "$(item "wait:main/ship-a#ci" | cut -d'|' -f1-4)" "open|wait|outside|outside"
eq row9-outside-due-at-until "$(sq "SELECT due_at FROM item WHERE key='wait:main/ship-a#ci'")" "$UNTIL_EPOCH"
# row 6: a wait for the owner goes to Main, never to the owner
feed "$H" main ship-a
eq row6-owner-wait-on-main "$(item "wait:main/ship-a#own" | cut -d'|' -f1-4)" "open|wait|main|main"
eq row6-due-thirty-minutes "$(due "wait:main/ship-a#own")" "1800"
case $(sq "SELECT owes FROM item WHERE key='wait:main/ship-a#own'") in "turn this into one owner question or answer it: pick a colour") ok row6-text ;; *) bad row6-text "wrong text" ;; esac
eq row6-no-owner-question "$(sq "SELECT count(*) FROM item WHERE kind='question'")" "0"
# row 11: resolved with its key closes that wait done
feed "$H" main ship-a
eq row11-resolved-closes-wait "$(item "wait:main/ship-a#ci" | cut -d'|' -f1,7)" "done|answer:the quota came back"
# row 12: a key that names no open wait; row 13: no key on open work
n0=$(nmoves); feed "$H" main ship-a
eq row12-resolved-no-such-wait-no-move "$(nmoves)" "$n0"
feed "$H" main ship-a
eq row13-keyless-resolved-is-a-note "$(lastmove $SA)" "note|resolved: all good so far"

# ---- row 3: done opens the next steps in the same write, the land with the line's head; jg-item landed prints nothing yet
feed "$H" main ship-a
eq row3-work-closed-with-receipt "$(item $SA | cut -d'|' -f1,7)" "done|receipt:r1"
eq row3-land-opens "$(item "land:main/TA-1@abc1234")" "open|land|tick|tick|TA-1|alpha|-"
eq row3-cleanup-opens "$(item "cleanup:main/ship-a" | cut -d'|' -f1-5)" "open|cleanup|main|main|TA-1"
eq row3-one-write "$(sq "SELECT count(DISTINCT at) FROM move WHERE key IN ('$SA','land:main/TA-1@abc1234','cleanup:main/ship-a') AND verb IN ('close','open') AND at=(SELECT at FROM move WHERE key='$SA' AND verb='close')")" "1"
eq row3-landed-prints-nothing "$(env -u JG_TASK_ID JG_HOME="$H" "$ITEM" landed TA-1)" ""
# row 4: done or failed on closed work
n0=$(nmoves); feed "$H" main ship-a; feed "$H" main ship-a
eq row4-no-move "$(nmoves)" "$n0"
# row 15: working on work closed done opens it again (a new generation)
feed "$H" main ship-a
eq row15-rework "$(sq "SELECT state,gen,owes FROM item WHERE key='$SA' ORDER BY gen DESC LIMIT 1")" "open|2|rework after done"
# row 5: failed on open work goes to the lead (Main in the main home)
feed "$H" main ship-a
eq row5-failed-handed-to-main "$(item $SA | cut -d'|' -f1-4)" "open|work|main|main"
eq row5-failed-text "$(lastmove $SA)" "hand|failed: the rework broke"

# ---- row 3b: a tight project's done opens no land, a Main-held land-word wait instead
feed "$H" main ship-b; feed "$H" main ship-b
eq row3b-no-land "$(sq "SELECT count(*) FROM item WHERE kind='land' AND subject='TB-1'")" "0"
eq row3b-land-word-wait "$(item "wait:main/ship-b#land-word" | cut -d'|' -f1-5)" "open|wait|main|main|TB-1"
eq row3b-due-thirty-minutes "$(due "wait:main/ship-b#land-word")" "1800"
case $(sq "SELECT owes FROM item WHERE key='wait:main/ship-b#land-word'") in *"ask the owner to land def5678"*"question:land:main/TB-1@def5678"*) ok row3b-text ;; *) bad row3b-text "wrong text" ;; esac
eq row3b-cleanup-opens "$(item "cleanup:main/ship-b" | cut -d'|' -f1-2)" "open|cleanup"
# a Recon's done opens its report, for Main
feed "$H" main recon-a; feed "$H" main recon-a
eq row3-recon-report "$(item "report:main/recon-a" | cut -d'|' -f1-5)" "open|report|main|main|RA-1"
eq row3-recon-proof "$(item work:main/recon-a | cut -d'|' -f1,7)" "done|report:data/recon-a/report.md"
eq row3-recon-no-land "$(sq "SELECT count(*) FROM item WHERE kind='land' AND subject='RA-1'")" "0"
# the project and ticket of every lane: v_ticket answers by ticket id, never by task id
eq vticket-by-ticket-id "$(sq "SELECT ticket FROM v_ticket WHERE ticket IN ('TA-1','TB-1','RA-1','ship-a','ship-b','recon-a') ORDER BY ticket")" "$(printf 'RA-1\nTA-1\nTB-1')"
eq both-projects-in-main-home "$(sq "SELECT group_concat(DISTINCT project) FROM (SELECT project FROM item WHERE kind='work' ORDER BY project)")" "alpha,beta"

# ---- row 1: a task with no record is one intake item for Main, later lines a note on it
cp "$FIX/main/state/noreco.status" "$W/noreco.status"; : > "$H/state/noreco.status"
feed "$H" main noreco
eq row1-intake-opens "$(item intake:main/noreco | cut -d'|' -f1-4)" "open|intake|main|main"
eq row1-intake-due "$(due intake:main/noreco)" "3600"
feed "$H" main noreco
eq row1-second-line-is-a-note "$(lastmove intake:main/noreco | cut -d'|' -f1)" "note"
eq row1-one-intake-item "$(sq "SELECT count(*) FROM item WHERE kind='intake'")" "1"

# ---- row 0: any line closes the worker-stopped alert of its ticket
python3 -I - "$ROOT/core/item-store" "$H" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import itemdb, store as S
st = itemdb.open_db(sys.argv[2], "adapter:liveness")
at = itemdb.stamp(st)
st.open(at, S.Store.alert_key("worker-stopped", "main", "AL-1"), "alert", "main", "AL-1", "the worker stopped writing", st.me, source="stuck:AL-1", named="main")
PY
feed "$H" main alive
eq row0-alert-closed-by-a-line "$(item worker-stopped:main/AL-1 | cut -d'|' -f1,7)" "done|gone: the worker wrote again"

# ---- row 10: waits-for opens a blocker on that ticket's open work; its done closes the blocker in the same write; nothing open: a dispatch
feed "$H" main t2-lane
feed "$H" main wf-1; feed "$H" main wf-1
eq row10-blocker-parent "$(sq "SELECT kind,state,parent,subject FROM item WHERE key='waits-for:main/wf-1#T2'")" "blocker|open|work:main/t2-lane|W1"
feed "$H" main t2-lane
eq row10-blocker-closes-with-the-step "$(sq "SELECT state FROM item WHERE key='waits-for:main/wf-1#T2'")" "done"
eq row10-same-write "$(sq "SELECT (SELECT at FROM move WHERE key='waits-for:main/wf-1#T2' AND verb='close') = (SELECT at FROM move WHERE key='work:main/t2-lane' AND verb='close')")" "1"
feed "$H" main wf-1
eq row10-dispatch-when-nothing-open "$(sq "SELECT kind,state,subject,holder FROM item WHERE key='dispatch:main/T9'")" "dispatch|open|T9|main"
eq row10-one-dispatch "$(sq "SELECT count(*) FROM item WHERE kind='dispatch' AND subject='T9'")" "1"
feed "$H" main wf-1

# ---- the lead home: a wait for the lead, a failed lane handed to the lead; the work is in Main's store under the lead's home
feed "$L" lead lane-c; feed "$L" lead lane-c
eq lead-wait-holder "$(item "wait:crewhouse/lane-c#x" | cut -d'|' -f1-4)" "open|wait|lead|lead:crewhouse"
eq lead-work-project "$(item work:crewhouse/lane-c | cut -d'|' -f1,5,6)" "open|TC-1|alpha"
feed "$L" lead lane-c
eq lead-failed-handed-to-lead "$(item work:crewhouse/lane-c | cut -d'|' -f1-4)" "open|work|lead|lead:crewhouse"
if [ -e "$L/state/item-store" ]; then bad lead-no-own-store "the lead home made its own store"; else ok lead-no-own-store; fi

# ---- read twice writes nothing; scan writes nothing; a partial last line is left for the next run
n0=$(nmoves)
for t in ship-a ship-b recon-a; do python3 -I "$LANE" read "$H/state/$t.status"; done
python3 -I "$LANE" scan "$H"
eq read-twice-writes-nothing "$(nmoves)" "$n0"
printf 'working [at=99]: half a li' >> "$H/state/ship-b.status"
python3 -I "$LANE" read "$H/state/ship-b.status"
eq partial-line-not-read "$(nmoves)" "$n0"
printf 'ne\n' >> "$H/state/ship-b.status"
python3 -I "$LANE" read "$H/state/ship-b.status"
if [ "$(nmoves)" -gt "$n0" ]; then ok partial-line-read-once-whole; else bad partial-line-read-once-whole "not read"; fi

# ---- the guarded append writes the move at once
printf 'working [at=1]: through the guard\n' | env -u JG_TASK_ID JG_HOME="$H" "$ROOT/bin/jg-lavish-guard.sh" --append "$H/state/guard-t.status"
eq guard-append-writes-at-once "$(lastmove work:main/guard-t)" "note|through the guard"
n0=$(nmoves)
env -u JG_TASK_ID JG_HOME="$H" "$ROOT/bin/jg-lavish-guard.sh" --append "$H/state/guard-t.status" 'paused [at=2] [wait=lead] [reason=review]: waiting for review' >/dev/null 2>&1
eq guard-append-wait-at-once "$(item wait:main/guard-t#pause | cut -d'|' -f1-3)" "open|wait|main"
rm "$H/config/item-store"; n1=$(nmoves)
env -u JG_TASK_ID JG_HOME="$H" "$ROOT/bin/jg-lavish-guard.sh" --append "$H/state/guard-t.status" 'working [at=3]: with the switch off' >/dev/null 2>&1
eq guard-silent-without-switch "$(nmoves)" "$n1"
: > "$H/config/item-store"

# ---- a refused write (a project with no policy row) is one intake item, not a lost line, and not one per line
HG=$W/gamma; mkdir -p "$HG/state" "$HG/config"; ln -sn "$ROOT/bin" "$HG/bin"; ln -sn "$ROOT/core" "$HG/core"
printf 'kind=ship\nproject=%s/projects/gamma\nticket=TG-1\n' "$W" > "$HG/state/gamma-t.meta"
printf 'blocked [at=1] [key=k]: stuck on a project with no policy\nblocked [at=2] [key=k]: still stuck\n' > "$HG/state/gamma-t.status"
python3 -I "$LANE" read "$HG/state/gamma-t.status"
DBG=$HG/state/item-store/fleet.db
eq refused-write-is-one-intake-item "$(python3 -I -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from item where kind=\"intake\"").fetchone()[0])' "$DBG")" "1"
eq refused-write-no-work "$(python3 -I -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from item where kind=\"work\"").fetchone()[0])' "$DBG")" "0"

# ---- the adapter's own record, for the stamp check
out=$(JG_HOME="$H" "$ROOT/core/item-store/logs/adapter-status")
if printf '%s\n' "$out" | grep -qP '^status:main/ship-a@0\twork:main/ship-a$'; then ok log-reader-prints-pairs; else bad log-reader-prints-pairs "no ship-a pair"; fi
if printf '%s\n' "$out" | awk -F'\t' 'NF!=2{bad=1} END{exit bad}'; then ok log-reader-two-columns; else bad log-reader-two-columns "a line is not two columns"; fi

# ---- jg-send: the steer and the wait it answers are one write; jg-delivery handled closes the steer
mkdir -p "$W/fakebin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/tmux"; cp "$W/fakebin/tmux" "$W/fakebin/sleep"; chmod +x "$W/fakebin/tmux" "$W/fakebin/sleep"
printf 'window=sess:jg-sendee\nkind=ship\nharness=claude\nproject=%s/projects/alpha\nticket=SD-1\n' "$W" > "$H/state/sendee.meta"
printf 'working [at=1]: on it\nblocked [at=2] [key=k1]: need an answer\n' > "$H/state/sendee.status"
python3 -I "$LANE" read "$H/state/sendee.status"
send() { env -u JG_TASK_ID PATH="$W/fakebin:$PATH" JG_ROOT_OVERRIDE="$H" JG_HOME="$H" JG_SEND_SETTLE=0 "$ROOT/bin/jg-send.sh" "$@" >/dev/null 2>"$W/send.err"; }
send sendee --resolve-key k1 "the answer is yes, go on"; rc=$?
eq send-exit "$rc" "0"
eq send-closes-the-wait "$(item "wait:main/sendee#k1" | cut -d'|' -f1,7)" "done|answer:steer:main/sendee/1"
eq send-opens-the-steer "$(item steer:main/sendee/1 | cut -d'|' -f1-5)" "open|steer|worker|worker:main/sendee|SD-1"
eq send-one-write "$(sq "SELECT (SELECT at FROM move WHERE key='wait:main/sendee#k1' AND verb='close' ORDER BY seq DESC LIMIT 1) = (SELECT at FROM move WHERE key='steer:main/sendee/1' AND verb='open')")" "1"
case $(sq "SELECT owes FROM item WHERE key='steer:main/sendee/1'") in *"the answer is yes, go on"*) ok send-steer-text ;; *) bad send-steer-text "wrong text" ;; esac
send sendee "a plain steer"
eq send-plain-steer-opens "$(item steer:main/sendee/2 | cut -d'|' -f1-3)" "open|steer|worker"
env -u JG_TASK_ID JG_HOME="$H" "$ROOT/bin/jg-delivery.sh" handled sendee 1 --evidence status:the-line >/dev/null 2>&1
eq delivery-handled-closes-the-steer "$(item steer:main/sendee/1 | cut -d'|' -f1,7)" "done|handled:status:the-line"
# a refused steer (a ticket the store cannot subject) is one intake item
printf 'window=sess:jg-badt\nkind=ship\nharness=claude\nproject=%s/projects/alpha\nticket=bad/ticket\n' "$W" > "$H/state/badt.meta"
send badt "a steer the store refuses"
eq send-refused-is-one-intake "$(sq "SELECT count(*) FROM move WHERE source='refused:send:badt/1' AND verb='open'")" "1"

# ---- the Recon's critic is a link written at assignment; a draft-ready sends the round by that link
for t in recon-r crit-c crit-d; do mkdir -p "$H/data/$t"; done
printf 'kind=scout\nproject=%s/projects/alpha\nticket=RR-1\n' "$W" > "$H/state/recon-r.meta"
printf 'kind=scout\nproject=%s/projects/alpha\nticket=CC-1\n' "$W" > "$H/state/crit-c.meta"
printf 'kind=scout\nproject=%s/projects/alpha\nticket=CD-1\n' "$W" > "$H/state/crit-d.meta"
printf 'working [at=1]: reading\n' > "$H/state/recon-r.status"; python3 -I "$LANE" read "$H/state/recon-r.status"
printf '# findings\n' > "$H/data/recon-r/report.md"
RH() { env -u JG_TASK_ID JG_HOME="$H" "$ROOT/bin/jg-recon-handoff.sh" "$@" >/dev/null 2>&1; }
RH draft recon-r
eq draft-ready-without-critic-asks-for-one "$(sq "SELECT kind,state FROM item WHERE key='dispatch:main/RR-1/critic'")" "dispatch|open"
RH assign recon-r --critic crit-c; rc=$?
eq assign-exit "$rc" "0"
eq assign-links-the-critic "$(sq "SELECT kind,state,parent,holder_id,subject,project FROM item WHERE key='work:main/crit-c'")" "work|open|work:main/recon-r|worker:main/crit-c|CC-1|alpha"
RH assign recon-r --critic crit-d; rc=$?
eq second-critic-refused-by-the-script "$rc" "1"
eq store-holds-one-critic-link "$(sq "SELECT count(*) FROM item WHERE kind='work' AND state='open' AND parent='work:main/recon-r'")" "1"
eq ready-sends-the-round-to-the-critic "$(env -u JG_TASK_ID JG_HOME="$H" "$ITEM" ready work:main/recon-r d2 --source ready:test:d2)" "round"
eq round-is-a-steer-to-the-critic-lane "$(sq "SELECT kind,holder,holder_id FROM item WHERE key='steer:main/crit-c/round@d2'")" "steer|worker|worker:main/crit-c"

# ---- import: work for a live lane, none for a done one; twice writes nothing
H2=$W/imp; mkhome "$H2" main; policy "$H2"
printf 'working [at=1]: live\n' > "$H2/state/ship-a.status"
printf 'working [at=1]: x\ndone [at=2] [head=eee]: ready\n' > "$H2/state/ship-b.status"
python3 -I "$LANE" import "$H2"
DB=$H2/state/item-store/fleet.db
eq import-opens-live-work "$(item work:main/ship-a | cut -d'|' -f1,2,5,6)" "open|work|TA-1|alpha"
eq import-no-work-for-done "$(sq "SELECT count(*) FROM item WHERE key='work:main/ship-b'")" "0"
eq import-cursor-at-end "$(cat "$H2/state/item-store/cursors/main.ship-a")" "$(wc -c < "$H2/state/ship-a.status")"
n0=$(nmoves); python3 -I "$LANE" import "$H2"
eq import-twice-writes-nothing "$(nmoves)" "$n0"
python3 -I "$LANE" scan "$H2"
eq scan-after-import-writes-nothing "$(nmoves)" "$n0"
DB=$H/state/item-store/fleet.db

# ---- compare: nothing on a home whose store and status files agree; a wait closed only in the file and a steer only on disk are listed
HC=$W/cmp; mkhome "$HC" compare; policy "$HC"
for t in cmp-a cmp-b; do cp "$FIX/compare/state/$t.status" "$HC/state/$t.status"; python3 -I "$LANE" read "$HC/state/$t.status"; done
out=$(python3 -I "$LANE" compare "$HC"); rc=$?
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then ok compare-clean-on-agreeing-homes; else bad compare-clean-on-agreeing-homes "exit $rc [$out]"; fi
printf 'resolved [at=20] [key=q1]: closed only in the file\n' >> "$HC/state/cmp-a.status"
mkdir -p "$HC/state/cmp-b.inbox"; printf 'a steer only on disk\n' > "$HC/state/cmp-b.inbox/001.msg"
out=$(python3 -I "$LANE" compare "$HC"); rc=$?
eq compare-lists-each-difference-once "$out" "$(printf 'cmp-a wait#q1 today=closed store=open\ncmp-b steer#1 today=open store=closed')"
eq compare-exit-one "$rc" "1"
printf 'blocked [at=21] [key=extra]: only in the file\n' >> "$HC/state/cmp-a.status"
mv "$HC/state/cmp-b.inbox/001.msg" "$HC/state/cmp-b.inbox/002.msg"
eq compare-wait-only-in-the-file "$(python3 -I "$LANE" compare "$HC" | grep -c 'wait#extra today=open store=closed')" "1"

# ---- jg_wait_is_open answers from the store once config/item-store-reads exists, the same on 1,000 and 100,000 lines
HB=$W/big; mkhome "$HB" main; policy "$HB"
printf 'kind=ship\nproject=%s/projects/alpha\nticket=BG-1\n' "$W" > "$HB/state/big.meta"
# shellcheck source=bin/jg-classify-lib.sh
. "$ROOT/bin/jg-classify-lib.sh"
# shellcheck source=bin/jg-wait-write-lib.sh
. "$ROOT/bin/jg-wait-write-lib.sh"
for size in 1000 100000; do
  seq 1 "$size" | sed 's/^\(.*\)$/working [at=\1]: filler/' > "$HB/state/big.status"
  printf 'blocked [at=1] [key=kb]: the one wait\n' >> "$HB/state/big.status"
  last=$(printf 'blocked [at=1] [key=kb]: the one wait\n' | wc -c)
  rm -rf "$HB/state/item-store" "$HB/config/item-store-reads"
  policy "$HB"
  mkdir -p "$HB/state/item-store/cursors"; echo $(( $(wc -c < "$HB/state/big.status") - last )) > "$HB/state/item-store/cursors/main.big"
  python3 -I "$LANE" read "$HB/state/big.status"
  export JG_HOME=$HB
  if [ "$size" -eq 1000 ]; then    # the fold of 100,000 lines takes minutes: that is the cost the store removes
    jg_wait_is_open "$HB/state/big.status" kb; folded=$?
    jg_wait_is_open "$HB/state/big.status" zz; folded_no=$?
  fi
  : > "$HB/config/item-store-reads"
  jg_wait_is_open "$HB/state/big.status" kb; stored=$?
  jg_wait_is_open "$HB/state/big.status" zz; stored_no=$?
  eq "wait-is-open-$size-lines-open-and-closed" "$stored$stored_no" "01"
  [ "$size" -ne 1000 ] || eq "wait-is-open-$size-lines-same-answer-as-the-fold" "$folded$folded_no" "$stored$stored_no"
  printf 'working [at=1]: the file no longer says it\n' > "$HB/state/big.status"
  jg_wait_is_open "$HB/state/big.status" kb; rc=$?
  eq "wait-is-open-$size-lines-store-answers" "$rc" "0"
  unset JG_HOME
done

# ---- the wiring dry run writes nothing
HW=$W/wire; mkdir -p "$HW/state"; ln -sn "$ROOT/bin" "$HW/bin"; ln -sn "$ROOT/core" "$HW/core"
out=$("$ROOT/core/item-store/lanes-wiring.sh" --dry-run "$HW" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qxF "would run: env -u JG_STATE_OVERRIDE JG_HOME=$HW $HW/bin/jg-check-register.sh item-store-lanes" \
   && printf '%s\n' "$out" | grep -qF "lane.py" && printf '%s\n' "$out" | tail -n 1 | grep -qx 'dry run: nothing written' && [ -z "$(ls -A "$HW/state")" ]; then
  ok lanes-wiring-dry-run
else
  bad lanes-wiring-dry-run "exit $rc [$out]"
fi
out=$("$ROOT/core/item-store/lanes-unwiring.sh" --dry-run "$HW" 2>&1)
if printf '%s\n' "$out" | grep -qx "item-store-lanes: not wired in $HW"; then ok lanes-unwiring-dry-run; else bad lanes-unwiring-dry-run "[$out]"; fi

# ---- the replay's counts are the fixture the table was read from
if python3 -I -c 'import json,sys; j=json.load(open(sys.argv[1])); sys.exit(0 if j["lines"]==1010 and sum(j["outcomes"].values())>=1010 else 1)' "$FIX/replay-status-lines.json"; then
  ok replay-fixture-1010-lines
else
  bad replay-fixture-1010-lines "unexpected fixture"
fi
exit "$fail"
