#!/usr/bin/env bash
# Integration: one machine-wide host memory ALERT wakes Main alone.
# Runs the real sampler tick against the real guard and a fixture /proc whose memory is
# below the alert floor, in three homes, and reads the wake queue and tally each leaves:
#   1. a Squad Lead home under a local root records the alert (interrupt log row, settled
#      tally, episode latch) and queues no wake, so its model takes no turn;
#   2. the root Overwatch home queues the wake as before;
#   3. a home with no parent record (a missing role record) queues the wake as before;
#   4. the root's alert names a task working in a local Squad Lead's home, which the guard
#      finds by walking the lead's records itself, and never interrupts it.
# Usage: bash host-memory/tests/jg-host-memory-alert-routing.test.sh   exit 0 = PASS.
set -u

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../../../tests/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-host-memory-alert-routing)
SAMPLER="$ROOT/core/host-memory/bin/jg-host-memory-sampler.sh"

# tick <home> <state> [<proc root>]: one sampler tick for that home, as the sampler's run loop would drive it.
tick() {
  local home=$1 state=$2 proc=${3:-$TMP_ROOT/proc}
  JG_HOME="$home" JG_STATE_OVERRIDE="$state" JG_CONFIG_OVERRIDE="$home/config" \
    JG_HOST_MEMORY_PROC="$proc" JG_HOST_MEMORY_CGROUP_ROOT="$TMP_ROOT/no-cgroup" \
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

test_alert_names_task_in_lead_home() (
  # The root records one local Squad Lead, whose home records a task; a fixture process working in
  # that task's worktree is the largest consumer. The tick passes the root alone, so the alert
  # names the task only if the guard walks the lead's home itself.
  main=$(new_home tree-main)
  lead=$(new_home tree-alpha)
  mkdir -p "$TMP_ROOT/tree-worktree"
  printf 'kind=squad_lead\nhome=%s\n' "$lead" > "$main/state/alpha.meta"
  printf 'kind=ship\nworktree=%s\n' "$TMP_ROOT/tree-worktree" > "$lead/state/umer-fix.meta"
  mkdir -p "$TMP_ROOT/tree-proc/pressure" "$TMP_ROOT/tree-proc/4242"
  cp "$TMP_ROOT/proc/meminfo" "$TMP_ROOT/tree-proc/meminfo"
  cp "$TMP_ROOT/proc/pressure/memory" "$TMP_ROOT/tree-proc/pressure/memory"
  printf 'Name:\tpython3\nVmRSS:\t900000 kB\n' > "$TMP_ROOT/tree-proc/4242/status"
  : > "$TMP_ROOT/tree-proc/4242/environ"
  ln -s "$TMP_ROOT/tree-worktree" "$TMP_ROOT/tree-proc/4242/cwd"
  tick "$main" "$main/state" "$TMP_ROOT/tree-proc" || fail "the root tick failed"
  assert_grep 'largest: task umer-fix (alpha) 0.9 GB' "$main/state/host-memory-interrupts.tsv" \
    "the alert must name the task working in the Squad Lead's home"
  assert_grep 'top consumer is not a task this home owns' "$main/state/host-memory-interrupts.tsv" \
    "a task in another home must never be interrupted by the root"
  pass "the alert names a task in a local Squad Lead's home and leaves it to that home"
)

test_lead_records_without_waking || exit 1
test_primary_wakes || exit 1
test_missing_role_record_wakes || exit 1
test_alert_names_task_in_lead_home || exit 1
echo 'PASS host memory alert wakes Main alone'
