#!/usr/bin/env bash
# The wake urgency rules give a routine event a `batch` class: its durable row is
# recorded and its wake does not end the watcher cycle, so the tickets checks
# never cost a turn of their own. An unlisted event, and any event the rules do
# not name, still wakes at once.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

state=$(jg_test_tmproot jg-wake-route)/state
mkdir -p "$state"
export JG_HOME="${state%/state}" JG_STATE_OVERRIDE="$state"

route_class() {  # <kind> <key> <payload>
  JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/jg-wake-lib.sh"
    jg_wake_route_class "$2" "$3" "$4"
  ' _ "$ROOT" "$1" "$2" "$3"
}

# 1. The rule file names the tickets checks, and nothing else on this branch.
assert_equals batch "$(route_class check 'state/tickets-stale.check.sh' 'tickets-check: a row says queued')" \
  'the tickets check must be classified batch'
assert_equals batch "$(route_class check 'state/tickets-sync.check.sh' 'tickets-sync: 1 homes read; 2 tickets changed')" \
  'the tickets poll summary must be classified batch'
assert_equals now "$(route_class check 'state/some-other.check.sh' 'check: something to act on')" \
  'an unlisted check must still wake at once'
assert_equals now "$(route_class signal 'task.status' 'done [at=1]: PR https://example.test/pull/1')" \
  'a finished task must still wake at once'
assert_equals now "$(route_class check 'state/tickets-stale.check.sh' 'needs-decision: pick one')" \
  'a decision line keeps its wake even from a batched check'
pass 'the rules give the tickets checks batch and leave everything else now'

# 2. The recorded row is durable either way; only the wake differs.
JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$state" bash -c '
  . "$1/bin/jg-wake-lib.sh"
  jg_wake_append check "state/tickets-stale.check.sh" "tickets-check: 206 rows no home accounts for"
  printf "%s\n" "$JG_WAKE_LAST"
' _ "$ROOT" > "$state/last"
assert_equals 'batch:state/tickets-stale.check.sh' "$(cat "$state/last")" 'the append must hand the batch verdict on'
assert_contains "$(cat "$state/.wake-queue")" 'tickets-check: 206 rows' 'a batch event must still be a durable row'
pass 'a batch event is recorded as an ordinary durable row'

# 3. The cycle gate: a batch reason returns to the cycle, an urgent one wakes.
out=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$state" bash -c '
  . "$1/bin/jg-push-transition-lib.sh"
  JG_WAKE_LAST="batch:state/tickets-stale.check.sh"
  wake "check: state/tickets-stale.check.sh: tickets-check: 206 rows no home accounts for"
  echo continued
' _ "$ROOT" 2>&1)
assert_equals continued "$out" 'a batch reason must not end the watcher cycle'
out=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$state" bash -c '
  . "$1/bin/jg-push-transition-lib.sh"
  JG_WAKE_LAST="now:state/some-other.check.sh"
  wake "check: state/some-other.check.sh: something to act on"
  echo continued
' _ "$ROOT" 2>&1)
assert_not_contains "$out" continued 'an urgent reason must end the watcher cycle'
assert_contains "$out" 'something to act on' 'an urgent reason must still be delivered'
# An urgent row from the same cycle keeps its wake: the latch beats a batch verdict.
out=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$state" bash -c '
  . "$1/bin/jg-push-transition-lib.sh"
  JG_WAKE_LAST="batch:state/tickets-stale.check.sh"
  JG_WAKE_CYCLE_URGENT=1
  wake "check: state/tickets-stale.check.sh: tickets-check: 206 rows no home accounts for"
  echo continued
' _ "$ROOT" 2>&1)
assert_not_contains "$out" continued 'an urgent row must not be silenced by a batch one'
pass 'a batch reason leaves the cycle and an urgent one ends it'

# 4. A home rule overrides the shipped one, so a captain can hold or release a class.
mkdir -p "$JG_HOME/config"
printf 'now check *tickets-stale.check.sh *\nnow * * *\n' > "$JG_HOME/config/wake-routing"
assert_equals now "$(route_class check 'state/tickets-stale.check.sh' 'tickets-check: x')" \
  'a home rule must override the shipped batch rule'
rm -f "$JG_HOME/config/wake-routing"
pass 'a home routing file overrides the shipped rules'
