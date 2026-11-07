#!/usr/bin/env bash
# Slice N8 on a real Beads store: the lane is bd's actor, so a comment and an event carry who wrote them, and the
# assignee is what keeps a held row in flight, so no metadata.hold_from is written or read. The store is the pinned
# bd and dolt, unchanged: no table, column, trigger or CHECK is added. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name
# the builds; without them the run skips plainly.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

T=$(jg_test_tmproot jg-beads-native-n8)
WRAPPER=$ROOT/bin/jg-beads.sh CLI=$ROOT/bin/jg-tasks-axi.sh
unset BEADS_DB BEADS_DOLT_SHARED_SERVER BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
mkdir -p "$T/store" "$T/home/config" "$T/home/data" "$T/home/state"
export TZ=UTC TMPDIR=$T BEADS_DIR=$T/store/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
printf '%s\n' "$BEADS_DIR" > "$T/home/config/beads-dir"
jail=()
command -v bwrap >/dev/null && jail=(bwrap --ro-bind / / --tmpfs /tmp --bind "$T" "$T" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent)

bd() { "${jail[@]}" "$WRAPPER" "$@"; }
axi() { JG_HOME="$T/home" "${jail[@]}" "$CLI" "$@"; }
as_lane() {  # <lane> <command...>: one write made from that lane.
  local name=$1
  shift
  JG_BACKLOG_LANE=$name JG_BACKLOG_AGENT=claude "$@"
}
field() {  # <id> <jq filter>: one value of the row as bd prints it.
  bd show "$1" --json 2>/dev/null | jq -r "(if type == \"array\" then .[0] else . end) | $2"
}
state_of() {  # <id>: the state the backlog lists the row under.
  local state
  for state in in_flight queued "done"; do
    axi list --state "$state" --fields state 2>/dev/null | grep -q "^  $1," && { printf '%s' "$state"; return; }
  done
}
shape() { bd dolt sql -q 'show tables' 2>&1; bd dolt sql -q 'show create table issues' 2>&1; bd dolt sql -q 'select constraint_name from information_schema.check_constraints order by 1' 2>&1; }

bd init --prefix jg >/dev/null 2>&1 || fail "init the store"
before=$(shape)
for id in n8-a n8-b n8-c n8-d n8-e n8-f; do axi add "$id" "[feature] Row $id" --priority 2 --body why >/dev/null || fail "seed $id"; done

# The lane is the actor: a comment and the events of a write carry it.
as_lane s1.1.1 axi start n8-a >/dev/null || fail "start from a lane"
[ "$(field n8-a .assignee)" = s1.1.1 ] || fail "the lane must own the row"
as_lane s1.1.1 "${jail[@]}" "$WRAPPER" comments add n8-a "from the lane" >/dev/null 2>&1 || fail "comment from a lane"
authors=$(bd comments n8-a --json 2>/dev/null | jq -r 'map(.author) | unique | join(",")')
[ "$authors" = s1.1.1 ] || fail "a lane's comment must carry the lane, got [$authors]"
printf 'ok - the comment author is the lane\n'
actors=$(bd dolt sql -q "select distinct actor from events where issue_id = 'n8-a' and event_type <> 'created' order by 1" 2>&1)
assert_contains "$actors" s1.1.1 "the events of a lane's write must carry the lane"
assert_not_contains "$actors" juggernaut "no event of a lane's write may carry the default actor"
printf 'ok - the events carry the lane\n'

# With no lane the actor is the caller's, else juggernaut.
bd comments add n8-a "from nobody" >/dev/null 2>&1 || fail "comment from the default"
BEADS_ACTOR=fixture "${jail[@]}" "$WRAPPER" comments add n8-a "from the caller" >/dev/null 2>&1 || fail "comment from a named actor"
authors=$(bd comments n8-a --json 2>/dev/null | jq -r 'map(.author) | unique | join(",")')
[ "$authors" = fixture,juggernaut,s1.1.1 ] || fail "the default and the caller's actor must stay, got [$authors]"
printf 'ok - no lane keeps the caller and the default actor\n'

# A start with no lane still names an owner, so a row in flight is never ownerless.
axi start n8-b >/dev/null || fail "start with no lane"
[ "$(field n8-b .assignee)" = juggernaut ] || fail "a start with no lane must name the default actor"
BEADS_ACTOR=fixture axi start n8-c >/dev/null || fail "start from a named actor"
[ "$(field n8-c .assignee)" = fixture ] || fail "a start must name the caller's actor"
out=$(axi start n8-a) || fail "start of a row already in flight"
assert_contains "$out" "already in flight" "a second start must change nothing"
[ "$(field n8-a .assignee)" = s1.1.1 ] || fail "a start with no lane must leave another lane's row alone"
printf 'ok - every start names an owner\n'

# A hold keeps the assignee, writes no hold_from, and the row stays in flight; a release returns it to its owner.
axi hold n8-a --reason "wait in flight" --kind parked >/dev/null || fail "hold an in-flight row"
[ "$(field n8-a .status)" = on_hold ] || fail "the row must be held"
[ "$(field n8-a .assignee)" = s1.1.1 ] || fail "a hold must keep the lane"
[ "$(field n8-a '.metadata.hold_from // "none"')" = none ] || fail "a hold must write no hold_from"
[ "$(state_of n8-a)" = in_flight ] || fail "a held lane must read in flight, got [$(state_of n8-a)]"
axi unhold n8-a >/dev/null || fail "release the hold"
[ "$(field n8-a .status)" = in_progress ] || fail "a release must return the row to in flight"
[ "$(field n8-a .assignee)" = s1.1.1 ] || fail "a release must keep the lane"
printf 'ok - a held lane stays in flight on its assignee alone\n'

# A queued row held has no owner and reads queued; a release opens it.
axi hold n8-d --reason "wait queued" >/dev/null || fail "hold a queued row"
[ -z "$(field n8-d '.assignee // empty')" ] || fail "a hold must not give a queued row an owner"
[ "$(state_of n8-d)" = queued ] || fail "a held queued row must read queued, got [$(state_of n8-d)]"
axi unhold n8-d >/dev/null || fail "release a queued hold"
[ "$(field n8-d .status)" = open ] || fail "a release must reopen a queued row"
printf 'ok - a held queued row stays queued\n'

# A row put in flight outside the backlog has no owner, so a hold gives it the actor rather than lose its flight.
axi add n8-g "[feature] Legacy flight" --priority 2 --body why >/dev/null || fail "seed a legacy row"
bd update n8-g --status in_progress >/dev/null 2>&1 || fail "put a legacy row in flight"
axi hold n8-g --reason "wait legacy" >/dev/null || fail "hold a legacy row"
[ "$(field n8-g .assignee)" = juggernaut ] || fail "a hold of an ownerless flight must name the actor"
[ "$(state_of n8-g)" = in_flight ] || fail "a held legacy flight must read in flight"
axi unhold n8-g >/dev/null || fail "release the legacy hold"
[ "$(field n8-g .status)" = in_progress ] || fail "a release must keep the legacy flight"

# hold_from no longer means anything: a held row with it and no owner reads queued.
axi add n8-h "[feature] Old marker" --priority 2 --body why >/dev/null || fail "seed a marker row"
bd update n8-h --status on_hold --set-metadata hold_reason=old --set-metadata hold_from=in_progress >/dev/null 2>&1 || fail "hold the marker row"
[ "$(state_of n8-h)" = queued ] || fail "hold_from must not keep a row in flight, got [$(state_of n8-h)]"
printf 'ok - hold_from is not read\n'

# No code reads or writes hold_from, and the store itself is as init left it.
if grep -rn hold_from "$ROOT/bin" "$ROOT/core" >/dev/null 2>&1; then fail "a script still names hold_from"; fi
[ "$(shape)" = "$before" ] || fail "the store shape changed: $(diff <(printf '%s\n' "$before") <(shape))"
bd check >/dev/null || fail "the store must still pass check"
printf 'ok - no table, column, trigger or CHECK was added\n'
pass "jg-beads native n8"
