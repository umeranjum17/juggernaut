#!/usr/bin/env bash
# The cut-over imports of alerts and finished-lane cleanups, and the lane compare's reading of a gone lane's inbox.
# Drives core/item-store/adapters/{alerts,cleanup,lane}.py as processes in a temporary main home and a lead home.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
AD=$ROOT/core/item-store/adapters
d=$(mktemp -d) || exit 1
trap 'rm -rf -- "$d"' EXIT
H=$d/main; L=$d/lead
mkdir -p "$H/state/alerts" "$H/config" "$L/state/alerts" "$L/config"
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
q() { python3 -I -c 'import sqlite3, sys; r = sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone(); print("" if r is None else r[0])' "$DB" "$1"; }
py() { local home=$1 f=$2; shift 2; JG_HOME=$home python3 -I "$AD/$f" "$@"; }
rec() {   # <home> <alert> <subject> <state> [security source]
  printf 'alert=%s\nsubject=%s\nstate=%s\nsecurity_source=%s\n' "$2" "$3" "$4" "${5:-}" > "$1/state/alerts/$2--$3.rec"
}

python3 -I - "$ROOT/core/item-store" "$H" <<'PY' || { bad setup "store"; exit 1; }
import sys, time
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "owner:registry")
st.set_policy(int(time.time()) - 10, "proj", "standard", "owner:registry", "import:projects.md:proj")
PY
printf 'ticket=T-1\nproject=/x/proj\n' > "$H/state/lane1.meta"

# 1. alerts import: one item for each alert open today, none for a resolved or a plumbing one, run twice safe
rec "$H" lost-worker box1 open
rec "$H" lost-worker lane1 open
rec "$H" security leak1 open key-in-env
rec "$H" drift old1 resolved
rec "$H" undelivered steer-9 open
out=$(py "$H" alerts.py import "$H")
check alerts-import-opens-three 3 "$(q "select count(*) from item where kind in ('alert','security') and state='open'")"
check alerts-import-lane-by-ticket open "$(q "select state from item where key='lost-worker:main/T-1'")"
check alerts-import-security-fleet-item open "$(q "select state from item where key='security:fleet/security'")"
check alerts-import-skips-resolved 0 "$(q "select count(*) from item where key like 'drift:%'")"
check alerts-import-says-count "alerts import main: opened 3, already open 0" "$out"
before=$(q "select count(*) from move")
out=$(py "$H" alerts.py import "$H")
check alerts-import-twice-writes-nothing "$before" "$(q "select count(*) from move")"
check alerts-import-twice-says-so "alerts import main: nothing to import (3 already open)" "$out"
check alerts-compare-clean "" "$(py "$H" alerts.py compare "$H")"
check alerts-compare-clean-prints-no-blank-line 0 "$(py "$H" alerts.py compare "$H" | wc -c)"

# 1b. an alert resolved today whose item is still open closes on the next import; a live one, a security one and another home's stay;
# run twice safe
rec "$H" lost-worker box1 resolved
rm -f "$H/state/alerts/lost-worker--lane1.rec"
check alerts-compare-lists-resolved-today "2" "$(py "$H" alerts.py compare "$H" | grep -c 'today=absent store=open')"
out=$(py "$H" alerts.py import "$H")
check alerts-import-closes-resolved-today "done" "$(q "select state from item where key='lost-worker:main/box1'")"
check alerts-import-closes-removed-record "done" "$(q "select state from item where key='lost-worker:main/T-1'")"
check alerts-import-keeps-security-fleet-item open "$(q "select state from item where key='security:fleet/security'")"
check alerts-import-says-closed "alerts import main: opened 0, already open 1, closed 2" "$out"
before=$(q "select count(*) from move")
out=$(py "$H" alerts.py import "$H")
check alerts-import-closing-twice-writes-nothing "$before" "$(q "select count(*) from move")"
check alerts-import-closing-twice-says-so "alerts import main: nothing to import (1 already open)" "$out"
check alerts-compare-clean-after-close "" "$(py "$H" alerts.py compare "$H")"
rec "$H" lost-worker box1 open
rec "$H" lost-worker lane1 open
py "$H" alerts.py import "$H" >/dev/null

# 2. a lead home's alerts import into the same store under its own home id
rec "$L" capacity route-chain open
py "$L" alerts.py import "$L" >/dev/null
check alerts-import-lead-home open "$(q "select state from item where key='capacity:muxr/route-chain'")"

# 3. cleanup import: a finished lane's copy gets its cleanup item; a working lane gets none; run twice safe
printf 'ticket=T-2\nproject=/x/proj\n' > "$H/state/fin1.meta"; echo 'done [at=1]: ready' > "$H/state/fin1.status"
printf 'ticket=T-3\nproject=/x/proj\n' > "$H/state/live1.meta"; echo 'working [at=1]: on it' > "$H/state/live1.status"
check cleanup-compare-lists-finished "lane fin1: finished, its copy is still here, and no cleanup item is open" "$(py "$H" cleanup.py compare "$H")"
out=$(py "$H" cleanup.py import "$H")
check cleanup-import-opens-one open "$(q "select state from item where key='cleanup:main/fin1'")"
check cleanup-import-subject-ticket T-2 "$(q "select subject from item where key='cleanup:main/fin1'")"
check cleanup-import-skips-working 0 "$(q "select count(*) from item where key='cleanup:main/live1'")"
check cleanup-import-says-count "cleanup import main: opened 1, already open 0" "$out"
before=$(q "select count(*) from move")
out=$(py "$H" cleanup.py import "$H")
check cleanup-import-twice-writes-nothing "$before" "$(q "select count(*) from move")"
check cleanup-import-twice-says-so "cleanup import main: nothing to import (1 already open)" "$out"
check cleanup-compare-clean "" "$(py "$H" cleanup.py compare "$H")"

# 4. lane compare: the inbox of a lane with no record is left over, not a steer waiting; a recorded lane's unimported steer is
mkdir -p "$H/state/ghost.inbox" "$H/state/lane1.inbox"
echo hi > "$H/state/ghost.inbox/001.msg"; echo hi > "$H/state/lane1.inbox/002.msg"
echo 'working [at=1]: x' > "$H/state/lane1.status"
out=$(py "$H" lane.py compare "$H")
check lane-compare-gone-lane-inbox-ignored "lane1 steer#2 today=open store=closed" "$(printf '%s\n' "$out" | grep steer)"

# 5. cleanup import: an open cleanup whose copy is gone from disk closes (nothing is left to return); run twice safe
printf 'ticket=T-4\nproject=/x/proj\n' > "$H/state/gone1.meta"; echo 'done [at=1]: ready' > "$H/state/gone1.status"
py "$H" cleanup.py import "$H" >/dev/null
rm -f "$H/state/gone1.meta"
check cleanup-compare-lists-open-without-copy "cleanup cleanup:main/gone1: open, and no copy is on disk" "$(py "$H" cleanup.py compare "$H")"
out=$(py "$H" cleanup.py import "$H")
check cleanup-import-closes-open-without-copy "done" "$(q "select state from item where key='cleanup:main/gone1'")"
check cleanup-import-closes-says-so "cleanup import main: closed 1, nothing to open" "$out"
check cleanup-compare-clean-after-close "" "$(py "$H" cleanup.py compare "$H")"
before=$(q "select count(*) from move")
py "$H" cleanup.py import "$H" >/dev/null
check cleanup-import-closing-twice-writes-nothing "$before" "$(q "select count(*) from move")"

# 6. lane import: each wait that is open today (a lead's, an owner's) opens with the work; a finished lane's stale pause is no wait
for t in wl wo; do printf 'ticket=T-%s\nproject=/x/proj\n' "$t" > "$H/state/$t.meta"; done
printf 'working [at=1]: go\npaused [at=2] [wait=main] [reason=dependency] [key=dep]: waits for the release\n' > "$H/state/wl.status"
printf 'paused [at=2] [wait=captain] [reason=credential] [key=cred]: needs the account\n' > "$H/state/wo.status"
printf 'ticket=T-fin\nproject=/x/proj\n' > "$H/state/wf.meta"
printf 'paused [at=2] [wait=main] [reason=approval] [key=old]: recheck\ndone [at=3]: landed\n' > "$H/state/wf.status"
py "$H" lane.py import "$H" >/dev/null
check lane-import-opens-the-work open "$(q "select state from item where key='work:main/wl'")"
check lane-import-opens-the-lead-wait open "$(q "select state from item where key='wait:main/wl#dep'")"
check lane-import-opens-the-owner-wait open "$(q "select state from item where key='wait:main/wo#cred'")"
check lane-import-skips-finished-lane 0 "$(q "select count(*) from item where key like '%/wf%' and kind in ('work','wait')")"
check lane-compare-clean-after-import "" "$(py "$H" lane.py compare "$H" | grep -v ' steer#')"
before=$(q "select count(*) from move")
py "$H" lane.py import "$H" >/dev/null
check lane-import-twice-writes-nothing "$before" "$(q "select count(*) from move")"
# 7. lane import: a lane running today is a fact, so none is refused at the project's lane limit (the cut-over's own stamp); a lane opened later is
for n in 1 2 3 4 5 6; do printf 'ticket=T-r%s\nproject=/x/proj\n' "$n" > "$H/state/r$n.meta"; echo "working [at=1]: go" > "$H/state/r$n.status"; done
py "$H" lane.py import "$H" >/dev/null
check lane-import-over-limit-opens-every-lane 6 "$(q "select count(*) from item where kind='work' and state='open' and key like 'work:main/r%'")"
check lane-import-over-limit-refuses-none 0 "$(q "select count(*) from item where key like 'intake:main/refused-%'")"
check lane-compare-clean-over-limit "" "$(py "$H" lane.py compare "$H" | grep -v ' steer#')"
exit "$fail"
