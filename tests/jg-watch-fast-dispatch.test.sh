#!/usr/bin/env bash
# tests/jg-watch-fast-dispatch.test.sh - the watcher's slow checks and timers run even while an old wake sits in the queue,
# no check is skipped because an earlier one woke, and dispatch starts every minute with a record of each pass.
# Runs the REAL watcher in a throwaway home: a farm of links to the real bin/ and core/, where the board-answers tick and the
# waiting-state timers tick are logging stand-ins, and the checks are trusted stand-ins (registered through the real
# bin/jg-check-register.sh) that append one line to a log per run. T3 runs the real dispatch.sh on one approved ticket.
set -u
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/watch-fast-dispatch.log")
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-watch-fast-dispatch)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
DISPATCH="$ROOT/core/auto-dispatch/dispatch.sh"

# new_home <name>: a case dir whose farm/ holds the watcher with the two stand-ins. Logs go to <dir>/log/.
new_home() {
  local d item farm
  d=$(make_case "$1")
  farm=$d/farm
  mkdir -p "$d/home/config" "$d/tmp" "$d/config" "$d/log" "$farm/bin" "$farm/core/wait-timers/bin"
  for item in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -e "$item" ] || continue
    case "${item##*/}" in bin|core) ;; *) ln -s "$item" "$farm/${item##*/}" ;; esac
  done
  for item in "$ROOT"/bin/* "$ROOT"/bin/.[!.]*; do
    [ -e "$item" ] || continue
    case "${item##*/}" in jg-board-answers.sh) ;; *) ln -s "$item" "$farm/bin/${item##*/}" ;; esac
  done
  for item in "$ROOT"/core/* "$ROOT"/core/.[!.]*; do
    [ -e "$item" ] || continue
    case "${item##*/}" in wait-timers) ;; *) ln -s "$item" "$farm/core/${item##*/}" ;; esac
  done
  for item in "$ROOT"/core/wait-timers/* "$ROOT"/core/wait-timers/.[!.]*; do
    [ -e "$item" ] || continue
    case "${item##*/}" in bin) ;; *) ln -s "$item" "$farm/core/wait-timers/${item##*/}" ;; esac
  done
  for item in "$ROOT"/core/wait-timers/bin/*; do
    case "${item##*/}" in jg-wait-timers-lib.sh) ;; *) ln -s "$item" "$farm/core/wait-timers/bin/${item##*/}" ;; esac
  done
  # The two stand-ins. The board-answers file must be a regular file: the fast tick refuses a link.
  printf '#!/usr/bin/env bash\ndate +%%s >> "%s/log/board"\nexit 0\n' "$d" > "$farm/bin/jg-board-answers.sh"
  chmod +x "$farm/bin/jg-board-answers.sh"
  printf 'jg_wait_timers_tick() { printf "tick\\n" >> "%s/log/timers"; }\n' "$d" > "$farm/core/wait-timers/bin/jg-wait-timers-lib.sh"
  printf '%s\n' "$d"
}

# add_check <dir> <id> <body>: write and register a trusted stand-in check.
add_check() {
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/state/$2.check.sh"
  chmod 700 "$1/state/$2.check.sh"
  env JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" "$ROOT/bin/jg-check-register.sh" "$2" > /dev/null \
    || fail "could not register the $2 check"
}

# A stand-in that logs one line per run: <epoch> run detached=<0|1>.
# shellcheck disable=SC2016 # the stand-in's own shell expands it
LOGGING='printf "%s run detached=%s\n" "$(date +%s)" "${JG_DISPATCH_DETACHED:-0}" >> '

# urgent_row <dir>: one routed-now row older than the stall time (the watcher re-delivers it and exits).
urgent_row() {
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$1/state/lane.meta"
  printf 'blocked [at=%s]: waiting on the writer\n' "$(date +%s)" > "$1/state/lane.status"
  prime_status_seen "$1/state" "$1/state/lane.status"
  append_wake "$1/state" signal lane.status "signal: $1/state/lane.status"
  # The queue's idle clock starts when a watcher first sees the row as the oldest, so look once, then let it age.
  JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" "$ROOT/bin/jg-bus.sh" watcher oldest > /dev/null
  sleep 2.5
}

# start_watch <dir> [VAR=value...]: one real watcher in the background; WPID is its pid. It exits on its first wake.
start_watch() {
  local d=$1
  shift
  env HOME="$d/home" XDG_CONFIG_HOME="$d/home/config" TMPDIR="$d/tmp" PATH="$d/fakebin:$PATH" \
    JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" JG_CONFIG_OVERRIDE="$d/config" \
    JG_POLL=0.2 JG_SIGNAL_GRACE=0 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS=99999999 JG_BUSY_TURN_MAX_SECS=999999 JG_STALE_ESCALATE_SECS=999999 \
    JG_SQUAD_LEAD_WAKE_STALL_SECS=1 JG_WATCH_HANDLING_SUCCESSOR=1 JG_FAKE_TMUX_WINDOWS=fake:1 \
    JG_CHECK_INTERVAL=999999 JG_FAST_CHECK_INTERVAL=999999 JG_DISPATCH_INTERVAL=60 "$@" \
    "$d/farm/bin/jg-watch.sh" > "$d/out" 2> "$d/err" &
  WPID=$!
}

# one_cycle <dir> [VAR=value...]: a watcher run to its first wake (the cycle exits on it).
one_cycle() {
  local rc=0
  start_watch "$@"
  wait_for_exit "$WPID" 100 || rc=$?
  case "$rc" in 0|124) ;; *) fail "the watcher failed (rc=$rc): $(cat "$1/err")" ;; esac
}

stop_watch() { kill "$WPID" 2> /dev/null; wait_for_exit "$WPID" 50 > /dev/null 2>&1 || true; }

lines_of() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# wait_lines <file> <count> <seconds>: until the file holds that many lines.
wait_lines() {
  local i=0
  while [ "$i" -lt $(($3 * 5)) ]; do
    [ "$(lines_of "$1")" -ge "$2" ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

# T1: a home whose queue holds one old urgent row starts the dispatch stand-in once before the cycle exits on that row.
t1_dispatch_starts_before_the_queue_exit() {
  local d
  d=$(new_home t1)
  touch "$d/state/.last-check"   # no sweep is due: only the fast tick can start the check
  add_check "$d" auto-dispatch "$LOGGING \"$d/log/dispatch\""
  urgent_row "$d"
  one_cycle "$d"
  grep -q 'lane.status' "$d/out" || fail "T1: the cycle did not exit on the queued row: $(cat "$d/out" "$d/err")"
  wait_lines "$d/log/dispatch" 1 5 || fail "T1: the dispatch stand-in did not run within 5 s"
  assert_equals 1 "$(lines_of "$d/log/dispatch")" "T1: the dispatch stand-in ran once"
  grep -q 'detached=1' "$d/log/dispatch" || fail "T1: the start must keep the pass's lead note for the sweep: $(cat "$d/log/dispatch")"
  pass "T1: the dispatch check starts once, detached, before the cycle exits on an old queued row"
}

# T2: two cycles 10 s apart with a 60 s interval start the stand-in once.
t2_interval_holds() {
  local d
  d=$(new_home t2)
  touch "$d/state/.last-check"
  add_check "$d" auto-dispatch "$LOGGING \"$d/log/dispatch\""
  urgent_row "$d"
  one_cycle "$d"
  wait_lines "$d/log/dispatch" 1 5 || fail "T2: the first cycle started no dispatch"
  sleep 10
  one_cycle "$d"
  sleep 1
  assert_equals 1 "$(lines_of "$d/log/dispatch")" "T2: a second cycle inside the interval starts no second pass"
  pass "T2: two cycles 10 s apart run the dispatch stand-in once"
}

# T3: the real dispatch.sh check writes one 7-field line for a pass.
t3_pass_line() {
  local d line n
  d=$TMP_ROOT/t3
  mkdir -p "$d/state" "$d/config" "$d/data"
  printf -- '- proj [local-trunk] - the one project (added 2026-11-01)\n' > "$d/data/projects.md"
  python3 - "$d" <<'PY'
import json, sys
d = sys.argv[1]
with open(d + "/export.jsonl", "w") as out:
    out.write(json.dumps({"id": "a1", "title": "[feature] row a1", "status": "open", "priority": 1, "issue_type": "task",
                          "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {}}) + "\n")
PY
  JG_HOME="$d" python3 "$ROOT/core/item-store/adapters/tickets.py" import --home main "$d/export.jsonl" > /dev/null || fail "the row did not import"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$d/hold"
  chmod +x "$d/hold"
  printf '1\n' > "$d/config/lane-target"
  touch "$d/state/.last-watcher-beat"
  env JG_HOME="$d" JG_AUTO_DISPATCH_HOLD="$d/hold" JG_AUTO_DISPATCH_BACKLOG="$ROOT/bin/jg-backlog.sh" \
    "$ROOT/bin/jg-backlog.sh" approve-dispatch a1 --harness claude --model sonnet --effort medium > /dev/null || fail "approve-dispatch was refused"
  mkdir -p "$d/data/a1"
  printf 'brief\n' > "$d/data/a1/brief.md"
  env JG_HOME="$d" JG_AUTO_DISPATCH_HOLD="$d/hold" JG_AUTO_DISPATCH_BACKLOG="$ROOT/bin/jg-backlog.sh" \
    bash "$DISPATCH" check "$d" > /dev/null || fail "the check failed"
  n=$(lines_of "$d/data/auto-dispatch/passes.tsv")
  assert_equals 1 "$n" "T3: one pass wrote exactly one line"
  line=$(cat "$d/data/auto-dispatch/passes.tsv")
  assert_equals 7 "$(printf '%s\n' "$line" | awk -F'\t' '{ print NF }')" "T3: the line has 7 fields"
  assert_equals "pass" "$(printf '%s\n' "$line" | cut -f2)" "T3: the second field names the line"
  assert_equals 1 "$(printf '%s\n' "$line" | cut -f3)" "T3: one candidate"
  assert_equals off "$(printf '%s\n' "$line" | cut -f7)" "T3: the switch is off"
  # The file keeps its last 5000 lines.
  awk 'BEGIN { for (i = 1; i <= 5000; i++) printf "%d\tpass\t0\t0\t0\t0\toff\n", i }' > "$d/data/auto-dispatch/passes.tsv"
  env JG_HOME="$d" JG_AUTO_DISPATCH_HOLD="$d/hold" JG_AUTO_DISPATCH_BACKLOG="$ROOT/bin/jg-backlog.sh" \
    bash "$DISPATCH" check "$d" > /dev/null || fail "the second check failed"
  assert_equals 5000 "$(lines_of "$d/data/auto-dispatch/passes.tsv")" "T3: the file is kept to 5000 lines"
  assert_equals 2 "$(head -n 1 "$d/data/auto-dispatch/passes.tsv" | cut -f1)" "T3: the oldest line went first"
  pass "T3: a pass writes one 7-field line and the file keeps its last 5000"
}

# T4: a sweep still runs the dispatch stand-in inline once and queues its line.
t4_sweep_runs_dispatch_inline() {
  local d
  d=$(new_home t4)
  add_check "$d" auto-dispatch "$LOGGING \"$d/log/dispatch\"; echo 'auto-dispatch: lead, a ticket failed to start'"
  one_cycle "$d" JG_CHECK_INTERVAL=1
  grep -q 'auto-dispatch: lead, a ticket failed to start' "$d/out" || fail "T4: the sweep did not deliver the pass's line: $(cat "$d/out" "$d/err")"
  grep -q 'a ticket failed to start' "$d/state/.wake-queue" || fail "T4: the pass's line was not queued"
  wait_lines "$d/log/dispatch" 2 5 || fail "T4: want one detached run and one inline run, got $(lines_of "$d/log/dispatch")"
  assert_equals 1 "$(grep -c 'detached=0' "$d/log/dispatch")" "T4: the sweep ran the check inline once"
  pass "T4: the sweep runs the dispatch check inline once and queues its line"
}

# T5: an overdue sweep and the timers tick run before the cycle exits on an old queued row.
t5_overdue_sweep_runs_first() {
  local d
  d=$(new_home t5)
  add_check "$d" a-first "$LOGGING \"$d/log/a\""
  add_check "$d" z-last "$LOGGING \"$d/log/z\""
  jg_touch_epoch $(($(date +%s) - 1200)) "$d/state/.last-check"
  urgent_row "$d"
  one_cycle "$d" JG_CHECK_INTERVAL=300
  grep -q 'lane.status' "$d/out" || fail "T5: the cycle did not exit on the queued row: $(cat "$d/out" "$d/err")"
  assert_equals 1 "$(lines_of "$d/log/a")" "T5: a-first ran"
  assert_equals 1 "$(lines_of "$d/log/z")" "T5: z-last ran"
  assert_equals 1 "$(lines_of "$d/log/timers")" "T5: the timers tick ran"
  pass "T5: an overdue sweep and the timers tick run before the cycle exits on an old queued row"
}

# T6: a check that wakes ends the sweep once; the next cycle continues after it, never at the first check again.
t6_cursor() {
  local d i=0
  d=$(new_home t6)
  add_check "$d" a-wakes "$LOGGING \"$d/log/a\"; echo 'check: a-wakes failed with news'"
  add_check "$d" b-quiet "$LOGGING \"$d/log/b\""
  add_check "$d" c-quiet "$LOGGING \"$d/log/c\""
  one_cycle "$d" JG_CHECK_INTERVAL=300
  assert_equals 1 "$(lines_of "$d/log/a")" "T6: the first sweep ran a-wakes"
  assert_equals 0 "$(lines_of "$d/log/b")" "T6: the first sweep ended on a-wakes"
  assert_equals b-quiet.check.sh "$(cat "$d/state/.check-cursor" 2> /dev/null)" "T6: the cursor names the next check"
  assert_equals "" "$(ls "$d/state/.last-check" 2> /dev/null)" "T6: the sweep that did not finish leaves no stamp"
  # The next cycle finishes the sweep quietly, so it does not exit: stop it once the sweep is stamped.
  start_watch "$d" JG_CHECK_INTERVAL=300
  while [ "$i" -lt 100 ] && [ ! -e "$d/state/.last-check" ]; do sleep 0.1; i=$((i + 1)); done
  stop_watch
  assert_equals 1 "$(lines_of "$d/log/b")" "T6: the next cycle ran b-quiet"
  assert_equals 1 "$(lines_of "$d/log/c")" "T6: the next cycle ran c-quiet"
  assert_equals 1 "$(lines_of "$d/log/a")" "T6: the next cycle did not run a-wakes again"
  [ -e "$d/state/.last-check" ] || fail "T6: the finished sweep did not stamp .last-check"
  [ ! -e "$d/state/.check-cursor" ] || fail "T6: the finished sweep left its cursor"
  jg_touch_epoch $(($(date +%s) - 700)) "$d/state/.last-check"   # more than two intervals late: the sweep runs before the queue resurface
  start_watch "$d" JG_CHECK_INTERVAL=300
  wait_lines "$d/log/a" 2 10
  stop_watch
  assert_equals 2 "$(lines_of "$d/log/a")" "T6: the sweep after that starts at a-wakes again"
  pass "T6: a woken sweep resumes after the check that woke, then starts over"
}

# T7: a dispatch pass that takes 25 s holds nothing: the board-answers tick keeps its cadence.
t7_slow_dispatch_does_not_wait() {
  local d first second gap
  d=$(new_home t7)
  touch "$d/state/.last-check"   # no sweep is due: it would run the slow stand-in inline
  # The stand-in runs until the test says stop (at most 25 s), then writes its end mark.
  add_check "$d" auto-dispatch "$LOGGING \"$d/log/dispatch\"; i=0; while [ ! -e \"$d/log/stop\" ] && [ \$i -lt 125 ]; do sleep 0.2; i=\$((i + 1)); done; touch \"$d/log/end\""
  start_watch "$d" JG_FAST_CHECK_INTERVAL=2
  wait_lines "$d/log/board" 2 15 || { touch "$d/log/stop"; stop_watch; fail "T7: the board-answers tick ran $(lines_of "$d/log/board") times in 15 s"; }
  first=$(sed -n 1p "$d/log/board")
  second=$(sed -n 2p "$d/log/board")
  gap=$((second - first))
  [ "$(lines_of "$d/log/dispatch")" -ge 1 ] && [ ! -e "$d/log/end" ]; ended=$?
  touch "$d/log/stop"
  stop_watch
  [ "$gap" -le 7 ] || fail "T7: the second board-answers tick came $gap s after the first (want 7 s at most)"
  [ "$ended" -eq 0 ] || fail "T7: the slow dispatch stand-in did not start, or ended before the check"
  pass "T7: a slow dispatch pass does not hold the board-answers tick ($gap s between ticks)"
}

t1_dispatch_starts_before_the_queue_exit
t2_interval_holds
t3_pass_line
t4_sweep_runs_dispatch_inline
t5_overdue_sweep_runs_first
t6_cursor
t7_slow_dispatch_does_not_wait
