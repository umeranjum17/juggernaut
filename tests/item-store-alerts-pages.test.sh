#!/usr/bin/env bash
# Slice 4 of the item store: alerts, security and Main-down as items, and Main's wake reading its pages.
# Drives bin/jg-alert.sh, core/item-store/adapters/{alerts,supervision}.py, jg-item and the instructions renderer as
# processes, in a temporary main home and a lead home bound to it (one host, one store file).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ITEM=$ROOT/core/item-store/jg-item
ALERTS=$ROOT/core/item-store/adapters/alerts.py
SUP=$ROOT/core/item-store/adapters/supervision.py
d=$(mktemp -d) || exit 1
trap 'rm -rf -- "$d"' EXIT
H=$d/main; L=$d/lead
mkdir -p "$H/state" "$H/config" "$L/state" "$L/config"
printf 'muxr\n' > "$L/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$L/.jg-squad-lead-parent"
H=$(cd "$H" && pwd -P); L=$(cd "$L" && pwd -P)
: > "$H/config/item-store"; : > "$L/config/item-store"
DB=$H/state/item-store/fleet.db
export JG_ITEM_TICK_LEASE_S=0
unset JG_TASK_ID JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_ALERT_NOW
fail=0
ok()  { echo "ok $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }
jg() { JG_HOME=$H "$ITEM" "$@"; }
jl() { JG_HOME=$L "$ITEM" "$@"; }
alert_h() { JG_HOME=$H bash "$ROOT/bin/jg-alert.sh" "$@"; }
alert_l() { JG_HOME=$L bash "$ROOT/bin/jg-alert.sh" "$@"; }
q() {   # one value from the store
  python3 -I -c 'import sqlite3, sys; r = sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone(); print("" if r is None else r[0])' "$DB" "$1"
}
now=$(date +%s)

# the store, a policy row for the fixture project, and the lane's record (ticket T-1)
python3 -I - "$ROOT/core/item-store" "$H" <<'PY' || { bad setup "store"; exit 1; }
import sys, time
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "owner:registry")
st.set_policy(int(time.time()) - 10, "proj", "standard", "owner:registry", "import:projects.md:proj")
PY
printf 'ticket=T-1\nproject=/x/proj\n' > "$H/state/lane1.meta"

# 1. a repeat is a note; resolve closes with gone:
JG_ALERT_NOW=$now alert_h raise lost-worker box1 >/dev/null 2>&1
JG_ALERT_NOW=$((now + 1)) alert_h raise lost-worker box1 >/dev/null 2>&1
check raise-one-item 1 "$(q "select count(*) from item where key='lost-worker:main/box1'")"
check raise-repeat-is-a-note 1 "$(q "select count(*) from move where key='lost-worker:main/box1' and verb='note'")"
check raise-first-holder-main main "$(q "select holder from item where key='lost-worker:main/box1'")"
alert_h resolve lost-worker--box1 --proof source:seen-alive >/dev/null 2>&1
check resolve-closes-gone "done gone:source:seen-alive" "$(q "select state || ' ' || outcome from item where key='lost-worker:main/box1'")"

# 2. one security cause is one fleet item, whichever home raises it
alert_h raise security leak1 --security-source key-in-env >/dev/null 2>&1
alert_l raise security leak2 --security-source key-in-env >/dev/null 2>&1
check security-one-fleet-item 1 "$(q "select count(*) from item where kind='security' and state='open' and key like 'security:fleet/%'")"
check security-second-home-is-a-note 1 "$(q "select count(*) from move where key='security:fleet/security' and verb='note'")"

# 3. delivery trouble raises no item
alert_h raise undelivered steer-9 >/dev/null 2>&1
check undelivered-no-item 0 "$(q "select count(*) from item where key like 'undelivered:%'")"

# 4. a lane's alerts are keyed by its ticket and held by its lead; its done close drops them (Y5)
alert_h raise lost-worker lane1 >/dev/null 2>&1
alert_h raise worker-stopped lane1 >/dev/null 2>&1
check lane-alerts-by-ticket 2 "$(q "select count(*) from item where kind='alert' and state='open' and subject='T-1' and key in ('lost-worker:main/T-1','worker-stopped:main/T-1')")"
jg open work:main/lane1 --kind work --home main --subject T-1 --owes "build T-1" --project proj --source disp:lane1 >/dev/null 2>&1
check lane-work-open open "$(q "select state from item where key='work:main/lane1'")"

# 5. compare: nothing after the raises; a record with no item is listed once
check compare-clean "" "$(JG_HOME=$H python3 -I "$ALERTS" compare "$H")"
printf 'alert=ghost\nsubject=x\nstate=open\n' > "$H/state/alerts/ghost--x.rec"
out=$(JG_HOME=$H python3 -I "$ALERTS" compare "$H"); rc=$?
check compare-lists-record-only "ghost:main/x missing-item today=open store=absent" "$out"
check compare-exit-1 1 "$rc"
rm -f "$H/state/alerts/ghost--x.rec"

# 6. an alert opened with no holder named is one intake item, and no alert
python3 -I - "$ROOT/core/item-store" "$H" <<'PY' || bad no-named-fixture "fixture failed"
import sys
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "adapter:alerts")
at = itemdb.stamp(st)
itemdb.or_intake(st, at, "fix:1", "main", "S", st.open, at, "alert:main/S", "alert", "main", "S", "no holder named", st.me)
PY
check no-named-no-alert 0 "$(q "select count(*) from item where key='alert:main/S'")"
check no-named-one-intake 1 "$(q "select count(*) from item where kind='intake' and key like 'intake:main/refused-%'")"
# a raise the schema refuses (an empty cause makes no legal key) becomes one more intake item
JG_HOME=$H python3 -I "$ALERTS" raise "" box9 --source fix:2 >/dev/null 2>&1
check refused-raise-intake 1 "$(q "select count(*) from move where source='refused:fix:2'")"
check refused-raise-no-alert 0 "$(q "select count(*) from item where key like ':main/%'")"

# 7. the lane's done close leaves no open alert on T-1
jg close work:main/lane1 "done" receipt:abc --source st:lane1 >/dev/null 2>&1
check lane-done-closes-alerts 0 "$(q "select count(*) from item where kind='alert' and state='open' and subject='T-1'")"

# 8. Main-down from a lead home: stale beat opens, fresh beat closes done back:, the main home writes nothing
touch -d '20 minutes ago' "$H/state/.last-watcher-beat"
before=$(q "select count(*) from move")
JG_HOME=$H python3 -I "$SUP" check "$H"
check main-home-writes-nothing "$before" "$(q "select count(*) from move")"
JG_HOME=$L python3 -I "$SUP" check "$L"
check main-down-open open "$(q "select state from item where key='main-down:main/supervision'")"
JG_HOME=$L python3 -I "$SUP" check "$L"
check main-down-open-once 1 "$(q "select count(*) from move where key='main-down:main/supervision' and verb='open'")"
touch "$H/state/.last-watcher-beat"
JG_HOME=$L python3 -I "$SUP" check "$L"
check main-down-back "done" "$(q "select state from item where key='main-down:main/supervision'")"
case "$(q "select outcome from item where key='main-down:main/supervision'")" in back:*) ok main-down-back-proof ;; *) bad main-down-back-proof "no back: close" ;; esac
check supervision-log-lines 2 "$(JG_HOME=$H "$ROOT/core/item-store/logs/adapter-supervision" | wc -l | tr -d ' ')"
# a back: close with no line in the supervision log is a finding of the stamp check
grep -v '^back:' "$H/state/item-store/supervision-written.log" > "$d/log" && cp "$d/log" "$H/state/item-store/supervision-written.log"
out=$(jg stamp-check 2>&1)
case "$out" in *"back:"*"main-down:main/supervision"*) ok stamp-check-finds-back ;; *) bad stamp-check-finds-back "[$out]" ;; esac
case "$out" in *"beat:"*) bad stamp-check-keeps-open "flagged a logged open: [$out]" ;; *) ok stamp-check-keeps-open ;; esac

# 9. Main's watcher stopped: the lead home's tick climbs Main-down to the owner
touch -d '30 minutes ago' "$H/state/.last-watcher-beat"
JG_HOME=$L python3 -I "$SUP" check "$L" --due 2
check main-down-reopened open "$(q "select state from item where key='main-down:main/supervision' order by gen desc limit 1")"
sleep 3
jl tick >/dev/null 2>&1
check main-down-owner owner "$(q "select holder from item where key='main-down:main/supervision' and state='open'")"

# 10. 10,000 unread pages: the capped read and the refused ack
python3 -I - "$ROOT/core/item-store" "$H" <<'PY' || bad bulk "fixture failed"
import sys
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "adapter:alerts")
at = itemdb.stamp(st)
st.con.execute("BEGIN")
for i in range(10000):
    st.open(at, "intake:main/bulk-%d" % i, "intake", "main", "bulk", "an arrival to place " + "x" * 120, st.me, source="bulk:%d" % i)
st.con.execute("COMMIT")
PY
out=$(jg pages main); lines=$(printf '%s\n' "$out" | wc -l | tr -d ' '); bytes=$(printf '%s\n' "$out" | wc -c | tr -d ' ')
if [ "$lines" -le 201 ] && [ "$bytes" -le 32768 ]; then ok pages-capped; else bad pages-capped "$lines lines, $bytes bytes"; fi
last=$(printf '%s\n' "$out" | tail -n 1)
case "$last" in pages:*" more after ack;"*) ok pages-count-line ;; *) bad pages-count-line "[$last]" ;; esac
seq=${last##*ack=}
res=$(jg ack main $((seq + 1000)) 2>&1); rc=$?
case "$res" in refused:*) [ "$rc" -eq 1 ] && r=0 || r=1 ;; *) r=1 ;; esac
if [ "$r" -eq 0 ]; then ok ack-past-refused; else bad ack-past-refused "exit $rc [$res]"; fi
check ack-ok ok "$(jg ack main "$seq")"

# 11. the rendered instructions carry the pages step only when config/item-store exists
X=$d/x; mkdir -p "$X/config"
off=$(JG_HOME=$X bash "$ROOT/bin/jg-supervision-instructions.sh" --harness claude 2>&1)
: > "$X/config/item-store"
on=$(JG_HOME=$X bash "$ROOT/bin/jg-supervision-instructions.sh" --harness claude 2>&1)
case "$off" in *"jg-item pages main"*) bad pages-step-absent "present without config/item-store" ;; *) ok pages-step-absent ;; esac
case "$on" in *"After the drain, run \`core/item-store/jg-item pages main\`"*"jg-item ack main <seq>"*) ok pages-step-present ;; *) bad pages-step-present "missing" ;; esac

# 12. the Main-down check is wired in a lead home only
T=$d/wire; mkdir -p "$T/state"; ln -sn "$ROOT/bin" "$T/bin"; ln -sn "$ROOT/core" "$T/core"
printf 'muxr\n' > "$T/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$T/.jg-squad-lead-parent"
T=$(cd "$T" && pwd -P)
out=$("$ROOT/core/item-store/supervision-wiring.sh" --dry-run "$T" 2>&1); rc=$?
want="would run: env -u JG_STATE_OVERRIDE JG_HOME=$T $T/bin/jg-check-register.sh item-store-supervision"
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qxF "$want"; then ok wiring-dry-run; else bad wiring-dry-run "exit $rc [$out]"; fi
M=$d/mainwire; mkdir -p "$M/state"; ln -sn "$ROOT/bin" "$M/bin"; ln -sn "$ROOT/core" "$M/core"
out=$("$ROOT/core/item-store/supervision-wiring.sh" --dry-run "$M" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "the main home cannot watch itself"; then ok wiring-refuses-main; else bad wiring-refuses-main "exit $rc [$out]"; fi
exit "$fail"
