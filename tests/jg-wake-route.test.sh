#!/usr/bin/env bash
# Wake urgency routing (docs/watcher-continuity.md "Wake urgency classes"): the rule file
# assigns now, batch, or silent; a batched row cannot end the watcher cycle; and an urgent
# row from the same event still latches it.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-wake-route)

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
  assert_equals "$(route "$home" "$state" check "$state/board-gate.check.sh" \
    "check: $state/board-gate.check.sh: board ask routed to Overwatch, not a must: ask-mac-screen-grant - Allow screen recording? (record owd-1)")" batch \
    "a board ask without a must category must land in a digest, not wake a model"
  assert_equals "$(route "$home" "$state" check "$state/board-gate.check.sh" \
    "check: $state/board-gate.check.sh: merge landed with no board Evidence card: m1 https://example.test/o/r/pull/7")" now \
    "a merge with no board proof must still wake at once"
  assert_equals "$(route "$home" "$state" check "$state/tickets-stale.check.sh" \
    'tickets-stale: jg-1 says queued')" batch \
    "a staled tickets row is bookkeeping, not a decision"
  assert_equals "$(route "$home" "$state" check "$state/tickets-sync.check.sh" \
    'tickets-sync: 1 homes read; 2 tickets changed')" batch \
    "a tickets poll summary must not wake a model"
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

test_no_model_wakes() (
  dir=$(make_case route-nomodel)
  state="$dir/state"
  mkdir -p "$dir/config" "$dir/homes/alpha" "$dir/homes/beta"
  printf 'alpha\n' > "$dir/homes/alpha/.jg-squad-lead-home"
  printf 'beta\n' > "$dir/homes/beta/.jg-squad-lead-home"
  printf 'kind=squad_lead\nhome=%s\n' "$dir/homes/alpha" > "$state/alpha.meta"
  printf 'kind=squad_lead\nhome=%s\n' "$dir/homes/beta" > "$state/beta.meta"
  printf 'alpha\n' > "$dir/config/parked-homes"
  cp "$ROOT/defaults/wake-routing" "$dir/config/wake-routing"
  printf 'paused [at=1]: ack\n' > "$state/alpha.status"
  printf 'paused [at=1]: ack\n' > "$state/beta.status"
  assert_equals "$(route "$dir" "$state" signal alpha.status x)" silent "a paused home's pause acknowledgement is settled"
  assert_equals "$(route "$dir" "$state" signal beta.status x)" now "a live home's pause still wakes"
  assert_equals "$(route "$dir" "$state" check alpha-wait-owner 'check: waiting-state alpha (x)')" silent "a timer on a paused home is settled"
  assert_equals "$(route "$dir" "$state" check beta-wait-owner 'check: waiting-state beta (x)')" now "a timer on a live home still wakes"
  relaunch='check: squad_lead beta auto-relaunched after dead (pane)'
  assert_equals "$(route "$dir" "$state" check squad-lead-relaunch-beta-9 "$relaunch")" now "a relaunch nobody asked for still wakes"
  printf '%s\tbeta\n' "$(date +%s)" > "$state/.squad-lead-restart-pass"
  assert_equals "$(route "$dir" "$state" check squad-lead-relaunch-beta-9 "$relaunch")" silent "a relaunch the restart pass caused is settled"
  printf '%s\tbeta\n' "$(( $(date +%s) - 9999 ))" > "$state/.squad-lead-restart-pass"
  assert_equals "$(route "$dir" "$state" check squad-lead-relaunch-beta-9 "$relaunch")" now "an old restart pass explains nothing"
  assert_equals "$(route "$dir" "$state" check rearm-resurface 'check: rearm-resurface')" silent "a re-arm with nothing queued is settled"
  append_wake "$state" signal beta.status 'signal: x'
  assert_equals "$(route "$dir" "$state" check rearm-resurface 'check: rearm-resurface')" now "a re-arm with an urgent row queued still wakes"
  printf 'set silence-cap-per-hour 2\nsilent signal *.status paused*\nnow * * *\n' > "$dir/cap.routing"
  for i in 1 2 3; do printf 'paused [at=1]: x\n' > "$state/a$i.status"; JG_WAKE_ROUTING="$dir/cap.routing" JG_HOME="$dir" append_wake "$state" signal "a$i.status" 'signal: x'; done
  assert_equals "$(wc -l < "$state/.wake-silenced" | tr -d ' ')" 2 "the per-hour cap counts settled wakes"
  pass "pause acks, relaunch notices, re-arms and timers on paused homes settle; a cap bounds them"
)

result=0
test_classes || result=1
test_no_model_wakes || result=1
test_silent_is_recorded_not_queued || result=1
test_batch_is_gated_and_urgent_latches || result=1
exit "$result"
