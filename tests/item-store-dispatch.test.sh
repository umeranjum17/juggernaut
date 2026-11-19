#!/usr/bin/env bash
# The dispatch adapter of the item store (core/item-store/adapters/dispatch.py) and the scripts that call it: an approved ticket is
# owed until a lane starts it. Temporary homes only: a main home with two projects (alpha with two lanes, beta with one) and a lead
# home bound to it. Part 1 drives the adapter: an approval opens one dispatch held by the lead, the same approval again writes
# nothing, a spawn closes it `lane:<task>` and opens the lane's work with the task record's project, 25 hours with no spawn climb it
# to Main, a project at its lane limit refuses the spawn's work (one intake item), `compare` prints nothing when the records agree
# and each difference once, a lane cleaned before its done line opens #1 and then #2, and a reopen at the lane limit waits with its
# new words and no steer until a lane frees. Part 2 runs the real core/auto-dispatch/dispatch.sh and the real bin/jg-spawn.sh over a
# fixture project and checks the guarded lines in both, and that they change nothing when the switch file is absent.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DISPATCH=$ROOT/core/item-store/adapters/dispatch.py
W=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf -- "$W"' EXIT
fail=0
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/item-store-dispatch.log}   # a sealed run keeps what the test printed
say() { echo "$1"; [ -z "$LOG" ] || echo "$1" >> "$LOG"; }
ok()  { say "ok $1"; }
bad() { say "FAIL $1: $2"; fail=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2], want [$3]"; fi; }

mkhome() {   # <dir>: a home with bin and core linked and the item-store switch on
  mkdir -p "$1/state/dispatch-approved" "$1/config" "$1/projects/alpha" "$1/projects/beta" "$1/data"
  ln -sn "$ROOT/bin" "$1/bin"; ln -sn "$ROOT/core" "$1/core"; : > "$1/config/item-store"
}
record() {   # <home> <task> <ticket> <project>: a task record, as the spawn writes it
  printf 'kind=ship\nticket=%s\nproject=%s/projects/%s\n' "$3" "$1" "$4" > "$1/state/$2.meta"
}
approval() { printf 'approved-at=%s\nharness=codex\nmodel=m\neffort=low\n' "$3" > "$1/state/dispatch-approved/$2"; }
H=$W/main; L=$W/lead
mkhome "$H"; mkhome "$L"
printf 'crewhouse\n' > "$L/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$L/.jg-squad-lead-parent"
python3 -I - "$ROOT/core/item-store" "$H" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "owner:registry")
t = int(time.time()) - 10
for pj, lanes in (("alpha", 2), ("beta", 1)):
    st.set_policy(t, pj, "standard", "owner:registry", "import:projects.md:" + pj, lanes=lanes)
PY
DB=$H/state/item-store/fleet.db
sq() { python3 -I -c 'import sqlite3,sys
c = sqlite3.connect(sys.argv[1])
for r in c.execute(sys.argv[2]): print("|".join("" if x is None else str(x) for x in r))' "$DB" "$1"; }
item() { sq "SELECT state,kind,holder,holder_id,subject,coalesce(project,'-'),coalesce(outcome,'-') FROM item WHERE key='$1' ORDER BY gen DESC LIMIT 1"; }
due()  { sq "SELECT due_at-opened_at FROM item WHERE key='$1' ORDER BY gen DESC LIMIT 1"; }
nmoves() { sq "SELECT count(*) FROM move"; }
disp() { JG_HOME=$1 python3 -I "$DISPATCH" "${@:2}"; }

# ---- an approval opens one dispatch held by the lead, 24 hours; the same approval again writes nothing
disp "$H" approve main TA-1 --source approval:TA-1@100
eq approve-opens-dispatch "$(item dispatch:main/TA-1)" "open|dispatch|main|main|TA-1|-|-"
eq approve-held-24-hours "$(due dispatch:main/TA-1)" "86400"
disp "$L" approve crewhouse TL-1 --source approval:TL-1@100
eq approve-in-lead-home-is-held-by-the-lead "$(item dispatch:crewhouse/TL-1)" "open|dispatch|lead|lead:crewhouse|TL-1|-|-"
n0=$(nmoves); disp "$H" approve main TA-1 --source approval:TA-1@100
eq approve-twice-writes-nothing "$(nmoves)" "$n0"
disp "$H" approve main TA-1 --source approval:TA-1@200
eq approve-new-record-is-a-note "$(sq "SELECT verb FROM move WHERE key='dispatch:main/TA-1' ORDER BY seq DESC LIMIT 1")" "note"
eq approve-one-item "$(sq "SELECT count(*) FROM item WHERE key='dispatch:main/TA-1'")" "1"

# ---- a spawn closes it lane:<task> and opens the lane's work with the task record's project; two projects in Main's home
record "$H" ship-a TA-1 alpha; approval "$H" TA-1 100
disp "$H" spawned main ship-a --source spawn:ship-a
eq spawn-closes-dispatch-with-the-lane "$(item dispatch:main/TA-1)" "done|dispatch|main|main|TA-1|-|lane:ship-a"
eq spawn-opens-work-alpha "$(item work:main/ship-a)" "open|work|worker|worker:main/ship-a|TA-1|alpha|-"
disp "$H" approve main TB-1 --source approval:TB-1@100; record "$H" ship-b TB-1 beta; approval "$H" TB-1 100
disp "$H" spawned main ship-b --source spawn:ship-b
eq spawn-opens-work-beta "$(item work:main/ship-b)" "open|work|worker|worker:main/ship-b|TB-1|beta|-"
n0=$(nmoves); disp "$H" spawned main ship-b --source spawn:ship-b
eq spawn-twice-writes-nothing "$(nmoves)" "$n0"
eq work-parent-is-the-dispatch "$(sq "SELECT parent FROM item WHERE key='work:main/ship-a'")" "dispatch:main/TA-1"

# ---- 25 hours with no spawn: the tick climbs the lead's dispatch to Main
python3 -I - "$ROOT/core/item-store" "$H" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], None)
st.tick(itemdb.stamp(st) + 25 * 3600)
PY
eq tick-climbs-the-lead-dispatch-to-main "$(item dispatch:crewhouse/TL-1 | cut -d'|' -f1-4)" "open|dispatch|main|main"

# ---- the project's lane limit reached: the spawn's work is refused, and that refusal is one intake item
disp "$H" approve main TB-2 --source approval:TB-2@100; record "$H" ship-b2 TB-2 beta; approval "$H" TB-2 100
disp "$H" spawned main ship-b2 --source spawn:ship-b2
eq limit-leaves-the-dispatch-open "$(item dispatch:main/TB-2 | cut -d'|' -f1,2)" "open|dispatch"
eq limit-refuses-the-work "$(sq "SELECT count(*) FROM item WHERE key='work:main/ship-b2'")" "0"
eq limit-refusal-is-one-intake "$(sq "SELECT count(*) FROM item WHERE kind='intake' AND home='main'")" "1"
disp "$H" spawned main ship-b2 --source spawn:ship-b2
eq limit-refusal-again-is-the-same-intake "$(sq "SELECT count(*) FROM item WHERE kind='intake'")" "1"

# ---- compare prints nothing when the records agree; an approval with no dispatch item is listed once, exit 1
rm -f "$H/state/ship-b2.meta"
out=$(disp "$H" compare "$H"); rc=$?
eq compare-agrees-prints-nothing "$out|$rc" "|0"
approval "$H" TX-9 100
out=$(disp "$H" compare "$H"); rc=$?
eq compare-lists-the-missing-dispatch "$out|$rc" "approved TX-9: no open dispatch:main/TX-9 in the store|1"
record "$H" ship-b2 TB-2 beta   # the lane is there again for the later steps

# ---- a lane cleaned before its done line opens #1, a second time #2
eq prior-work-open "$(disp "$H" prior-work ship-b)" "open"
eq prior-work-none-exits-1 "$(disp "$H" prior-work no-such-task; echo $?)" "1"
eq next-is-1 "$(disp "$H" next main TB-1)" "1"
disp "$H" requeue main TB-1 1 --words "the lane was cleaned before its done line" --source requeue:TB-1#1
eq requeue-opens-1 "$(item "dispatch:main/TB-1#1")" "open|dispatch|main|main|TB-1|-|-"
eq requeue-carries-the-words "$(sq "SELECT why FROM move WHERE key='dispatch:main/TB-1#1' AND verb='open'")" "start TB-1 again: the lane was cleaned before its done line"
eq next-names-the-open-wait "$(disp "$H" next main TB-1)" "1"
python3 -I - "$ROOT/core/item-store" "$H" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "adapter:dispatch")
st.close(itemdb.stamp(st), "dispatch:main/TB-1#1", "dropped", "test: the lane started", "adapter:dispatch", source="test:drop1")
PY
eq next-after-a-closed-requeue-is-2 "$(disp "$H" next main TB-1)" "2"
disp "$H" requeue main TB-1 2 --words "cleaned again" --source requeue:TB-1#2
eq requeue-opens-2 "$(item "dispatch:main/TB-1#2")" "open|dispatch|main|main|TB-1|-|-"

# ---- a reopen at the lane limit waits with its new words and no steer; when a lane frees, the spawn closes it
disp "$H" requeue main TB-2 1 --words "reopened at the lane limit: add the missing case" --source requeue:TB-2#1
eq reopen-waits-as-a-dispatch "$(item "dispatch:main/TB-2#1" | cut -d'|' -f1,2)" "open|dispatch"
eq reopen-opens-no-steer "$(sq "SELECT count(*) FROM item WHERE kind='steer'")" "0"
python3 -I - "$ROOT/core/item-store" "$H" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "adapter:status")
st.close(itemdb.stamp(st), "work:main/ship-b", "done", "receipt:test", "adapter:status", source="test:free")
PY
disp "$H" spawned main ship-b2 --source spawn:ship-b2-again
eq freed-lane-spawn-closes-the-plain-dispatch "$(item dispatch:main/TB-2 | cut -d'|' -f1,7)" "done|lane:ship-b2"
eq freed-lane-spawn-closes-the-reopen "$(item "dispatch:main/TB-2#1" | cut -d'|' -f1,7)" "done|lane:ship-b2"
eq freed-lane-work-opens "$(item work:main/ship-b2 | cut -d'|' -f1,6)" "open|beta"
out=$(disp "$H" compare "$H" | grep -c 'TB-2\|TA-1\|TB-1' ); eq compare-clean-for-the-spawned-tickets "$out" "0"

# ---- part 2: the real scripts
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot item-store-dispatch)
P2=$TMP_ROOT/world; HD=$P2/home; PROJ=$P2/proj
mkdir -p "$P2"
git init -q --bare "$P2/origin.git"; git -C "$P2/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$P2/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true
FAKEBIN=$(make_spawn_fakebin "$P2/fake"); jg_test_fake_sleep_noop "$FAKEBIN"
jg_test_spawn_home "$HD"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HD/config/host-memory"
ln -sn "$ROOT/core" "$HD/core" 2>/dev/null || true
DB2=$HD/state/item-store/fleet.db
sq2() { python3 -I -c 'import sqlite3,sys
c = sqlite3.connect(sys.argv[1])
for r in c.execute(sys.argv[2]): print("|".join("" if x is None else str(x) for x in r))' "$DB2" "$1"; }
mkticket() {   # <id> <title>: a queued ticket with its brief and a copy to start from
  jg_test_add "$HD" "$1" "$2"
  JG_HOME="$HD" "$ROOT/bin/jg-brief.sh" "$1" proj --mode direct-PR --project "$PROJ" --migration-row none >/dev/null 2>&1 || { bad "setup-$1" "no brief"; return 1; }
  sed -i 's/{TASK}/Exercise the dispatch lines./;s/{JUGGERNAUT_SPEC}/Exercise the dispatch lines end to end./' "$HD/data/$1/brief.md"
  git -C "$PROJ" worktree add -q --detach "$P2/wt-$1" origin/main >/dev/null 2>&1 || bad "setup-$1" "no copy"
}
spawn() { out=$(jg_test_run_spawn "$HD" "$P2/wt-$1" "$FAKEBIN" "$1" "$PROJ" codex --mode direct-PR --yolo off); rc=$?; }
for t in 0 1 2 3 4; do mkticket "jg-ds$t" "[feature] dispatch lines $t"; done
mkdir -p "$HD/state/dispatch-approved" "$HD/data/auto-dispatch"
for t in 1 2; do approval "$HD" "jg-ds$t" 100; done
check() { JG_AUTO_DISPATCH_BACKLOG="$ROOT/bin/jg-backlog.sh" "$ROOT/core/auto-dispatch/dispatch.sh" check "$HD" >/dev/null 2>&1; }
store() {   # <python statements over st, itemdb and key helpers>: one write as the named adapter
  python3 -I - "$ROOT/core/item-store" "$HD" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "adapter:status")
at = itemdb.stamp(st)
exec(sys.argv[3])
PY
}

# the switch off: the spawn writes no store
spawn jg-ds0
eq spawn-switch-off-exit-0 "$rc" "0"
eq spawn-switch-off-no-store "$(find "$HD/state" -name fleet.db 2>/dev/null | wc -l)" "0"

# the switch on, a policy row for the fixture project with one lane: the check opens the dispatch; the spawn closes it, opens the work
: > "$HD/config/item-store"
python3 -I - "$ROOT/core/item-store" "$HD" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "owner:registry")
st.set_policy(int(time.time()) - 10, "proj", "standard", "owner:registry", "import:projects.md:proj", lanes=1)
PY
check
eq check-opens-the-dispatch "$(sq2 "SELECT state||'|'||holder FROM item WHERE key='dispatch:main/jg-ds1'")" "open|main"
eq check-opens-one-per-approval "$(sq2 "SELECT count(*) FROM item WHERE kind='dispatch'")" "2"
check
eq check-twice-writes-no-second-item "$(sq2 "SELECT count(*) FROM item WHERE kind='dispatch'")" "2"
spawn jg-ds1
eq spawn-exit-0 "$rc" "0"
eq spawn-closes-its-dispatch "$(sq2 "SELECT state||'|'||outcome FROM item WHERE key='dispatch:main/jg-ds1'")" "done|lane:jg-ds1"
eq spawn-opens-its-work "$(sq2 "SELECT state||'|'||project FROM item WHERE key='work:main/jg-ds1'")" "open|proj"

# the project at its lane limit: the second spawn's work is refused by the store (one intake item); the spawn itself still runs
spawn jg-ds2
eq limit-spawn-still-runs "$rc" "0"
eq limit-spawn-leaves-its-dispatch-open "$(sq2 "SELECT state FROM item WHERE key='dispatch:main/jg-ds2'")" "open"
eq limit-spawn-one-intake "$(sq2 "SELECT count(*) FROM item WHERE kind='intake'")" "1"

# a reopen finds the project at its capacity: it waits as a dispatch with the new words, no steer, and the spawn defers (exit 75)
store 'st.close(at, "work:main/jg-ds1", "done", "receipt:test", "adapter:status", source="test:free1");
st.open(at, "work:main/jg-ds3", "work", "main", "jg-ds3", "an earlier lane", "adapter:status", source="test:earlier3", lane="worker:main/jg-ds3", project="proj");
st.close(at, "work:main/jg-ds3", "done", "receipt:test", "adapter:status", source="test:done3")'
printf 'proj 1\n' > "$HD/config/project-capacity"
spawn jg-ds3
eq reopen-at-the-limit-defers "$rc" "75"
eq reopen-waits-as-a-dispatch "$(sq2 "SELECT state FROM item WHERE key='dispatch:main/jg-ds3#1'")" "open"
case $(sq2 "SELECT why FROM move WHERE key='dispatch:main/jg-ds3#1' AND verb='open'") in
  "start jg-ds3 again: reopened at the lane limit: "*) ok reopen-carries-the-new-words ;; *) bad reopen-carries-the-new-words "no words" ;;
esac
eq reopen-opens-no-steer "$(sq2 "SELECT count(*) FROM item WHERE kind='steer'")" "0"
spawn jg-ds3
eq reopen-deferred-again-is-the-same-item "$(sq2 "SELECT count(*) FROM item WHERE kind='dispatch' AND subject='jg-ds3'")" "1"
rm -f "$HD/config/project-capacity"

# a lane cleaned before its done line leaves its work open: the next spawn of the ticket opens #1 and then closes it with its lane
store 'st.close(at, "work:main/jg-ds2", "dropped", "test: cleaned", "adapter:status", source="test:drop2") if st.item("work:main/jg-ds2") else None;
st.open(at, "work:main/jg-ds4", "work", "main", "jg-ds4", "an earlier lane", "adapter:status", source="test:earlier4", lane="worker:main/jg-ds4", project="proj")'
spawn jg-ds4
eq cleaned-lane-respawn-exit-0 "$rc" "0"
eq cleaned-lane-opened-one-requeue "$(sq2 "SELECT state||'|'||outcome FROM item WHERE key='dispatch:main/jg-ds4#1'")" "done|lane:jg-ds4"
eq cleaned-lane-requeue-carries-the-words "$(sq2 "SELECT substr(why,1,24) FROM move WHERE key='dispatch:main/jg-ds4#1' AND verb='open'")" "start jg-ds4 again: Exer"
JG_HOME=$HD python3 -I "$DISPATCH" compare "$HD" > "$P2/compare.out" 2>&1
eq compare-real-home-agrees "$(grep -c 'jg-ds1\|jg-ds4' "$P2/compare.out")" "0"
exit "$fail"
