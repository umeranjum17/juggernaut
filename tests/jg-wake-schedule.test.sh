#!/usr/bin/env bash
# The wake schedule: a supervisor is woken at once only for what needs a person, and everything
# else rides one digest at most every `set digest-minutes`. Four journeys, each on a fixture home
# with no config/wake-routing of its own, so the shipped defaults/wake-routing is what is proved:
#
#   routine     a routine item raises no wake, waits in the queue, and arrives in the next digest;
#               the digest is sent at most once per window and never when nothing waits.
#   heartbeat   in away mode a heartbeat over an unchanged fleet raises no wake; a changed fleet does.
#   done-key    a done carrying a key closes that key's wait (proved by tests/jg-wake-batching.test.sh,
#               which the journey runs beside this file, so a key never re-pings after its done).
#   immediate   a captain answer, a red gate, a host alarm, a stuck worker and a finished deliverable
#               still wake at once, even when the digest is due.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(jg_test_tmproot jg-wake-schedule)
export TMP_ROOT
WATCH="$ROOT/bin/jg-watch.sh"
DRAIN="$ROOT/bin/jg-wake-drain.sh"

assert_unmodified_home() {  # <home>
  [ ! -e "$1/config/wake-routing" ] || fail "the fixture home carries a wake-routing override: $1"
}

# core <dir> <command...>: the production wake core, told this fixture home.
core() {  # <dir> <command...>
  local dir=$1; shift
  JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" JG_CONFIG_OVERRIDE="$dir/config" \
    bash -c '. "$1/bin/jg-wake-lib.sh"; shift; jg_wake_core "$@"' _ "$ROOT" "$@"
}

route() { core "$1" route "$2" "$3" "$4"; }  # <dir> <kind> <key> <payload>

# append <dir> <kind> <key> <payload>: the production appender, which prints the class it chose.
append() {
  JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/bin/jg-wake-lib.sh"; jg_wake_append "$2" "$3" "$4"; printf "%s\n" "$JG_WAKE_LAST"' _ "$ROOT" "$2" "$3" "$4"
}

# cycle <dir> [VAR=value...]: one real watcher cycle, then drain and acknowledge it the way a
# Stop-owned arm runs the cycle. A wake ends the cycle and lands in <dir>/events.
cycle() {
  local dir=$1 rc=0 seq gen pid; shift
  env HOME="$dir/home" XDG_CONFIG_HOME="$dir/home/config" TMPDIR="$dir/tmp" \
    PATH="$dir/fakebin:$PATH" JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" \
    JG_CONFIG_OVERRIDE="$dir/config" JG_POLL=0.2 JG_SIGNAL_GRACE=0 \
    JG_FAKE_TMUX_WINDOWS="$(printf 'fake:1\nfake:2')" \
    JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS=99999999 JG_BUSY_TURN_MAX_SECS=999999 \
    JG_STALE_ESCALATE_SECS=999999 JG_WAIT_ALERT_SECS=900000 JG_WAIT_ESCALATE_SECS=900001 \
    JG_WAIT_CARD_SECS=999999 JG_SQUAD_LEAD_WAKE_STALL_SECS=1 JG_WATCH_HANDLING_SUCCESSOR=1 "$@" \
    "$WATCH" > "$dir/out" 2> "$dir/err" &
  pid=$!
  wait_for_exit "$pid" 40 || rc=$?
  case "$rc" in 0|124) ;; *) fail "watcher failed: $(cat "$dir/err")" ;; esac
  cat "$dir/out" >> "$dir/events"
  # Only a woken turn drains and acknowledges; a quiet cycle leaves the queue for the next one.
  [ -s "$dir/out" ] || return 0
  JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$dir/drain" 2> "$dir/ack"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$dir/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$dir/ack")
  [ -z "$seq" ] || JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" "$DRAIN" \
    --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}

new_home() {  # <name>
  local dir; dir=$(make_case "$1")
  mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
  assert_unmodified_home "$dir"
  printf '%s\n' "$dir"
}

# --- 1. a routine item raises no wake and appears in the next digest -----------
test_routine_rides_the_digest() {
  local dir out now
  dir=$(new_home routine)
  now=$(date +%s)
  : > "$dir/events"

  out=$(append "$dir" check ready-work "check: ready work waiting with free lane slots (0/4 open): alpha-one")
  assert_equals "batch:ready-work" "$out" "a routine ready-work item must be routed batch"

  # The first routine row opens the window: no digest yet, and a real cycle raises no wake.
  core "$dir" digest mark >/dev/null && fail "a digest was sent the moment one routine item arrived"
  cycle "$dir"
  [ ! -s "$dir/events" ] || fail "a routine item woke the supervisor: $(cat "$dir/events")"
  [ -e "$dir/state/.wake-digest-at" ] || fail "the first routine item did not open a digest window"

  # Thirty-one minutes later the digest is due; a real cycle delivers one wake naming the count,
  # and the drain the next turn runs still presents the routine item itself.
  printf '%s\n' "$((now - 1860))" > "$dir/state/.wake-digest-at"
  core "$dir" digest | grep -qx 1 || fail "the digest was not due after the window"
  cycle "$dir"
  grep -q 'digest - 1 routine' "$dir/events" || fail "the due digest never woke: $(cat "$dir/events")"
  grep -q 'ready-work' "$dir/drain" || fail "the digest turn's drain did not present the routine item"

  # At most one digest per window.
  : > "$dir/events"
  append "$dir" check ready-work "check: ready work waiting with free lane slots (0/4 open): beta-two" >/dev/null
  cycle "$dir"
  core "$dir" digest mark >/dev/null && fail "a second digest was sent inside the window"
  [ ! -s "$dir/events" ] || fail "a second wake came inside the digest window: $(cat "$dir/events")"

  # Silence when nothing changed: with the queue acknowledged empty there is no digest at all.
  printf '%s\n' "$((now - 3600))" > "$dir/state/.wake-digest-at"
  cycle "$dir"
  : > "$dir/events"
  cycle "$dir"
  core "$dir" digest mark >/dev/null && fail "an empty digest was sent"
  [ ! -s "$dir/events" ] || fail "a wake came with nothing queued: $(cat "$dir/events")"
  pass "a routine item raises no wake, waits for the digest, and an empty digest is never sent"
}

# --- 2. an unchanged fleet raises no heartbeat ---------------------------------
test_unchanged_fleet_no_heartbeat() {
  local dir old
  dir=$(new_home heartbeat)
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$dir/state/lane.meta"
  printf 'working [at=%s]: building the writer\n' "$(date +%s)" > "$dir/state/lane.status"
  prime_status_seen "$dir/state" "$dir/state/lane.status"
  : > "$dir/state/.afk"
  old=$(( $(date +%s) - 7200 ))

  # No fingerprint yet: the first heartbeat is never hidden.
  [ "$(route "$dir" heartbeat heartbeat heartbeat)" = now ] || fail "the first heartbeat was hidden"
  core "$dir" fleet-fp-record
  [ "$(route "$dir" heartbeat heartbeat heartbeat)" = silent ] \
    || fail "a heartbeat over an unchanged fleet must be silent"

  : > "$dir/events"
  touch -d "@$old" "$dir/state/.last-heartbeat"
  cycle "$dir" JG_HEARTBEAT=1 JG_HEARTBEAT_MAX=1
  ! grep -q 'heartbeat' "$dir/events" || fail "an unchanged fleet raised a heartbeat: $(cat "$dir/events")"

  # A new status line is a real change: the next heartbeat wakes.
  printf 'working [at=%s]: wrote the reader\n' "$(date +%s)" >> "$dir/state/lane.status"
  prime_status_seen "$dir/state" "$dir/state/lane.status"
  [ "$(route "$dir" heartbeat heartbeat heartbeat)" = now ] || fail "a changed fleet must wake its heartbeat"
  rm -f "$dir/state/.heartbeat-streak"
  touch -d "@$old" "$dir/state/.last-heartbeat"
  cycle "$dir" JG_HEARTBEAT=1 JG_HEARTBEAT_MAX=1
  grep -q 'heartbeat' "$dir/events" || fail "a changed fleet raised no heartbeat: $(cat "$dir/events")"
  [ "$(route "$dir" heartbeat heartbeat heartbeat)" = silent ] \
    || fail "the heartbeat that woke did not record the fleet it saw"
  pass "an unchanged fleet raises no heartbeat and a changed one does"
}

# --- 3. a captain answer, a red gate, a host alarm, a stuck worker still wake ---
test_urgent_stays_now() {
  local dir
  dir=$(new_home urgent)
  printf 'blocked [at=%s] [key=ask]: waiting on the captain\n' "$(date +%s)" > "$dir/state/lane.status"
  printf 'done [at=%s]: PR https://example.test/pr/1\n' "$(date +%s)" > "$dir/state/ship.status"
  printf 'needs-decision [at=%s]: pick one\n' "$(date +%s)" > "$dir/state/dec.status"
  printf 'ready [at=%s]: PR https://example.test/pr/2\n' "$(date +%s)" > "$dir/state/rdy.status"
  assert_equals now "$(route "$dir" check 'inbox:7' 'check: captain inbox note 7 - yes, merge it')" "a captain answer must wake"
  assert_equals now "$(route "$dir" check ci.check.sh 'check: ci.check.sh: PR 12 checks failed')" "a red gate must wake"
  assert_equals now "$(route "$dir" check host-memory 'check: host memory ALERT: 91 percent')" "a host alarm must wake"
  assert_equals now "$(route "$dir" check delete-guard 'check: delete guard blocked a command')" "a host alarm must wake"
  assert_equals now "$(route "$dir" stale crew:w1 'stale: crew:w1 (no output for 20 minutes)')" "a stuck worker must wake"
  assert_equals now "$(route "$dir" signal dec.status 'signal: dec.status')" "a decision must wake"
  assert_equals now "$(route "$dir" signal ship.status 'signal: ship.status')" "a finished deliverable must wake"
  assert_equals now "$(route "$dir" signal rdy.status 'signal: rdy.status')" "a ready deliverable must wake"
  assert_equals now "$(route "$dir" signal lane.status 'signal: lane.status')" "a blocked line must wake"

  # Even with the digest due, a captain answer wakes on its own cycle and is not folded into it.
  rm -f "$dir"/state/*.status
  printf '%s\n' "$(( $(date +%s) - 7200 ))" > "$dir/state/.wake-digest-at"
  : > "$dir/events"
  append "$dir" check 'inbox:9' 'check: captain inbox note 9 - answer' >/dev/null
  cycle "$dir"
  grep -q 'inbox:9\|captain inbox note 9' "$dir/events" || fail "a captain answer did not wake at once: $(cat "$dir/events")"
  pass "a captain answer, a red gate, a host alarm, a stuck worker and a finished deliverable wake at once"
}

test_routine_rides_the_digest
test_unchanged_fleet_no_heartbeat
test_urgent_stays_now
echo "wake schedule: routine rides the digest, an unchanged fleet is silent, urgent still wakes"
