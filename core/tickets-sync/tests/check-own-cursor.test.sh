#!/usr/bin/env bash
# The board shows work that is in progress, whatever order the watcher runs its checks in. The watcher runs the
# read-only stale check and then the poll in one sweep, each inside its time budget. The check once walked the poll's
# own cursor, so the poll skipped every row the check had walked, and on the fleet six rows in progress (the tip-red
# fix, lead sweeps, the /tmp leak, lander retries, a project on the board, the green tip) never reached the board: the
# check said "ticket says no state" for each. This test files those six rows, starts each one, and runs the sweeps
# (stale check, then poll) with a budget of one row per pass: real jg-backlog.sh on a Beads store, the installed
# watcher checks and real sign-off-axi, in isolated homes.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-sync-cursor.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fork=${JG_TEST_FORK:-$(cd "$root/.." && pwd -P)}
[ -f "$fork/bin/jg-backlog.sh" ] || { echo "FAIL: $fork is not a Juggernaut checkout (no bin/jg-backlog.sh); set JG_TEST_FORK"; exit 1; }
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export JG_HOME=$work/main
mkdir -p "$HOME" "$JG_HOME"/{data,config,state}
ln -s "$fork/bin" "$JG_HOME/bin"
ln -s "$fork/core" "$JG_HOME/core"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
# shellcheck source=core/lib/beads-test-env.sh disable=SC1091
. "$root/lib/beads-test-env.sh"
core_beads_home "$fork" "$JG_HOME"
rows='trunk-tests-red-on-tip|[blocker] Fix three jg-trunk tests red on the trunk tip
lead-sweeps-landed-lanes|[feature] Lead heartbeat sweeps landed lanes and finished Recons
tmp-leak-disk-full|[blocker] Juggernaut scripts leak /tmp files until the disk quota is full
gc-a1|[feature] Lander retries a red caused by /tmp, a checkout error or a slow read
gc-c3|[feature] Every Juggernaut ticket has a project on the board
tip-green-owner|[feature] Friction fix: make the trunk tip green and keep it green'
while IFS='|' read -r item title; do
  (cd "$JG_HOME" && jg-backlog.sh add "$item" "$title" --repo juggernaut --priority 1 >/dev/null && jg-backlog.sh start "$item" >/dev/null)
  printf 'working [at=1700000000]: building %s\n' "$item" > "$JG_HOME/state/$item.status"
done <<<"$rows"
bash "$root/tickets-sync/wiring.sh" >/dev/null
# One row per pass: a pass handles the row it resumed on and stops before the next.
export JG_TICKETS_SYNC_BUDGET_SECS=0
fail=0
board_state() { sign-off-axi ticket "$work/board.json" --json 2>/dev/null | python3 -c '
import hashlib, json, sys
tickets = {t["id"]: t for t in json.load(sys.stdin)["tickets"]}
t = tickets.get("jg-" + hashlib.sha256(("main/" + sys.argv[1]).encode()).hexdigest()[:32], {})
print(t.get("state") or "no state")' "$1"; }
sweeps=$(grep -c . <<<"$rows")
for sweep in $(seq "$sweeps"); do
  env -u JG_HOME "$JG_HOME/state/tickets-stale.check.sh" > "$work/stale-$sweep.out"
  env -u JG_HOME "$JG_HOME/state/tickets-sync.check.sh" > "$work/sync-$sweep.out"
  # A walk that resumed part-way never calls a row it did not read this pass unaccounted.
  if grep -q "no home's work accounts for it" "$work/stale-$sweep.out"; then
    echo "FAIL: sweep $sweep: the stale check called a row unaccounted after a partial walk: $(cat "$work/stale-$sweep.out")"; fail=1
  fi
  # The poll publishes the next row of its own walk on every sweep: the check walking first takes none of them.
  published=0
  while IFS='|' read -r item _; do [ "$(board_state "$item")" = 'in progress' ] && published=$((published + 1)); done <<<"$rows"
  [ "$published" = "$sweep" ] || { echo "FAIL: after sweep $sweep the board shows $published of the rows in progress, not $sweep"; fail=1; }
done
while IFS='|' read -r item title; do
  state=$(board_state "$item")
  [ "$state" = 'in progress' ] || { echo "FAIL: $item ($title) is in progress in the backlog and the board says $state"; fail=1; }
done <<<"$rows"
# The next stale check, a whole walk, finds the board true: no row says "no state".
for _ in $(seq "$sweeps"); do env -u JG_HOME "$JG_HOME/state/tickets-stale.check.sh"; done > "$work/stale-final.out"
if [ -s "$work/stale-final.out" ]; then echo "FAIL: the stale check still reports rows on a true board: $(cat "$work/stale-final.out")"; fail=1; fi
# The check walks with its own cursor and leaves the poll's alone.
test -e "$JG_HOME/state/tickets-sync/check-cursor.json" || { echo 'FAIL: the stale check kept no cursor of its own'; fail=1; }
[ "$fail" = 0 ] || exit 1
echo 'PASS: rows in progress reach the board on the poll that follows the stale check, and a true board reads silent'
