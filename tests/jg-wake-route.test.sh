#!/usr/bin/env bash
# Wake urgency routing (docs/watcher-continuity.md "Wake urgency classes"): the rule file
# assigns now, batch, or silent; a batched row cannot end the watcher cycle; and an urgent
# row from the same event still latches it.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-wake-route)

# route <home> <state> <kind> <key> <payload>: the class the rule file gives it.
route() {
  JG_HOME="$1" JG_STATE_OVERRIDE="$2" bash -c '
    . "$1/bin/jg-wake-lib.sh"; jg_wake_route_class "$2" "$3" "$4"' _ "$ROOT" "$3" "$4" "$5"
}

test_classes() {
  local home="$TMP_ROOT/classes" state="$TMP_ROOT/classes/state"
  mkdir -p "$state"
  assert_equals "$(route "$home" "$state" signal crew.turn-ended 'signal: x')" batch \
    "a turn-end must be batched, not woken on"
  assert_equals "$(route "$home" "$state" check startup 'check: MISSING')" now \
    "a startup failure must wake at once"
  printf 'working [at=1]: editing\n' > "$state/lane.status"
  printf 'needs-decision [at=2]: pick one\n' > "$state/pick.status"
  assert_equals "$(route "$home" "$state" signal pick.status "signal: x")" now \
    "a captain decision must wake at once"
  printf 'silent signal *.status working*\nnow * * *\n' > "$home.routing"
  assert_equals "$(JG_WAKE_ROUTING="$home.routing" route "$home" "$state" signal lane.status x)" \
    silent "a home rule must be able to record an event only"
  assert_equals "$(route "$home" "$state" signal lane.status "signal: x")" now \
    "a status line still wakes unless a home rule holds it"
  pass "the rule file assigns now, batch, and silent"
}

test_silent_is_recorded_not_queued() (
  dir=$(make_case route-silent)
  mkdir -p "$dir/config"
  printf 'silent signal *.status working*\nnow * * *\n' > "$dir/config/wake-routing"
  printf 'working [at=1]: editing\n' > "$dir/state/lane.status"
  JG_HOME="$dir" append_wake "$dir/state" signal lane.status "signal: x"
  [ ! -s "$dir/state/.wake-queue" ] || fail "a silent event reached the queue"
  assert_grep "lane.status" "$dir/state/.wake-settled" "a silent event must stay readable"
  pass "a home's silent rule records an event and never queues it"
)

test_batch_is_gated_and_urgent_latches() (
  dir=$(make_case route-gate)
  out=$(JG_STATE_OVERRIDE="$dir/state" bash -c '. "$1/bin/jg-wake-lib.sh"
    jg_wake_append signal crew.turn-ended "signal: crew.turn-ended"
    printf "batch=%s\n" "${JG_WAKE_LAST:-}"
    printf "done [at=2]: done: finished\n" > "$STATE/pick.status"
    jg_wake_append signal pick.status "signal: $STATE/pick.status"
    printf "urgent=%s\n" "${JG_WAKE_CYCLE_URGENT:-}"' _ "$ROOT" 2>&1)
  assert_contains "$out" "batch=batch:crew.turn-ended" "a batched row hands its class on"
  assert_contains "$out" "urgent=1" "an urgent row must latch the cycle"
  assert_contains "$(JG_STATE_OVERRIDE="$dir/state" bash -c '. "$1/bin/jg-push-transition-lib.sh"
    JG_WAKE_LAST=batch:crew.turn-ended
    wake "signal: crew.turn-ended" && echo gated' _ "$ROOT" 2>&1)" gated \
    "a batched row must not end the watcher cycle"
  pass "batch rows are gated and an urgent row latches the cycle"
)

result=0
test_classes || result=1
test_silent_is_recorded_not_queued || result=1
test_batch_is_gated_and_urgent_latches || result=1
exit "$result"
