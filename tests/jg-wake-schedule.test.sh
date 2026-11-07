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
#   planned     a pause that names its future event raises no wake and no re-ping, while a block
#               with no clearing condition still escalates.
#   misses      the four notices that cost a turn for nothing after c-5 (a gap just opened, the fleet-pulse
#               2h report, a relaunch that lost the race to another spawn during a restart pass, a
#               lead's supervision notice seconds after its own restart) raise no wake, and the same
#               notices still wake once the gap is long, the failure is not a restart pass, or the lead
#               stayed down past the grace window.
#   immediate   a captain answer, a red gate, a host alarm, a stuck worker and a finished deliverable
#               still wake at once, even when the digest is due.
# This is also the test that owns journeys/wake-schedule.sh and journeys/wake-batch-threshold.sh (the done-done journey runs this file),
# so the changed-test map selects it for a change to that journey.
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
  # A quiet cycle never exits on its own, so a case that expects silence is stopped at this short
  # window. A case that expects a wake uses cycle_wake, which waits for the watcher's own exit.
  wait_for_exit "$pid" "${CYCLE_POLLS:-40}" || rc=$?
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

# A woken watcher prints its wake and exits, so wait for that event itself rather than a fixed
# budget a slow host can miss. The long deadline only bounds a wake that never comes; it is
# reached only on failure, never on a pass.
cycle_wake() { CYCLE_POLLS=${CYCLE_WAKE_POLLS:-1500} cycle "$@"; }

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

  # Thirty-one minutes later (past the 15-minute delay) the digest is due; a real cycle delivers one wake naming the count,
  # and the drain the next turn runs still presents the routine item itself.
  printf '%s\n' "$((now - 1860))" > "$dir/state/.wake-digest-at"
  core "$dir" digest | grep -qx 1 || fail "the digest was not due after the window"
  cycle_wake "$dir"
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
  cycle_wake "$dir"
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
  cycle_wake "$dir" JG_HEARTBEAT=1 JG_HEARTBEAT_MAX=1
  grep -q 'heartbeat' "$dir/events" || fail "a changed fleet raised no heartbeat: $(cat "$dir/events")"
  [ "$(route "$dir" heartbeat heartbeat heartbeat)" = silent ] \
    || fail "the heartbeat that woke did not record the fleet it saw"

  # The settled-wake check keeps its own baseline: no baseline reads as changed, a recorded one reads
  # as unchanged until a line is appended, and recording it never moves the heartbeat's.
  rm -f "$dir/state/.wake-ack-fleet-fp"
  core "$dir" fleet-unchanged "$dir/state/.wake-ack-fleet-fp" && fail "a missing baseline read as an unchanged fleet"
  cp "$dir/state/.heartbeat-fleet-fp" "$dir/heartbeat-fp.before"
  printf 'working [at=%s]: wrote the tests\n' "$(date +%s)" >> "$dir/state/lane.status"
  core "$dir" fleet-fp-record "$dir/state/.wake-ack-fleet-fp"
  core "$dir" fleet-unchanged "$dir/state/.wake-ack-fleet-fp" || fail "a just-recorded baseline read as a changed fleet"
  cmp -s "$dir/heartbeat-fp.before" "$dir/state/.heartbeat-fleet-fp" || fail "recording the settled-wake baseline moved the heartbeat's"
  printf 'working [at=%s]: wrote the docs\n' "$(date +%s)" >> "$dir/state/lane.status"
  core "$dir" fleet-unchanged "$dir/state/.wake-ack-fleet-fp" && fail "a fleet with a new status line read as unchanged"
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
  # The watcher re-delivers a queued row once it is JG_SQUAD_LEAD_WAKE_STALL_SECS (1) old, so let it age.
  sleep 2
  cycle_wake "$dir"
  grep -q 'inbox:9\|captain inbox note 9' "$dir/events" || fail "a captain answer did not wake at once: events=$(cat "$dir/events") out=$(cat "$dir/out") err=$(cat "$dir/err") queue=$(cat "$dir/state/.wake-queue" 2>/dev/null) class=$(route "$dir" check 'inbox:9' 'check: captain inbox note 9 - answer')"
  pass "a captain answer, a red gate, a host alarm, a stuck worker and a finished deliverable wake at once"
}

# --- 4. a planned wait does not wake or re-ping; an unconditioned block still escalates ---
test_planned_wait_is_quiet() {
  local dir fut stale_beyond stale_due timer_pause timer_block
  dir=$(new_home planned)
  fut=$(date -u -d '+3 days' +%Y-%m-%dT%H:%MZ)
  stale_beyond='stale: w:1 (paused 9s, awaiting external - the declared time is beyond the recheck cadence; confirm the wait still holds)'
  stale_due='stale: w:1 (paused 9s, awaiting external - the declared clearing time has passed, rechecked on a long cadence not a wedge; confirm the wait cleared)'
  timer_pause='check: waiting-state lane (paused, observed 9s, level=owner; still open, owning lead must recheck and unblock) id=x'
  timer_block='check: waiting-state lane (blocked key=held, observed 9s, level=owner; owning lead must recheck and unblock) id=x'

  # A change held for the next release branch names its future event: a paused line with `until`.
  printf 'paused [at=%s]: PR held for release/c-6 until %s\n' "$(date +%s)" "$fut" > "$dir/state/planned.status"
  assert_equals batch "$(route "$dir" signal planned.status 'signal: planned.status')" "a planned wait must not wake on its status line"
  assert_equals batch "$(route "$dir" stale w:1 "$stale_beyond")" "a planned wait with its time ahead must not re-ping"
  assert_equals batch "$(route "$dir" check waiting-timer-h-planned-g1-default-owner-again "$timer_pause")" "a planned wait's timer must not re-ping"
  # Once the declared time has passed the wait is rechecked once, so a plan that slipped is found.
  assert_equals now "$(route "$dir" stale w:1 "$stale_due")" "a pause past its declared time must wake"

  # A block that names no clearing condition is a stuck worker and keeps escalating.
  printf 'blocked [at=%s] [key=held]: waiting, cannot continue\n' "$(date +%s)" > "$dir/state/stuck.status"
  assert_equals now "$(route "$dir" signal stuck.status 'signal: stuck.status')" "a block with no clearing condition must wake"
  assert_equals now "$(route "$dir" check waiting-timer-h-stuck-g1-held-owner "$timer_block")" "a block with no clearing condition must escalate"

  # The real appender queues the planned wait's re-ping as routine, so no cycle wakes for it.
  rm -f "$dir"/state/*.status
  : > "$dir/events"
  append "$dir" stale w:1 "$stale_beyond" >/dev/null
  cycle "$dir"
  [ ! -s "$dir/events" ] || fail "a planned wait woke the supervisor: $(cat "$dir/events")"
  pass "a planned wait raises no wake and no re-ping, and a block with no clearing condition still escalates"
}

# --- 5. the four notices that cost Main a turn for nothing after c-5 ---------------
test_wake_misses_after_c5() {
  local dir state now hb pre pulse lead
  dir=$(new_home misses)
  state="$dir/state"
  now=$(date +%s)
  hb="$state/fleet-heartbeat.check.sh"
  pre="check: $hb: fleet heartbeat:"

  # (a) A gap that has only just opened rides the digest; a gap open past the threshold wakes.
  assert_equals batch "$(route "$dir" check "$hb" "$pre homeA GAP for 0s - 1 ready, 2 of 6 lanes working, 18 paused wait(s)")" "a gap just opened must ride the digest"
  assert_equals batch "$(route "$dir" check "$hb" "$pre homeA GAP for 0s - 2 ready, 0 of ? lanes working, pause declaration failed in config/x")" "a failure word in a fresh gap's side note must not wake"
  assert_equals batch "$(route "$dir" check "$hb" "$pre homeA GAP for 3599s - 1 ready, 1 of 6 lanes working")" "a gap just under the threshold still rides the digest"
  assert_equals batch "$(route "$dir" check "$hb" "$pre homeA GAP for 0s - work waits in a new shape")" "an unknown gap shape rides the digest"
  assert_equals now "$(route "$dir" check "$hb" "$pre homeA GAP for 3600s - 1 ready, 1 of 6 lanes working, 20 paused wait(s)")" "a gap open at the threshold must wake"
  assert_equals now "$(route "$dir" check "$hb" "$pre homeA GAP for 0s - 1 ready, 2 of 6 lanes working $pre homeB GAP for 7200s - 3 ready, 0 of 4 lanes working")" "a long gap in any home of the report must wake"
  assert_equals now "$(route "$dir" check "$hb" "$pre homeA STALLED for 9s - work waits but no supervision beat for 999s")" "a stall keeps waking"
  printf 'set gap-wake-seconds 600\n' > "$dir/config/wake-routing"
  assert_equals now "$(route "$dir" check "$hb" "$pre homeA GAP for 700s - 1 ready, 1 of 6 lanes working")" "a home can lower the gap threshold"
  rm -f "$dir/config/wake-routing"

  # (b) The fleet-pulse 2h report rides the digest whatever words it carries; another fleet-pulse
  # failure keeps waking.
  pulse="$state/fleet-pulse.check.sh"
  assert_equals batch "$(route "$dir" check "$pulse" "check: $pulse: fleet-pulse 2h (landings = merged PRs; open target 4, ! = over, UNDER = free slots with ready work; rule words 8602): crewhouse:landed0/open1(w0 done0 asks>2h0 dry=1) STALLED GATE-BYPASS1 - steer STALLED, GATE-BYPASS (merged without a passing checks-lint) | alarm: 2 lanes failed FAILED")" "the 2h report must ride the digest even when it names a stall or a failure"
  assert_equals now "$(route "$dir" check "$pulse" "check: $pulse: setup sync failed: credential shape refused")" "another fleet-pulse failure must wake"
  : > "$dir/events"
  assert_equals batch:fleet-pulse.check.sh "$(append "$dir" check fleet-pulse.check.sh "check: fleet-pulse.check.sh: fleet-pulse 2h (landings = merged PRs): crewhouse:landed0/open1 STALLED failed")" "the production appender must batch the 2h report"
  cycle "$dir"
  [ ! -s "$dir/events" ] || fail "the 2h report woke the supervisor: $(cat "$dir/events")"

  # (c) A relaunch that lost the race to another spawn is noise only during Main's restart pass.
  lead="check: squad_lead beta auto-relaunch failed after dead (pane): error: another spawn is already creating task beta"
  assert_equals now "$(route "$dir" check "squad-lead-relaunch-failed-beta-$now" "$lead")" "the same notice outside a restart pass must wake"
  printf '%s\tbeta\n' "$now" > "$state/.squad-lead-restart-pass"
  assert_equals silent "$(route "$dir" check "squad-lead-relaunch-failed-beta-$now" "$lead")" "the notice during a restart pass must settle"
  assert_equals now "$(route "$dir" check "squad-lead-relaunch-failed-gamma-$now" "${lead//beta/gamma}")" "a lead outside the restart pass keeps waking"
  assert_equals now "$(route "$dir" check "squad-lead-relaunch-failed-beta-$now" "check: squad_lead beta auto-relaunch failed after dead (pane): error: no such backend")" "any other relaunch failure keeps waking in a pass"
  printf '%s\tbeta\n' "$((now - 9999))" > "$state/.squad-lead-restart-pass"
  assert_equals now "$(route "$dir" check "squad-lead-relaunch-failed-beta-$now" "$lead")" "the notice long after the pass must wake"
  rm -f "$state/.squad-lead-restart-pass"

  # (d) 'supervision not running' seconds after the lead's own restart is noise; a lead still down
  # after the grace window keeps waking.
  lead="check: squad_lead beta supervision not running while it has work under way; it was told to re-arm, and the wait escalates until it does"
  assert_equals now "$(route "$dir" check "squad-lead-supervision-beta-$now" "$lead")" "a lead with no recent restart must wake"
  printf '%s\trelaunched\n' "$((now - 20))" > "$state/.squad-lead-relaunch-beta"
  assert_equals silent "$(route "$dir" check "squad-lead-supervision-beta-$now" "$lead")" "seconds after its relaunch the notice must settle"
  assert_equals now "$(route "$dir" check "squad-lead-supervision-gamma-$now" "${lead//beta/gamma}")" "another lead's restart does not cover this lead"
  printf '%s\trelaunched\n' "$((now - 400))" > "$state/.squad-lead-relaunch-beta"
  assert_equals now "$(route "$dir" check "squad-lead-supervision-beta-$now" "$lead")" "a lead still down after the grace window must wake"
  printf '%s\tfailed\n' "$((now - 20))" > "$state/.squad-lead-relaunch-beta"
  assert_equals now "$(route "$dir" check "squad-lead-supervision-beta-$now" "$lead")" "a failed relaunch is no restart"
  rm -f "$state/.squad-lead-relaunch-beta"
  printf '%s\tbeta\n' "$now" > "$state/.squad-lead-restart-pass"
  assert_equals silent "$(route "$dir" check "squad-lead-supervision-beta-$now" "$lead")" "Main's restart pass still covers the lead"
  rm -f "$state/.squad-lead-restart-pass"
  pass "the four c-5 wake misses settle in their quiet case and still wake in the real one"
}

# --- 6. routine wakes batch by count or delay; urgent classes bypass the batch -------
# `set digest-count` (default 5) and `set digest-minutes` (default 15) in defaults/wake-routing,
# overridable by a home's config/wake-routing. Whichever trigger fires first releases the routine
# rows as ONE wake.
merged_row() { append "$1" check "merged-$2" "check: merged-$2: PR merged" >/dev/null; }  # <dir> <n>

test_batch_threshold() {
  local dir n now
  dir=$(new_home batch-threshold)
  now=$(date +%s)
  : > "$dir/events"
  assert_equals batch "$(route "$dir" check merged-1 'check: merged-1: PR merged')" "a merge notice is routine"

  # (a) Count trigger, shipped default of 5: four routine rows wait, the fifth releases them as one wake.
  for n in 1 2 3 4; do merged_row "$dir" "$n"; done
  core "$dir" digest mark >/dev/null && fail "four routine rows released a batch before the threshold"
  cycle "$dir"
  [ ! -s "$dir/events" ] || fail "four routine rows woke the supervisor: $(cat "$dir/events")"
  merged_row "$dir" 5
  assert_equals 5 "$(core "$dir" digest)" "the fifth routine row did not release the batch"
  cycle_wake "$dir"
  grep -q 'digest - 5 routine' "$dir/events" || fail "the count trigger never woke: $(cat "$dir/events") $(cat "$dir/err")"
  [ "$(grep -c 'digest - ' "$dir/events")" = 1 ] || fail "the batch woke more than once: $(cat "$dir/events")"
  grep -q 'merged-5' "$dir/drain" || fail "the batch wake's drain did not carry the held rows"

  # The count starts again from zero after a release: four more rows are held, the fifth releases.
  : > "$dir/events"
  for n in 6 7 8 9; do merged_row "$dir" "$n"; done
  cycle "$dir"
  [ ! -s "$dir/events" ] || fail "rows after a release woke early: $(cat "$dir/events")"
  merged_row "$dir" 10
  cycle_wake "$dir"
  grep -q 'digest - 5 routine' "$dir/events" || fail "the second batch never woke: $(cat "$dir/events")"

  # (b) Delay trigger, shipped default of 15 minutes: two rows wait, due only once the delay passed.
  cycle "$dir"; : > "$dir/events"
  merged_row "$dir" 11; merged_row "$dir" 12
  printf '%s\n' "$((now - 14 * 60))" > "$dir/state/.wake-digest-at"
  core "$dir" digest >/dev/null && fail "a batch was released before 15 minutes"
  printf '%s\n' "$((now - 16 * 60))" > "$dir/state/.wake-digest-at"
  assert_equals 2 "$(core "$dir" digest)" "the delay trigger did not release the batch after 15 minutes"
  cycle_wake "$dir"
  grep -q 'digest - 2 routine' "$dir/events" || fail "the delay trigger never woke: $(cat "$dir/events")"

  # (c) The knob: a home's config/wake-routing wins over the shipped default.
  cycle "$dir"; : > "$dir/events"
  printf 'set digest-count 2\n' > "$dir/config/wake-routing"
  merged_row "$dir" 13
  core "$dir" digest mark >/dev/null && fail "one row released a batch under digest-count 2"
  merged_row "$dir" 14
  assert_equals 2 "$(core "$dir" digest)" "digest-count 2 did not release two rows"
  printf 'set digest-count 0\n' > "$dir/config/wake-routing"
  merged_row "$dir" 15; merged_row "$dir" 16; merged_row "$dir" 17
  core "$dir" digest >/dev/null && fail "digest-count 0 did not turn the count trigger off"
  rm -f "$dir/config/wake-routing"
  pass "routine rows are held and released as one wake at 5 rows or 15 minutes, and the knobs override"
}

test_batch_urgent_bypass() {
  local dir n
  dir=$(new_home batch-urgent)
  for n in 1 2 3; do merged_row "$dir" "$n"; done
  printf 'blocked [at=%s]: stuck\n' "$(date +%s)" > "$dir/state/b.status"
  printf 'done [at=%s]: report written\n' "$(date +%s)" > "$dir/state/d.status"
  printf 'needs-decision [at=%s]: pick\n' "$(date +%s)" > "$dir/state/n.status"
  printf 'failed [at=%s]: broke\n' "$(date +%s)" > "$dir/state/f.status"
  assert_equals now "$(route "$dir" check inbox:3 'check: captain inbox note 3')" "a captain note bypasses the batch"
  assert_equals now "$(route "$dir" check ci.check.sh 'check: PR 12 checks failed')" "a failed check bypasses the batch"
  assert_equals now "$(route "$dir" signal b.status 'signal: b.status')" "blocked bypasses the batch"
  assert_equals now "$(route "$dir" signal n.status 'signal: n.status')" "needs-decision bypasses the batch"
  assert_equals now "$(route "$dir" signal d.status 'signal: d.status')" "done bypasses the batch"
  assert_equals now "$(route "$dir" signal f.status 'signal: f.status')" "failed bypasses the batch"
  assert_equals now "$(route "$dir" stale crew:w1 'stale: crew:w1 (no output for 20 minutes)')" "a stale escalation bypasses the batch"
  assert_equals now "$(route "$dir" check delete-guard 'check: delete guard blocked a command')" "a security alarm bypasses the batch"

  # With three routine rows held and the batch not due, a blocked status line is found by the
  # watcher's own scan and wakes at once, by itself, leaving the held rows for the next drain.
  rm -f "$dir"/state/*.status
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$dir/state/lane.meta"
  printf 'working [at=%s]: building\n' "$(date +%s)" > "$dir/state/lane.status"
  prime_status_seen "$dir/state" "$dir/state/lane.status"
  printf 'blocked [at=%s] [key=stuck]: waiting on the captain\n' "$(date +%s)" >> "$dir/state/lane.status"
  : > "$dir/events"
  cycle_wake "$dir"
  grep -q 'lane\.status' "$dir/events" || fail "a blocked line did not bypass the held batch: events=$(cat "$dir/events") err=$(cat "$dir/err")"
  ! grep -q 'digest - ' "$dir/events" || fail "the urgent wake was reported as a digest"
  grep -q 'merged-3' "$dir/drain" || fail "the held routine rows were not presented by the urgent wake's drain"
  pass "captain, failed, blocked, needs-decision, done, security and stale events bypass the batch"
}

# --- 7. a PR-ready outcome rides the ten-minute merge-ready batch, never its own wake -----------
# core/merge-on-green/merge-ready-batch.sh is the one line per window that names every PR-ready outcome with
# its authority verdict, and it wakes the lead; the individual PR-ready row stays queued (nothing dropped).
test_merge_ready_batches() {
  local dir
  dir=$(new_home merge-ready)
  printf 'done [at=%s]: PR https://example.test/pr/1\n' "$(date +%s)" > "$dir/state/ship.status"
  printf 'kind=ship\n' > "$dir/state/ship.meta"
  assert_equals batch "$(route "$dir" signal ship.status 'signal: ship.status')" "a PR-ready report must ride the batch, not wake alone"
  assert_equals now "$(route "$dir" check state/merge-on-green.check.sh 'merge-on-green: merge-ready batch, 2 outcome(s): a x: mergeable;')" "the batch line wakes the lead once"
  assert_equals now "$(route "$dir" check state/merge-on-green.check.sh 'merge-on-green: NOT merging a x: refused')" "a refusal still wakes at once"
  printf 'failed [at=%s]: broke\n' "$(date +%s)" > "$dir/state/ship.status"
  assert_equals now "$(route "$dir" signal ship.status 'signal: ship.status')" "a failed report is never batched"
  printf 'done [at=%s]: PR https://example.test/pr/2\n' "$(date +%s)" > "$dir/state/recon.status"
  printf 'kind=scout\n' > "$dir/state/recon.meta"
  assert_equals now "$(route "$dir" signal recon.status 'signal: recon.status')" "a Recon result is never batched"
  pass "a PR-ready outcome waits for the merge-ready batch; the batch line and a refusal wake"
}

if [ "${WAKE_SCHEDULE_ONLY:-}" = batch-threshold ]; then
  test_batch_threshold
  test_batch_urgent_bypass
  echo "wake batch threshold: count trigger, delay trigger, knob override and urgent bypass"
  exit 0
fi

test_routine_rides_the_digest
test_unchanged_fleet_no_heartbeat
test_urgent_stays_now
test_planned_wait_is_quiet
test_wake_misses_after_c5
test_batch_threshold
test_batch_urgent_bypass
test_merge_ready_batches
echo "wake schedule: routine rides the digest, an unchanged fleet is silent, urgent still wakes, the c-5 misses settle"
