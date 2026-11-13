#!/usr/bin/env bash
# Wake batching is honoured in the core, on a home that carries no override of its own.
#
# Three misroutes cost Main a turn for an event the routing rules already class
# `batch`, and each is proven here on the shipped `defaults/wake-routing` with no
# `config/wake-routing` in the fixture home:
#
#   lead-lines  A squad_lead's status log is a relay channel for its child work
#               (bin/jg-branch-prompt.sh), so its `done` lines report a child's
#               outcome. bin/jg-wake-lib.sh's jg_wake_route_class read the shipped
#               rules and the first match for a routine `done [key=child-...]` line
#               was `now * * * done*`, so every routine lead report woke Main.
#   resurface   bin/jg-watch.sh's own_queue_resurface re-delivered the oldest
#               unsettled row whatever its class; a Stop-owned arm turns that print
#               into a model wake, so a `batch` row woke through the stop hook.
#               resurface_after_downtime already asks the class before it wakes, and
#               this case pins the same rule on the other arm path.
#   done-key    The decision fold (core/classify, one owner) closed a keyed `done`
#               only on a ship or scout lane; on a squad_lead lane the answered
#               decision stayed open, so its wait-timer episode kept its source and
#               the escalation ladder kept climbing.
#
# This is also the test that owns the wake-batching journey of .done-done.yaml (the done-done journey
# runs this file), so the changed-test map selects it for a change to that journey.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(jg_test_tmproot jg-wake-batching)
WATCH="$ROOT/bin/jg-watch.sh"
DRAIN="$ROOT/bin/jg-wake-drain.sh"
TAB=$(printf '\t')

# The shipped rule file answers, never a home override: every case below asserts
# this first, so a fixture that quietly grew a config override cannot pass.
assert_unmodified_home() {  # <home>
  [ ! -e "$1/config/wake-routing" ] \
    || fail "the fixture home carries a wake-routing override, so it cannot prove the core: $1"
}

# route <home> <kind> <key> <payload>: the class the production rule owner gives it.
# shellcheck disable=SC2016 # the single-quoted body expands only inside the called bash
route() {  # <home> <kind> <key> <payload>
  env -u JG_WAKE_ROUTING JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/bin/jg-wake-lib.sh"; jg_wake_route_class "$2" "$3" "$4"' _ "$ROOT" "$2" "$3" "$4"
}

# --- 1. a routine lead line rides the digest ----------------------------------
test_lead_lines_batch() {
  local dir lead status now
  dir="$TMP_ROOT/lead-lines"
  mkdir -p "$dir/state" "$dir/config"
  assert_unmodified_home "$dir"
  lead="$dir/state/lead.status"
  status="$dir/state/lead.meta"
  printf 'kind=squad_lead\nbackend=tmux\nwindow=fake:9\n' > "$status"
  now=$(date +%s)

  # Exactly the lines the parent-channel libraries write (bin/jg-pr-check.sh,
  # bin/jg-inactive-reconcile.sh, bin/jg-merge-outcome-lib.sh), stamped by
  # bin/jg-parent-channel-lib.sh.
  printf 'done [at=%s] [key=child-pr-11]: child 11 PR ready: https://example.test/o/r/pull/11\n' "$now" > "$lead"
  assert_equals batch "$(route "$dir" signal lead.status 'signal: x')" \
    "a lead's PR-ready child report must ride the digest, not wake Main"
  printf 'done [at=%s] [key=child-outcome-11-done-abcd1234]: child 11 done: refactored the writer pr=https://example.test/o/r/pull/11 mode=direct-PR\n' "$now" > "$lead"
  assert_equals batch "$(route "$dir" signal lead.status 'signal: x')" \
    "a lead's ledger copy of a child outcome must ride the digest"
  printf 'done [at=%s] [key=merged-11]: merged 11 https://example.test/o/r/pull/11\n' "$now" > "$lead"
  assert_equals batch "$(route "$dir" signal lead.status 'signal: x')" \
    "a lead's merge notice must ride the digest"
  printf 'working [at=%s]: stepping through the third shard\n' "$now" > "$lead"
  assert_equals batch "$(route "$dir" signal lead.status 'signal: x')" \
    "a lead's progress line must ride the digest"

  # A captain decision on the same lane still wakes at once.
  printf 'needs-decision [at=%s]: pick the release branch\n' "$now" > "$lead"
  assert_equals now "$(route "$dir" signal lead.status 'signal: x')" \
    "a captain decision must never be batched"
  pass "a lead's routine status lines ride the digest, a decision still wakes"
}

# --- 2. a batch row does not wake through the stop-owned arm ------------------
# cycle <dir>: one real watcher cycle, then drain and acknowledge it, the way a
# Stop-owned arm runs the cycle. A wake ends the cycle and lands in the output.
# A cycle that delivers nothing would run out its whole poll budget (0.1 s a poll). A cycle that only has to arm
# a wait names that wait's record as <ready>, and is ended as soon as the record exists instead of at the budget.
cycle() {  # <dir> [escalate] [alert] [ready record]
  local dir=$1 escalate=${2:-900001} alert=${3:-900000} ready=${4:-} polls=40 rc=0 seq gen pid i=0
  local fake_windows
  fake_windows=$(printf 'fake:1\nfake:2')
  env HOME="$dir/home" XDG_CONFIG_HOME="$dir/home/config" TMPDIR="$dir/tmp" \
    PATH="$dir/fakebin:$PATH" JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" \
    JG_CONFIG_OVERRIDE="$dir/config" JG_POLL=0.2 JG_SIGNAL_GRACE=0 \
    JG_FAKE_TMUX_WINDOWS="$fake_windows" \
    JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS=99999999 JG_BUSY_TURN_MAX_SECS=999999 \
    JG_STALE_ESCALATE_SECS=999999 JG_WAIT_ALERT_SECS="$alert" \
    JG_WAIT_ESCALATE_SECS="$escalate" JG_WAIT_CARD_SECS=999999 \
    JG_SQUAD_LEAD_WAKE_STALL_SECS=1 JG_WATCH_HANDLING_SUCCESSOR=1 \
    "$WATCH" > "$dir/out" 2> "$dir/err" &
  pid=$!
  if [ -n "$ready" ]; then
    while [ "$i" -lt "$polls" ] && [ ! -e "$ready" ] && is_live_non_zombie "$pid"; do sleep 0.1; i=$((i + 1)); done
    [ ! -e "$ready" ] || polls=0
  fi
  wait_for_exit "$pid" "$polls" || rc=$?
  case "$rc" in 0|124) ;; *) fail "watcher failed: $(cat "$dir/err")" ;; esac
  cat "$dir/out" >> "$dir/events"
  JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$dir/drain" 2> "$dir/ack"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$dir/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$dir/ack")
  [ -z "$seq" ] || JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" "$DRAIN" \
    --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}

test_batch_row_does_not_wake() {
  local dir out
  dir=$(make_case batch-resurface)
  mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
  assert_unmodified_home "$dir"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$dir/state/lane.meta"
  printf 'working [at=%s]: building the writer\n' "$(date +%s)" > "$dir/state/lane.status"
  prime_status_seen "$dir/state" "$dir/state/lane.status"

  # The producer routes this row `batch` on the shipped rules.
  out=$(JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/bin/jg-wake-lib.sh"
    jg_wake_append signal lane.turn-ended "signal: $STATE/lane.turn-ended"
    printf "%s\n" "$JG_WAKE_LAST"' _ "$ROOT" 2>&1)
  assert_equals "batch:lane.turn-ended" "$out" "the turn-end row must be routed batch"
  "$dir/fakebin/tmux" >/dev/null 2>&1 || true

  # Wait past the resurface window, then run one cycle. A batch row must stay queued
  # rather than close the cycle; the drain that a real turn runs still presents it.
  sleep 1.2
  cycle "$dir"
  ! grep -q 'lane.turn-ended' "$dir/events" \
    || fail "a batch row woke the stop-owned cycle: $(cat "$dir/events")"
  grep -q 'lane.turn-ended' "$dir/drain" \
    || fail "the batch row was dropped instead of delivered by the next turn's drain"

  # A `now` row behind it still re-delivers: the class decides, not the row's age.
  printf 'blocked [at=%s] [key=stuck]: waiting on the writer\n' "$(date +%s)" >> "$dir/state/lane.status"
  JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/bin/jg-wake-lib.sh"; jg_wake_append signal lane.status "signal: $STATE/lane.status"' _ "$ROOT"
  sleep 1.2
  cycle "$dir"
  grep -q 'signal: .*lane\.status' "$dir/events" \
    || fail "a now row behind a batch row stopped re-delivering: $(cat "$dir/events")"
  pass "a batch row waits for a turn and a now row still re-delivers"
}

# --- 3. a done carrying a key clears that key's escalation --------------------
# due_episode <dir> <task>: make that lane's episode overdue without waiting, the
# same clock shortcut core/wait-timers/tests/jg-wait-timers.test.sh uses.
due_episode() {  # <dir> <task>
  local record=$1/state/.waiting-timers/$2 sig _since _owner _parent key _misses _card _last now
  now=$(date +%s)
  IFS=$TAB read -r sig _since _owner _parent key _misses _card _last < "$record" || return 1
  printf '%s\t%s\t%s\t0\t%s\t%s\t0\t0\n' \
    "$sig" "$((now - 900))" "$((now - 900))" "$key" "${_misses:-0}" > "$record"
}

test_done_closes_its_escalation() {
  local dir lane now
  dir=$(make_case done-key)
  mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
  assert_unmodified_home "$dir"
  now=$(date +%s)
  for lane in lead-a lead-b; do
    printf 'kind=squad_lead\nbackend=tmux\nwindow=fake:%s\n' "${lane#lead-}" > "$dir/state/$lane.meta"
  done
  printf 'blocked [at=%s] [key=answer-me]: waiting on the writer\n' "$now" > "$dir/state/lead-a.status"
  printf 'blocked [at=%s] [key=still-waiting]: waiting on CI\n' "$now" > "$dir/state/lead-b.status"
  for lane in lead-a lead-b; do prime_status_seen "$dir/state" "$dir/state/$lane.status"; done

  # Arm both episodes on quiet cycles: the tick ends the cycle on the first
  # escalation, so each lane arms on its own cycle.
  cycle "$dir" 900001 900000 "$dir/state/.waiting-timers/lead-a"
  cycle "$dir" 900001 900000 "$dir/state/.waiting-timers/lead-b"
  [ -e "$dir/state/.waiting-timers/lead-a" ] || fail "the first lane's wait never armed"
  [ -e "$dir/state/.waiting-timers/lead-b" ] || fail "the second lane's wait never armed"
  : > "$dir/events"

  # The first lane climbs to Main on the ladder's own rung.
  due_episode "$dir" lead-a
  cycle "$dir" 2 1
  grep -q 'answer-me' "$dir/events" || fail "the unanswered first wait never escalated"
  : > "$dir/events"

  # Its owner answers with a `done` carrying that exact key. That line is a wake of its
  # own, so one cycle delivers it and the next settles the episode; a real turn boundary
  # would do the same. Only then is the second lane's wait made overdue.
  printf 'done [at=%s] [key=answer-me]: the writer landed, nothing waits here\n' "$(date +%s)" \
    >> "$dir/state/lead-a.status"
  cycle "$dir"
  cycle "$dir"
  : > "$dir/events"
  # An answered wait that survived its own done is due again here; one the fold closed
  # has no record left to make due.
  [ ! -e "$dir/state/.waiting-timers/lead-a" ] || due_episode "$dir" lead-a
  due_episode "$dir" lead-b
  cycle "$dir" 2 1
  grep -q 'still-waiting' "$dir/events" || fail "the open second wait stopped climbing"
  ! grep -q 'answer-me' "$dir/events" \
    || fail "an answered decision kept climbing after its done: $(cat "$dir/events")"
  pass "a done carrying a key clears that key's escalation and leaves the other wait open"
}

test_lead_lines_batch
test_batch_row_does_not_wake
test_done_closes_its_escalation
echo "wake batching: all three misroutes are honored on an unmodified home"
