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
exit "$fail"
