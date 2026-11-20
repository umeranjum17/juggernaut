#!/usr/bin/env bash
# Integration test for the status append's kick: a worker's `done` line (bin/jg-lavish-guard.sh --append) starts the home's
# delivery pass (bin/jg-delivery-tick.sh) at once, and a line that frees the lane (done, paused, blocked, needs-decision,
# failed) starts the home's dispatch at once when auto-dispatch is on, so neither waits for its own beat. Built from the
# measured wait of 19-20 Nov: a ready lane waited a median 212 s before the lander saw it.
# Each case runs the real guard command the generated brief gives a worker against a scratch home with a ship lane record;
# the tick and the dispatch shim are stand-ins that append one line to a log (JG_STATUS_KICK_TICK, JG_STATUS_KICK_DISPATCH).
#
# T1 A done line is written and the tick starts with the home, with the kick mark in its environment.
# T2 With auto-dispatch on, a paused line starts the dispatch and not the tick; a done line starts both.
# T3 A working line starts neither; auto-dispatch off leaves only the tick for a done line; JG_STATUS_KICK=0 starts neither.
# T4 The append wins: a tick that exits 1 and a dispatch that is missing never fail the append or put a word on its output.
# T5 A kicked tick that finds the pass running leaves state/.delivery-tick.again and exits 0 at once; an unkicked call leaves none.
# T6 A kick that lands while a pass runs makes that pass, when it ends, start exactly one more and leaves no mark.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/jg-lavish-guard.sh"
TICK="$ROOT/bin/jg-delivery-tick.sh"
TMP_ROOT=$(jg_test_tmproot jg-status-kick)
ID=lane-one

# home <name>: a scratch home with one ship lane record (not local-trunk, so the done proof check does not apply),
# and stand-ins that log one line each. Sets HOME_D, LOG.
home() {
  HOME_D="$TMP_ROOT/$1"; LOG="$HOME_D/kick.log"
  mkdir -p "$HOME_D/state" "$HOME_D/config" "$HOME_D/data"
  jg_write_meta "$HOME_D/state/$ID.meta" "mode=direct-pr" "worktree=$HOME_D/none" "spawn_gen=g-$ID"
  # shellcheck disable=SC2016 # the stand-in expands its own arguments
  printf '#!/usr/bin/env bash\nprintf "kick %%s kick=%%s\\n" "$1" "${JG_DELIVERY_TICK_KICK:-}" >> %q\n' "$LOG" > "$HOME_D/tick-standin"
  printf '#!/usr/bin/env bash\nprintf "dispatch\\n" >> %q\n' "$LOG" > "$HOME_D/dispatch-standin"
  chmod +x "$HOME_D/tick-standin" "$HOME_D/dispatch-standin"
  : > "$LOG"
}

# append <line> [<env>...]: the worker's status command with the stand-ins in place; sets RC, OUT (stdout and stderr).
append() {
  local line=$1; shift
  RC=0
  OUT=$(printf '%s\n' "$line" | env -u JG_HOME -u JG_STATE_OVERRIDE -u JG_DATA_OVERRIDE \
    JG_STATUS_KICK_TICK="$HOME_D/tick-standin" JG_STATUS_KICK_DISPATCH="$HOME_D/dispatch-standin" "$@" \
    bash "$GUARD" --append "$HOME_D/state/$ID.status" 2>&1) || RC=$?
}
# no_kick_words: the kick prints nothing; the guard's own warning for a ship lane's done (the proof check does not apply) is all there is.
no_kick_words() { case $OUT in *kick=*|*dispatch*|*standin*|*delivery-tick*) fail "the kick put a word on the output: $OUT" ;; esac; }
# wait_log <pattern> <count>: wait up to 5 s for the log to hold <count> lines matching <pattern>.
wait_log() {
  for _ in $(seq 1 50); do
    [ "$(grep -c -- "$1" "$LOG")" -ge "$2" ] && return 0
    sleep 0.1
  done
  return 1
}
# settle: long enough for a kick that should NOT happen to have shown itself.
settle() { sleep 1; }
count() { grep -c -- "$1" "$LOG" || true; }

test_a_done_line_starts_the_delivery_pass() {
  home t1
  append "done [at=$(date +%s)]: ready in branch x"
  [ "$RC" = 0 ] || fail "the append must exit 0: rc=$RC $OUT"
  no_kick_words
  grep -q '^done \[at=' "$HOME_D/state/$ID.status" || fail "the done line is not in the status file"
  wait_log "kick $HOME_D" 1 || fail "the tick stand-in was not started with the home within 5 s: $(cat "$LOG")"
  assert_contains "$(cat "$LOG")" "kick=1" "the tick is started with the kick mark"
  pass 'a done line is written and starts the delivery pass with the home, detached, within seconds'
}

test_a_freed_lane_starts_dispatch() {
  home t2
  printf 'on\n' > "$HOME_D/config/auto-dispatch"
  append "paused [at=$(date +%s)] [wait=outside] [reason=ci]: waiting for a check"
  [ "$RC" = 0 ] || fail "a paused line was refused: $OUT"
  wait_log '^dispatch' 1 || fail "a paused line did not start the dispatch: $(cat "$LOG")"
  settle
  [ "$(count '^kick')" = 0 ] || fail "a paused line started the tick: $(cat "$LOG")"
  : > "$LOG"
  append "done [at=$(date +%s)]: ready in branch x"
  [ "$RC" = 0 ] || fail "a done line was refused: $OUT"
  wait_log '^dispatch' 1 || fail "a done line must start the dispatch: $(cat "$LOG")"
  wait_log '^kick' 1 || fail "a done line must start the tick: $(cat "$LOG")"
  pass 'with auto-dispatch on, a paused line starts the dispatch only; a done line starts the tick and the dispatch'
}

test_nothing_else_starts_a_kick() {
  home t3
  printf 'on\n' > "$HOME_D/config/auto-dispatch"
  append "working [at=$(date +%s)]: setup complete"
  [ "$RC" = 0 ] || fail "a working line was refused: $OUT"
  settle
  [ ! -s "$LOG" ] || fail "a working line started something: $(cat "$LOG")"
  printf 'off\n' > "$HOME_D/config/auto-dispatch"
  append "done [at=$(date +%s)]: ready in branch x"
  wait_log '^kick' 1 || fail "a done line must start the tick with dispatch off"
  settle
  [ "$(count '^dispatch')" = 0 ] || fail "dispatch off, yet the dispatch started: $(cat "$LOG")"
  : > "$LOG"
  printf 'on\n' > "$HOME_D/config/auto-dispatch"
  append "done [at=$(date +%s)]: ready in branch x" JG_STATUS_KICK=0
  [ "$RC" = 0 ] || fail "the append failed with the kick off: $OUT"
  settle
  [ ! -s "$LOG" ] || fail "JG_STATUS_KICK=0 still started something: $(cat "$LOG")"
  : > "$LOG"
  append "done [at=$(date +%s)]: first
done [at=$(date +%s)]: second"
  wait_log '^kick' 1 || fail "a two-line text must start the tick"
  settle
  [ "$(count '^kick')" = 1 ] && [ "$(count '^dispatch')" = 1 ] || fail "a text of two lines must start one of each: $(cat "$LOG")"
  pass 'a working line, dispatch off, and JG_STATUS_KICK=0 start only what they should; a two-line text starts one of each'
}

test_the_append_wins_over_a_failed_kick() {
  home t4
  printf 'on\n' > "$HOME_D/config/auto-dispatch"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$HOME_D/tick-standin"
  rm -f "$HOME_D/dispatch-standin"
  append "done [at=$(date +%s)]: ready in branch x"
  [ "$RC" = 0 ] || fail "a failing tick or a missing dispatch must not touch the append: rc=$RC $OUT"
  no_kick_words
  grep -q '^done \[at=' "$HOME_D/state/$ID.status" || fail "the done line is not in the status file"
  pass 'a tick that exits 1 and a missing dispatch leave the append at exit 0 with the line written and no output'
}

# hold_lock <home> <secs>: another runner holds the home's pass lock for <secs> seconds.
hold_lock() {
  bash -c '. "$1/bin/jg-wake-lib.sh"; jg_lock_try_acquire "$2/state/.delivery-tick.lock" && { sleep "$3"; jg_lock_release "$2/state/.delivery-tick.lock"; }' \
    _ "$ROOT" "$1" "$2" &
  for _ in $(seq 1 50); do [ -e "$1/state/.delivery-tick.lock" ] && return 0; sleep 0.1; done
  fail "the lock holder did not start"
}

test_a_kick_that_finds_the_pass_running_leaves_the_mark() {
  home t5
  hold_lock "$HOME_D" 3
  RC=0; JG_DELIVERY_TICK_KICK=1 bash "$TICK" "$HOME_D" >/dev/null 2>&1 || RC=$?
  [ "$RC" = 0 ] || fail "a kicked tick must exit 0 while the pass runs: $RC"
  [ -e "$HOME_D/state/.delivery-tick.again" ] || fail "a kicked tick left no .delivery-tick.again"
  wait
  rm -f "$HOME_D/state/.delivery-tick.again"
  hold_lock "$HOME_D" 3
  bash "$TICK" "$HOME_D" >/dev/null 2>&1 || true
  [ ! -e "$HOME_D/state/.delivery-tick.again" ] || fail "an unkicked call must never leave the mark"
  wait
  pass 'a kicked tick finds the pass running, leaves .delivery-tick.again and exits 0; an unkicked call leaves none'
}

# A pass slowed down by one stand-in step (a copy of bin made of links, so the tick still finds its core), so a kick can land
# while it runs.
test_a_marked_pass_starts_exactly_one_more() {
  local f slow="$TMP_ROOT/slow-root"
  home t6
  mkdir -p "$slow/bin"; ln -sn "$ROOT/core" "$slow/core"
  for f in "$ROOT"/bin/*; do ln -sn "$f" "$slow/bin/$(basename "$f")"; done
  rm -f "$slow/bin/jg-ready-trace.sh"; printf '#!/usr/bin/env bash\nsleep 2\n' > "$slow/bin/jg-ready-trace.sh"
  export JG_DELIVERY_TICK_TRACE="$HOME_D/trace"
  bash "$slow/bin/jg-delivery-tick.sh" "$HOME_D" >/dev/null 2>&1 &
  for _ in $(seq 1 50); do [ -s "$HOME_D/trace" ] && break; sleep 0.1; done
  [ -s "$HOME_D/trace" ] || fail "the first pass did not start"
  JG_DELIVERY_TICK_KICK=1 bash "$slow/bin/jg-delivery-tick.sh" "$HOME_D" >/dev/null 2>&1 || fail "the kicked call must exit 0"
  [ -e "$HOME_D/state/.delivery-tick.again" ] || fail "the kick left no mark while the first pass ran"
  for _ in $(seq 1 100); do [ "$(wc -l < "$HOME_D/trace")" -ge 2 ] && break; sleep 0.1; done
  [ "$(wc -l < "$HOME_D/trace")" -ge 2 ] || fail "the marked pass started no second pass within 10 s: $(cat "$HOME_D/trace")"
  sleep 4
  [ "$(wc -l < "$HOME_D/trace")" = 2 ] || fail "exactly two passes expected, the mark must not repeat: $(cat "$HOME_D/trace")"
  [ ! -e "$HOME_D/state/.delivery-tick.again" ] || fail "the mark was not removed"
  unset JG_DELIVERY_TICK_TRACE
  wait
  pass 'a pass that ends with the mark present removes it and starts exactly one more pass'
}

test_a_done_line_starts_the_delivery_pass
test_a_freed_lane_starts_dispatch
test_nothing_else_starts_a_kick
test_the_append_wins_over_a_failed_kick
test_a_kick_that_finds_the_pass_running_leaves_the_mark
test_a_marked_pass_starts_exactly_one_more
printf 'jg-status-kick: ok\n'
