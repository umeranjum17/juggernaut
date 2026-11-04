#!/usr/bin/env bash
# Integration: one machine-wide host memory ALERT wakes Main alone.
# Runs the real sampler tick against the real guard and a fixture /proc whose memory is
# below the alert floor, in three homes, and reads the wake queue and tally each leaves:
#   1. a Squad Lead home under a local root records the alert (interrupt log row, settled
#      tally, episode latch) and queues no wake, so its model takes no turn;
#   2. the root Overwatch home queues the wake as before;
#   3. a home with no parent record (a missing role record) queues the wake as before.
# Usage: bash host-memory/tests/jg-host-memory-alert-routing.test.sh   exit 0 = PASS.
set -u

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../../../tests/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-host-memory-alert-routing)
SAMPLER="$ROOT/core/host-memory/bin/jg-host-memory-sampler.sh"

# tick <home> <state>: one sampler tick for that home, as the sampler's run loop would drive it.
tick() {
  local home=$1 state=$2
  JG_HOME="$home" JG_STATE_OVERRIDE="$state" JG_CONFIG_OVERRIDE="$home/config" \
    JG_HOST_MEMORY_PROC="$TMP_ROOT/proc" JG_HOST_MEMORY_CGROUP_ROOT="$TMP_ROOT/no-cgroup" \
    bash -c '
      SAMPLER_DIR=$1/bin STATE=$JG_STATE_OVERRIDE CONFIG=$JG_CONFIG_OVERRIDE
      . "$SAMPLER_DIR/jg-wake-lib.sh"
      . "$SAMPLER_DIR/jg-backend.sh"
      . "$2"
      jg_memory_sampler_tick' _ "$ROOT" "$SAMPLER"
}

mkdir -p "$TMP_ROOT/proc/pressure"
printf 'MemAvailable: 100000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$TMP_ROOT/proc/meminfo"
printf 'some avg10=0 avg60=0 avg300=0 total=0\n' > "$TMP_ROOT/proc/pressure/memory"

new_home() { # <name>: an empty home with a state directory
  mkdir -p "$TMP_ROOT/$1/state" "$TMP_ROOT/$1/config"
  printf '%s\n' "$TMP_ROOT/$1"
}

assert_alert_recorded() { # <state> <label>: the alert is in the durable interrupt log and the latch is set
  assert_grep 'host memory ALERT' "$1/host-memory-interrupts.tsv" "$2: the alert must reach the interrupt log"
  [ -s "$1/.host-memory-alerted" ] || fail "$2: the episode latch was not set"
}

test_lead_records_without_waking() (
  main=$(new_home lead-main)
  lead=$(new_home lead-alpha)
  printf 'alpha\n' > "$lead/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$main" > "$lead/.jg-squad-lead-parent"
  tick "$lead" "$lead/state" || fail "the lead tick failed"
  assert_alert_recorded "$lead/state" "Squad Lead home"
  [ ! -s "$lead/state/.wake-queue" ] || fail "a Squad Lead home queued a wake: $(<"$lead/state/.wake-queue")"
  assert_grep 'host-memory' "$lead/state/.wake-settled" "a Squad Lead home must tally the alert as settled"
  pass "a Squad Lead home records the host memory alert and queues no wake"
)

test_primary_wakes() (
  main=$(new_home primary-main)
  tick "$main" "$main/state" || fail "the primary tick failed"
  assert_alert_recorded "$main/state" "primary home"
  assert_grep 'host memory ALERT' "$main/state/.wake-queue" "the primary home must queue the alert wake"
  pass "the primary home queues the host memory alert wake"
)

test_missing_role_record_wakes() (
  home=$(new_home no-role)
  # A lead marker with no parent record names no root above it, so the home wakes as it always did.
  printf 'orphan\n' > "$home/.jg-squad-lead-home"
  tick "$home" "$home/state" || fail "the no-role tick failed"
  assert_alert_recorded "$home/state" "home with no parent record"
  assert_grep 'host memory ALERT' "$home/state/.wake-queue" "a home with no parent record must queue the alert wake"
  pass "a home with a missing role record still queues the host memory alert wake"
)

test_lead_records_without_waking || exit 1
test_primary_wakes || exit 1
test_missing_role_record_wakes || exit 1
echo 'PASS host memory alert wakes Main alone'
