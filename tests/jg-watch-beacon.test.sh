#!/usr/bin/env bash
# The watcher liveness beacon (state/.last-watcher-beat), read the way a lead's
# supervision check reads it. The real watcher is armed in throwaway homes with
# bin/jg-watch-arm.sh, and every verdict below comes from bin/jg-supervision-lib.sh.
#
#   healthy sweep  A due-check sweep runs every registered state/*.check.sh in turn, each bounded
#                  only by JG_CHECK_TIMEOUT, so a healthy scan can outlast the stale grace. The
#                  home must stay supervised throughout: publishing the beacon only at the end of
#                  a scan made exactly this cycle read as a dead watcher, which is the false
#                  "the watcher beacon is Ns old and no turn is running" alarm that cost main a turn.
#   killed watcher The same home, killed on a fresh beacon, must read as unsupervised within the
#                  grace while supervision is still needed, so the real detector still fires.
#   actionable exit A cycle that ends on a delivered wake leaves a beacon, and the home stays
#                  supervised once the hand-off stamp ages out.
#
# This is also the test that owns journeys/watcher-exit-beacon.sh (the done-done journey runs this
# file), so the changed-test map selects it for a change to that journey.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH_ARM="$ROOT/bin/jg-watch-arm.sh"
LIB="$ROOT/bin/jg-wake-lib.sh"
SUP_LIB="$ROOT/bin/jg-supervision-lib.sh"

# shellcheck source=/dev/null
. "$LIB"
# shellcheck source=/dev/null
. "$SUP_LIB"

TMP_ROOT=$(jg_test_tmproot jg-watch-beacon)
cleanup() {
  local p
  for p in "$TMP_ROOT"/*/state/.watch.lock/pid; do
    [ -e "$p" ] || continue
    kill -TERM "$(cat "$p" 2>/dev/null)" 2>/dev/null || true
  done
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

# A home on the file wake queue, so a machine with no wake-bus service running
# cannot stall the scan this suite is measuring.
make_home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config" || fail "could not create the throwaway home"
  printf 'off\n' > "$dir/config/wake-bus"
  printf '%s\n' "$dir"
}

# Wait for <path> to exist, up to <polls> tenths.
wait_file() {  # <path> <polls>
  local i
  for ((i = 0; i < $2; i++)); do
    [ ! -e "$1" ] || return 0
    sleep 0.1
  done
  return 1
}

register_slow_checks() {  # <dir> <count> <seconds> <log>
  local dir=$1 count=$2 secs=$3 log=$4 i
  for ((i = 1; i <= count; i++)); do
    cat > "$dir/state/slow$i.check.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$(date +%s)" >> "$log"
sleep $secs
exit 0
EOF
    chmod 0700 "$dir/state/slow$i.check.sh"
    JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" "$ROOT/bin/jg-check-register.sh" "slow$i" >/dev/null \
      || fail "could not register slow$i"
  done
}

supervision_read() {  # <dir> <grace>
  JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" jg_supervision_status "$1/state" "$2"
}

# --- A live sweep longer than the grace stays supervised; a killed watcher does not.
test_live_sweep_is_supervised_and_a_killed_watcher_is_not() (
  local dir state beat runs log grace=4 arm i unhealthy=0 peak=0 samples=0 runs_before runs_during
  local age_now watcher_pid took detected=no started
  dir=$(make_home sweep)
  state=$dir/state
  beat=$state/.last-watcher-beat
  log=$dir/check-runs.log
  runs=$log
  : > "$log"
  # shellcheck disable=SC2030,SC2031 # Each case runs in its own subshell, so its exports die with it.
  export JG_HOME="$dir" JG_STATE_OVERRIDE="$state" JG_POLL=0.2 JG_SIGNAL_GRACE=0 \
    JG_GUARD_GRACE=$grace JG_CHECK_INTERVAL=0 JG_CHECK_TIMEOUT=5 JG_HEARTBEAT=999999
  # Four slow checks: one sweep is twice the grace, the shape a busy home reaches
  # when its checks come due together.
  register_slow_checks "$dir" 4 2 "$log"
  "$WATCH_ARM" > "$dir/arm.out" 2>&1 &
  arm=$!
  wait_file "$beat" 600 || fail "the real watcher published no beacon: $(cat "$dir/arm.out")"
  watcher_pid=$(cat "$state/.watch.lock/pid") || fail "the watcher holds no lock"
  runs_before=$(wc -l < "$runs")
  for ((i = 0; i < 250; i++)); do
    supervision_read "$dir" "$grace"
    if [ "$JG_SUP_WATCHER_FRESH" != true ]; then
      unhealthy=$((unhealthy + 1))
      [ "$unhealthy" -gt 3 ] || printf 'unsupervised mid-sweep: needed=%s fresh=%s beacon=%s\n' \
        "$JG_SUP_NEEDED" "$JG_SUP_WATCHER_FRESH" "$JG_SUP_BEACON_DESC" >&2
    fi
    age_now=$(jg_path_age "$beat")
    [ "$age_now" -gt "$peak" ] && peak=$age_now
    samples=$((samples + 1))
    sleep 0.1
  done
  runs_during=$(( $(wc -l < "$runs") - runs_before ))
  [ "$runs_during" -ge 2 ] || fail "no due-check sweep ran inside the window, so this proves nothing"
  [ "$unhealthy" -eq 0 ] \
    || fail "a live, working watcher read as unsupervised $unhealthy times during its own check sweep (checks run: $runs_during, peak beacon age ${peak}s, grace ${grace}s)"

  # Kill it on a fresh beacon and require the real detector, with supervision still needed.
  for ((i = 0; i < 200; i++)); do
    [ "$(jg_path_age "$beat")" -gt 1 ] || break
    sleep 0.1
  done
  supervision_read "$dir" "$grace"
  [ "$JG_SUP_NEEDED" = true ] || fail "supervision was not needed, so the kill direction would be vacuous"
  kill -TERM "$watcher_pid" 2>/dev/null
  wait "$arm" 2>/dev/null
  started=$(date +%s)
  for ((i = 0; i < 400; i++)); do
    supervision_read "$dir" "$grace"
    if [ "$JG_SUP_NEEDED" = true ] && [ "$JG_SUP_WATCHER_FRESH" = false ]; then detected=yes; break; fi
    sleep 0.1
  done
  took=$(( $(date +%s) - started ))
  [ "$detected" = yes ] || fail "a killed watcher was never reported unsupervised (beacon $(jg_path_age "$beat")s old)"
  [ "$took" -le $((grace + 10)) ] || fail "a killed watcher took ${took}s to report, past the ${grace}s grace window"
  pass "a live watcher stayed supervised through a ${runs_during}-check sweep longer than the ${grace}s grace, and a killed watcher read as unsupervised in ${took}s"
  kill -TERM "$watcher_pid" 2>/dev/null
)

# --- A cycle that ends on a delivered wake leaves a supervised home behind.
test_actionable_exit_leaves_the_home_supervised() (
  local dir state beat arm
  dir=$(make_home exit)
  state=$dir/state
  beat=$state/.last-watcher-beat
  # shellcheck disable=SC2030,SC2031 # Each case runs in its own subshell, so its exports die with it.
  export JG_HOME="$dir" JG_STATE_OVERRIDE="$state" JG_POLL=0.2 JG_SIGNAL_GRACE=0 \
    JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 JG_ARM_CONFIRM_TIMEOUT=60
  unset JG_GUARD_GRACE
  printf 'x\n' > "$state/job.meta"
  printf 'done: completed lane\n' > "$state/job.status"
  touch -t "$(date -d "@$(( $(date +%s) - 600 ))" +%Y%m%d%H%M.%S 2>/dev/null \
    || date -r "$(( $(date +%s) - 600 ))" +%Y%m%d%H%M.%S)" "$beat"
  "$WATCH_ARM" > "$dir/arm.out" 2>&1 || true
  grep -q '^signal:' "$dir/arm.out" \
    || fail "the watcher did not end its cycle on the signal: $(head -n 3 "$dir/arm.out")"
  rm -f "$state/.last-watcher-handoff"
  supervision_read "$dir" 300
  [ "$JG_SUP_WATCHER_FRESH" = true ] \
    || fail "the home reads as unsupervised after an actionable exit (beacon $JG_SUP_BEACON_DESC)"
  pass "an actionable exit leaves the home supervised once the hand-off stamp ages out"
)

# A stale predecessor must not prevent completed first-scan units from proving progress.
test_stale_first_scan_progress_and_restart() (
  local dir state arm pid i checks
  dir=$(make_home first-scan)
  state=$dir/state
  # shellcheck disable=SC2030,SC2031 # Exports stay inside this case subshell.
  export JG_HOME="$dir" JG_STATE_OVERRIDE="$state" JG_POLL=0.2 JG_SIGNAL_GRACE=0 \
    JG_GUARD_GRACE=4 JG_CHECK_INTERVAL=0 JG_CHECK_TIMEOUT=10 JG_HEARTBEAT=0 JG_ARM_CONFIRM_TIMEOUT=60
  register_slow_checks "$dir" 4 2 "$dir/check-runs.log"
  touch -t "$(date -d "@$(( $(date +%s) - 600 ))" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$(( $(date +%s) - 600 ))" +%Y%m%d%H%M.%S)" "$state/.last-watcher-beat"
  "$WATCH_ARM" > "$dir/arm.out" 2>&1 &
  arm=$!
  wait_file "$dir/check-runs.log" 600 || fail "first scan never reached a check"
  # A PID before any completed work is insufficient evidence.
  ! JG_HOME="$dir" jg_watcher_healthy "$state" "$ROOT/bin/jg-watch.sh" 4 "$dir" \
    || fail "a first scan with no completed unit was called healthy"
  for ((i = 0; i < 600; i++)); do
    if JG_HOME="$dir" jg_watcher_healthy "$state" "$ROOT/bin/jg-watch.sh" 4 "$dir"; then break; fi
    sleep 0.1
  done
  [ "$i" -lt 600 ] || fail "completed first-scan work never confirmed health"
  checks=$(wc -l < "$dir/check-runs.log")
  [ "$checks" -lt 4 ] || fail "stale recovery withheld all progress until the whole first scan ($checks checks)"
  pid=$(cat "$state/.watch.lock/pid")
  kill -TERM "$arm"
  wait "$arm" 2>/dev/null || true
  ! jg_pid_alive "$pid" || fail "interrupted arm left its watcher running"
  "$WATCH_ARM" > "$dir/restart.out" 2>&1 &
  arm=$!
  # This marker is written at the heartbeat at the end of the scan, after all checks.
  wait_file "$state/.heartbeat-streak" 600 || fail "restarted first scan never completed"
  supervision_read "$dir" 4
  [ "$JG_SUP_WATCHER_FRESH" = true ] || fail "completed first scan reads unsupervised"
  JG_HOME="$dir" jg_watcher_healthy "$state" "$ROOT/bin/jg-watch.sh" 4 "$dir" \
    || fail "guard and supervision disagree after first-scan progress"
  kill -TERM "$arm"
  wait "$arm" 2>/dev/null || true
  printf 'first-scan: checks before interruption=%s; completed heartbeat=%s; strict guard and supervision=true\n' \
    "$checks" "$(cat "$state/.heartbeat-streak")"
  pass "stale first-scan progress confirms real work, interrupted recovery resumes and completes, and guard agrees"
)

# A timed-out contributions check followed by an untrusted orphan must surface the
# rejection, not crash in the no-control-lock release path.
test_timeout_and_orphan_release_return() (
  local dir state
  dir=$(make_home release-return)
  state=$dir/state
  cat > "$state/contributions.check.sh" <<EOF
#!/usr/bin/env bash
touch "$dir/contributions-ran"
sleep 5
EOF
  chmod 0700 "$state/contributions.check.sh"
  JG_HOME="$dir" "$ROOT/bin/jg-check-register.sh" contributions >/dev/null || fail "register contributions"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$state/orphan.check.sh"
  chmod 0700 "$state/orphan.check.sh"
  JG_HOME="$dir" JG_STATE_OVERRIDE="$state" JG_CHECK_TIMEOUT=1 JG_CHECK_INTERVAL=0 \
    JG_POLL=0.2 JG_SIGNAL_GRACE=0 JG_HEARTBEAT=999999 "$WATCH_ARM" > "$dir/arm.out" 2>&1 \
    || fail "release-return crashed: $(cat "$dir/arm.out")"
  [ -e "$dir/contributions-ran" ] || fail "timeout direction was not exercised"
  grep -q '^check: rejected unauthenticated state checks:.*orphan.check.sh' "$dir/arm.out" \
    || fail "orphan rejection was not delivered: $(cat "$dir/arm.out")"
  pass "a timed-out contributions check releases without a control lock and the orphan rejection is delivered"
)

# The guard and the supervision read must agree on a live watcher still in its first scan: the
# supervision read calls it "starting" (healthy), so the verdict the guard and the inbox act on
# must not call the same home down. A disagreement printed "WATCHER DOWN ... last beat: starting".
test_first_scan_holder_is_not_called_down() (
  local dir state arm age
  dir=$(make_home first-scan-verdict)
  state=$dir/state
  # shellcheck disable=SC2030,SC2031 # Exports stay inside this case subshell.
  export JG_HOME="$dir" JG_STATE_OVERRIDE="$state" JG_POLL=0.2 JG_SIGNAL_GRACE=0 \
    JG_GUARD_GRACE=4 JG_CHECK_INTERVAL=0 JG_CHECK_TIMEOUT=20 JG_HEARTBEAT=0 JG_ARM_CONFIRM_TIMEOUT=60 \
    JG_WATCHER_STALL_BOUND=60 JG_SUPERVISION_MODEL=persistent
  register_slow_checks "$dir" 1 8 "$dir/check-runs.log"
  touch -t "$(date -d "@$(( $(date +%s) - 600 ))" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$(( $(date +%s) - 600 ))" +%Y%m%d%H%M.%S)" "$state/.last-watcher-beat"
  "$WATCH_ARM" > "$dir/arm.out" 2>&1 &
  arm=$!
  wait_file "$dir/check-runs.log" 600 || fail "first scan never reached a check"
  supervision_read "$dir" 4
  case "$JG_SUP_BEACON_DESC" in starting*) ;; *) fail "setup: the supervision read is not in the starting state ($JG_SUP_BEACON_DESC)" ;; esac
  jg_watcher_supervision_verdict "$state" "$ROOT/bin/jg-watch.sh" 4 "$dir" "$ROOT"
  [ "$JG_WATCHER_VERDICT_OK" = true ] \
    || fail "the verdict calls a live first-scan watcher down (${JG_WATCHER_VERDICT_REASON}) while supervision reads it as $JG_SUP_BEACON_DESC"
  # The strict arm-side primitive is unchanged: a pid before any completed work is not healthy.
  ! jg_watcher_healthy "$state" "$ROOT/bin/jg-watch.sh" 4 "$dir" \
    || fail "the strict watcher check called a first scan with no completed unit healthy"
  kill -TERM "$arm"
  wait "$arm" 2>/dev/null || true
  age=$(jg_path_age "$state/.last-watcher-beat")
  pass "a live first-scan watcher reads as starting and the guard verdict agrees (beat age ${age}s)"
)

if [ "${JG_WATCH_BEACON_FIRST_SCAN_ONLY:-0}" = 1 ]; then
  test_stale_first_scan_progress_and_restart
  exit
fi
test_timeout_and_orphan_release_return
test_first_scan_holder_is_not_called_down
test_stale_first_scan_progress_and_restart
test_live_sweep_is_supervised_and_a_killed_watcher_is_not
test_actionable_exit_leaves_the_home_supervised

# journeys/supervision-gap-records.sh captures this same integration journey.
bash "$ROOT/journeys/supervision-gap-integration.sh" || fail "supervision gap journey failed"
