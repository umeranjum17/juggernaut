#!/usr/bin/env bash
# shellcheck disable=SC2015 # pass/fail reporting lines: "check && pass || fail" is the intended shape here
# The tick journey of a worker's lease (bin/jg-delivery-tick.sh -> bin/jg-lease-tick.sh) on a fixture home with a real Beads store.
# Time is moved, not waited for: each step ages the beat records and the store's lease table by the seconds the tick gap stands for,
# then runs the real tick. Over 6 minutes a live pane's lease never lapses, with a 30 s tick (the watcher) and a 60 s tick (the
# sentinel alone), also with more live panes than one pass serves; a heartbeat leaves the changes read empty and shows in the in-progress
# read; a held ticket raises no alarm and takes a new lease after the hold; a done lane whose pane has exited keeps its row and is not
# relaunched; a row in progress with no task record is reclaimed after the grace time, naming who lost it, and a fresh start takes it.
# JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the builds; without them the run skips plainly.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip: jq is needed"; exit 0; }

T=$(jg_test_tmproot jg-lease-tick)
H=$T/home S=$H/state
CLI=$ROOT/bin/jg-backlog.sh WRAPPER=$ROOT/bin/jg-beads.sh
unset BEADS_DB BEADS_DOLT_SHARED_SERVER BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
mkdir -p "$T/store" "$S" "$H/config" "$H/data"
export TZ=UTC TMPDIR=$T BEADS_DIR=$T/store/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT JG_HOME=$H
printf '%s\n' "$BEADS_DIR" > "$H/config/beads-dir"
: > "$H/config/backlog-intake-loose"
"$WRAPPER" init --prefix jg >"$T/init.log" 2>&1 || fail "init the store: $(cat "$T/init.log")"

# The agent-state stub: a pane is alive when its task id is a line of $T/alive.
# shellcheck disable=SC2016 # the stub's own $1 is expanded when it runs
printf '#!/usr/bin/env bash\ngrep -qx -- "$1" "%s/alive" && echo alive || echo dead\n' "$T" > "$T/agent"
chmod +x "$T/agent"; : > "$T/alive"
export JG_LEASE_AGENT=$T/agent

bd() { "$WRAPPER" "$@"; }
row() { bd show "$1" --json 2>/dev/null | jq -r "(if type == \"array\" then .[0] else . end) | $2"; }
lease() { bd list --status in_progress --limit 0 --json 2>/dev/null | jq -r --arg id "$1" '.[] | select(.id == $id) | .lease_expires_at // empty'; }
lapsed() {  # <id>: succeeds when the row holds no lease that is still in the future.
  local at; at=$(lease "$1")
  [ -z "$at" ] || [ "$(date -u -d "$at" +%s)" -le "$(date +%s)" ]
}
held_leases() {  # the number of in-progress rows whose lease is still in the future, from one read.
  bd list --status in_progress --limit 0 --json 2>/dev/null | jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[.[] | select((.lease_expires_at // "") > $now)] | length'
}
seed() {  # <id> <agent name> [nometa]: a row owned by the name, a live pane, and its task record.
  "$CLI" add "$1" "[feature] Row $1" --priority 2 --body why >/dev/null || fail "seed $1"
  JG_BACKLOG_LANE=$2 JG_BACKLOG_SPAWN_GEN=g1 "$CLI" start "$1" >/dev/null || fail "start $1"
  [ -n "${3:-}" ] && return 0
  printf 'ticket=%s\nagent_name=%s\nspawn_gen=g1\nkind=ship\n' "$1" "$2" > "$S/$1.meta"
  echo "$1" >> "$T/alive"
}
age() {  # <seconds>: every stored time moves back, as if that long had passed.
  local f
  for f in "$S"/*.beat; do [ -e "$f" ] && touch -d "@$(( $(stat -c %Y "$f") - $1 ))" "$f"; done
  bd dolt sql -q "update leases set lease_expires_at = date_sub(lease_expires_at, interval $1 second), heartbeat_at = date_sub(heartbeat_at, interval $1 second)" >/dev/null 2>&1 \
    || fail "age the lease table"
}
tick() { bash "$ROOT/bin/jg-delivery-tick.sh" "$H" 2>"$T/tick.err" >"$T/tick.out"; }

# --- A start takes the lease; the changes read stays empty after a heartbeat, the in-progress read shows it. ---
seed jg-solo solo-agent
[ -n "$(lease jg-solo)" ] || fail "the start must take the lease, and the in-progress read must show lease_expires_at"
pass "a start takes the lease, and the in-progress read shows it"
before=$(row jg-solo .updated_at); revision=$(row jg-solo .revision); events=$(bd history jg-solo --events 2>/dev/null | wc -l)
mark=$(date -u -d '+1 second' +%Y-%m-%dT%H:%M:%SZ); sleep 2
age 130; tick || fail "the tick failed"
[ "$(row jg-solo .updated_at)" = "$before" ] && [ "$(row jg-solo .revision)" = "$revision" ] || fail "a heartbeat must not change the row"
[ "$(bd history jg-solo --events 2>/dev/null | wc -l)" = "$events" ] || fail "a heartbeat must write no history line"
[ "$(bd list --updated-after "$mark" --json 2>/dev/null | jq 'length')" = 0 ] || fail "the changes read must return nothing after a heartbeat"
lapsed jg-solo && fail "the tick must have sent the heartbeat that is 130 s after the start"
[ -e "$S/jg-solo.beat" ] || fail "the tick must record its beat in state/<task>.beat"
pass "a heartbeat leaves the changes read empty and the in-progress read shows the lease"

# --- 6 minutes with 21 live panes (one more than a pass serves): the watcher's 30 s tick, then the sentinel's 60 s tick alone. ---
for n in $(seq 1 21); do seed "jg-p$n" "pane-$n-agent"; done
for gap in 30 60; do
  for step in $(seq 1 $((360 / gap))); do
    age "$gap"; tick || fail "the tick failed"
    [ "$(held_leases)" = 22 ] || fail "a lease lapsed at $((step * gap)) s with a $gap s tick: $(held_leases) of 22 hold one"
  done
  pass "over 6 minutes of a $gap s tick no lease of 22 live panes lapses (a pass serves 20)"
done
[ ! -s "$T/tick.err" ] || fail "a quiet pass must say nothing, got: $(cat "$T/tick.err")"

# --- A held ticket: no alarm, no lease while held, a lease again after. ---
"$CLI" hold jg-solo --reason "wait for the owner" --kind parked >/dev/null || fail "hold"
age 130; tick || fail "the tick failed"
[ ! -s "$T/tick.err" ] || fail "a held ticket must raise no alarm, got: $(cat "$T/tick.err")"
[ -z "$(lease jg-solo)" ] || fail "a held ticket has no lease"
[ -z "$(find "$S" -maxdepth 1 -name '.alert*' -newer "$T/init.log" 2>/dev/null)" ] || fail "a held ticket must raise no alert record"
"$CLI" unhold jg-solo >/dev/null || fail "unhold"
age 130; tick || fail "the tick failed"
lapsed jg-solo && fail "the lease must come back after the hold"
pass "a ticket on hold gets no alarm, and its lease comes back after the hold"

# --- A done lane whose pane has exited: held past the grace time, not reclaimed, not relaunched. ---
seed jg-done done-agent
printf 'done [at=1]: ready in branch x\n' > "$S/jg-done.status"
grep -vx jg-done "$T/alive" > "$T/alive.new"; mv "$T/alive.new" "$T/alive"
age 1500; tick || fail "the tick failed"
[ "$(row jg-done .status)" = in_progress ] && [ "$(row jg-done .assignee)" = done-agent ] || fail "a lane with a task record keeps its row and its owner past the grace time"
! grep -q 'reclaimed' "$T/tick.out" "$T/tick.err" || fail "the tick must reclaim no lane with a record"
[ ! -e "$S/jg-done.exit" ] && [ ! -e "$S/jg-done.spawn" ] || fail "the tick must relaunch nothing"
lapsed jg-done || fail "a dead pane takes no heartbeat, so its lease runs out"
pass "a done lane with an exited pane is held past the grace time, not reclaimed, not relaunched"

# --- A row in progress with no task record: reported when asked, reclaimed after the grace time, and a fresh start takes it. ---
seed jg-orphan ghost-agent nometa
age 400; tick || fail "the tick failed"
[ "$(row jg-orphan .status)" = in_progress ] || fail "a lease 100 s past is inside the grace time"
age 600; printf 'report\n' > "$H/config/lease-reclaim"; tick || fail "the tick failed"
[ "$(row jg-orphan .status)" = in_progress ] || fail "report-only must write nothing"
grep -q 'would reclaim jg-orphan from ghost-agent' "$T/tick.out" "$T/tick.err" || fail "report-only must say what it would reclaim"
rm -f "$H/config/lease-reclaim"; tick || fail "the tick failed"
[ "$(row jg-orphan .status)" = open ] && [ -z "$(row jg-orphan '.assignee // empty')" ] || fail "the row must return to ready with no owner, got $(row jg-orphan .status) owned by $(row jg-orphan .assignee)"
grep -q 'reclaimed jg-orphan from ghost-agent' "$T/tick.out" "$T/tick.err" || fail "the line must name who lost the row"
JG_BACKLOG_LANE=fresh-agent JG_BACKLOG_SPAWN_GEN=g2 "$CLI" start jg-orphan >/dev/null || fail "a fresh start must take the reclaimed row"
[ "$(row jg-orphan .assignee)" = fresh-agent ] && [ -n "$(lease jg-orphan)" ] || fail "the fresh start owns the row and holds a lease"
pass "a row with no task record is reclaimed after the grace time, names who lost it, and a fresh start takes it"
