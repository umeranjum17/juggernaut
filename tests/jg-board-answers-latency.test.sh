#!/usr/bin/env bash
# tests/jg-board-answers-latency.test.sh - a board answer wakes Main within a minute,
# with no manual arm, and a broken registration heals itself or says so once.
# Runs the REAL watcher on a throwaway home; only sign-off-axi is a fixture.
#   Quick (default): JG_POLL=1, tick every 3 s, bound 20 s.
#   Production timing: JG_BOARD_LATENCY_REAL=1 uses the shipped defaults
#   (15 s cycle, 30 s tick) and the 60 s bound; it takes about two minutes.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-board-latency)
WATCH="$ROOT/bin/jg-watch.sh"
DRAIN="$ROOT/bin/jg-wake-drain.sh"
BA="$ROOT/bin/jg-board-answers.sh"

if [ "${JG_BOARD_LATENCY_REAL:-0}" = 1 ]; then
  POLL_ENV=() BOUND=60 QUIET=50
else
  POLL_ENV=(JG_POLL=1 JG_FAST_CHECK_INTERVAL=3) BOUND=20 QUIET=8
fi
LATENCY_LOG=${JG_BOARD_LATENCY_LOG:-}

new_home() {  # <name> -> case dir with a fake board; the board's answers file is empty
  local d
  d=$(make_case "$1")
  mkdir -p "$d/home/config" "$d/tmp" "$d/config" "$d/so/.sign-off"
  printf '{"schema":2,"items":[]}\n' > "$d/so/.sign-off/decisions.json"
  : > "$d/so/.sign-off/decisions.answers.jsonl"
  cat > "$d/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1; shift
board=$SIGN_OFF_HOME/.sign-off/decisions.json
case "$cmd" in
  answers) jq -s 'reduce .[] as $a ({}; .[$a.key] = ($a | del(.key)))' "${board%.json}.answers.jsonl" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$d/fakebin/sign-off-axi"
  printf '%s\n' "$d"
}

answer() {  # <dir> <key> <epoch>
  printf '{"key":"%s","answer":"yes","label":"yes","close":"done","at":"2026-11-06T02:02:%02dZ"}\n' "$2" "$(($3 % 60))" \
    >> "$1/so/.sign-off/decisions.answers.jsonl"
}

start_watch() {  # <dir> -> sets WPID
  env HOME="$1/home" XDG_CONFIG_HOME="$1/home/config" TMPDIR="$1/tmp" PATH="$1/fakebin:${WATCH_PATH:-$PATH}" \
    JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" JG_CONFIG_OVERRIDE="$1/config" SIGN_OFF_HOME="$1/so" \
    JG_SIGNAL_GRACE=1 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS=99999999 JG_STALE_ESCALATE_SECS=999999 "${POLL_ENV[@]}" \
    "$WATCH" > "$1/out" 2> "$1/err" &
  WPID=$!
}

stop_watch() {
  kill "$WPID" 2>/dev/null || true
  wait_for_exit "$WPID" 100 >/dev/null 2>&1 || true
}

# Wait up to <limit> s for a durable wake row matching <pattern>; print the seconds it took.
wait_wake() {  # <limit> <dir> <pattern>
  local start now
  start=$(date +%s.%N)
  while :; do
    now=$(date +%s.%N)
    if grep -q -- "$3" "$2/state/.wake-queue" 2>/dev/null; then
      awk -v a="$start" -v b="$now" 'BEGIN { printf "%.1f", b - a }'
      return 0
    fi
    awk -v a="$start" -v b="$now" -v l="$1" 'BEGIN { exit !(b - a > l) }' && { awk -v a="$start" -v b="$now" 'BEGIN { printf "%.1f", b - a }'; return 1; }
    sleep 0.2
  done
}

ack() {  # <dir>
  local seq gen
  JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" "$DRAIN" > "$1/drain" 2> "$1/ack"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$1/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$1/ack")
  [ -z "$seq" ] || JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" > /dev/null
}

wait_for() {  # <limit> <command...>: poll until the command succeeds
  local limit=$1 i=0
  shift
  while [ "$i" -lt $((limit * 5)) ]; do
    "$@" && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

registered() {  # <dir>
  bash -c '. "$1/bin/jg-pr-lib.sh"; . "$1/bin/jg-check-lib.sh"; jg_custom_check_registered "$2" board-answers' _ "$ROOT" "$1/state"
}

test_new_answer_wakes_within_the_bound_with_no_manual_arm() {
  local d secs
  d=$(new_home latency)
  answer "$d" already-on-the-board 1   # on the board before anything is armed
  [ ! -e "$d/state/board-answers.check.sh" ] || fail "fixture started armed"
  start_watch "$d"
  wait_for 40 registered "$d" || { stop_watch; fail "the watcher never armed the check itself: $(cat "$d/err")"; }
  wait_for 20 grep -qs already-on-the-board "$d/state/.board-answers-seen" || { stop_watch; fail "the first pass did not record the board's answers"; }
  # First pass is silent: with the answer recorded the watcher is still waiting.
  sleep 4
  ! grep -q 'already-on-the-board' "$d/state/.wake-queue" 2>/dev/null || { stop_watch; fail "the first pass woke for an answer already on the board"; }
  answer "$d" captains-pick "$(date +%s)"
  secs=$(wait_wake "$BOUND" "$d" 'captains-pick') || { stop_watch; fail "no wake within ${BOUND}s of the answer (waited $secs s)"; }
  stop_watch
  grep -q 'already-on-the-board' "$d/state/.wake-queue" && fail "the first-pass answer woke Main"
  [ -z "$LATENCY_LOG" ] || printf 'answer-to-wake seconds: %s (bound %s)\n' "$secs" "$BOUND" >> "$LATENCY_LOG"
  printf 'MEASURED answer-to-wake: %s s (bound %s s)\n' "$secs" "$BOUND"
  pass "an answer posted on a home nobody armed wakes Main in $secs s; the first pass stayed silent"
}

test_broken_registration_heals_and_answers_still_wake() {
  local d secs
  d=$(new_home heal)
  env JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" PATH="$d/fakebin:$PATH" SIGN_OFF_HOME="$d/so" "$BA" arm > /dev/null || fail "arm failed"
  registered "$d" || fail "arm left no registration"
  printf '# edited after it was bound\n' >> "$d/state/board-answers.check.sh"   # the bound bytes no longer match
  registered "$d" && fail "the edit did not break the registration"
  start_watch "$d"
  wait_for 40 registered "$d" || { stop_watch; fail "the broken registration was not re-armed"; }
  # The log line is written just after the registration verifies, so wait for it rather than race it.
  wait_for 10 grep -qs 're-armed: board-answers' "$d/state/board-answers.rearm.log" || { stop_watch; fail "the re-arm left no log line"; }
  answer "$d" after-heal "$(date +%s)"
  secs=$(wait_wake "$BOUND" "$d" 'after-heal') || { stop_watch; fail "no wake after the re-arm (waited $secs s)"; }
  stop_watch
  [ -z "$LATENCY_LOG" ] || printf 'negative control, broken registration: re-armed, then answer-to-wake %s s\n' "$secs" >> "$LATENCY_LOG"
  pass "a registration that no longer verifies is re-armed by the watcher; the next answer wakes in $secs s"
}

test_unfixable_registration_alerts_once_and_recovers() {
  local d secs
  d=$(new_home alert)
  env JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" PATH="$d/fakebin:$PATH" SIGN_OFF_HOME="$d/so" "$BA" arm > /dev/null || fail "arm failed"
  rm -f "$d/state/board-answers.check.sh"
  mkdir "$d/state/board-answers.check.sh"   # a directory where the shim goes: the re-arm cannot succeed
  start_watch "$d"
  secs=$(wait_wake "$BOUND" "$d" 'board-answers check is not registered and could not be re-armed') || { stop_watch; fail "a registration that cannot be re-armed stayed silent for ${BOUND}s"; }
  ack "$d"
  # Still broken: the same cause must not alert again.
  sleep 8
  ! grep -q 'could not be re-armed' "$d/state/.wake-queue" 2>/dev/null || { stop_watch; fail "the same unfixed cause alerted twice"; }
  rm -rf -- "$d/state/board-answers.check.sh"
  wait_for 40 registered "$d" || { stop_watch; fail "the check did not recover once the cause was removed"; }
  wait_for 10 test ! -e "$d/state/.board-answers-rearm-alert" || { stop_watch; fail "recovery left the alert latched"; }
  answer "$d" after-recovery "$(date +%s)"
  secs=$(wait_wake "$BOUND" "$d" 'after-recovery') || { stop_watch; fail "no wake after recovery (waited $secs s)"; }
  stop_watch
  [ -z "$LATENCY_LOG" ] || printf 'negative control, unfixable registration: alert raised, recovered, answer-to-wake %s s\n' "$secs" >> "$LATENCY_LOG"
  pass "an unfixable registration raises one alert naming the check, then recovers"
}

test_disarm_is_not_undone_by_the_watcher() {
  local d
  d=$(new_home disarm)
  env JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" PATH="$d/fakebin:$PATH" SIGN_OFF_HOME="$d/so" "$BA" arm > /dev/null || fail "arm failed"
  env JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" "$BA" disarm > /dev/null
  start_watch "$d"
  sleep 8
  stop_watch
  [ ! -e "$d/state/board-answers.check.sh" ] || fail "the watcher armed a check the captain disarmed"
  pass "a disarmed check stays disarmed"
}

test_no_board_stays_quiet_until_one_appears() {
  local d
  d=$(new_home noboard)
  rm -f "$d/so/.sign-off/decisions.json"
  start_watch "$d"
  sleep "$QUIET"
  [ ! -e "$d/state/board-answers.check.sh" ] || { stop_watch; fail "a home with no board was armed"; }
  ! grep -q 'board-answers' "$d/state/.wake-queue" 2>/dev/null || { stop_watch; fail "a home with no board woke Main: $(cat "$d/state/.wake-queue")"; }
  printf '{"schema":2,"items":[]}\n' > "$d/so/.sign-off/decisions.json"
  wait_for 40 registered "$d" || { stop_watch; fail "the check was not armed once the board appeared"; }
  stop_watch
  pass "a home with no board is neither armed nor woken, and arms itself once a board appears"
}

test_board_without_the_tool_alerts_once() {
  local d dir kept=''
  d=$(new_home notool)
  rm -f "$d/fakebin/sign-off-axi"
  while IFS= read -r dir; do
    [ -x "$dir/sign-off-axi" ] || kept=$kept${kept:+:}$dir
  done < <(printf '%s\n' "$PATH" | tr ':' '\n')
  WATCH_PATH=$kept start_watch "$d"
  wait_wake "$BOUND" "$d" 'sign-off-axi is not on PATH' > /dev/null || { stop_watch; fail "a board with no tool stayed silent"; }
  ack "$d"
  sleep "$QUIET"
  stop_watch
  ! grep -q 'sign-off-axi is not on PATH' "$d/state/.wake-queue" 2>/dev/null || fail "the missing tool alerted twice"
  pass "a board whose tool is missing raises one alert"
}

test_new_answer_wakes_within_the_bound_with_no_manual_arm
test_no_board_stays_quiet_until_one_appears
test_board_without_the_tool_alerts_once
test_broken_registration_heals_and_answers_still_wake
test_unfixable_registration_alerts_once_and_recovers
test_disarm_is_not_undone_by_the_watcher
