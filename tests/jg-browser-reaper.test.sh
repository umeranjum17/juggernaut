#!/usr/bin/env bash
# Behavior tests for bin/jg-reaper-lib.sh - the deterministic stale test-browser reaper and
# the machine load alarm. A process is stopped only when all three conditions hold, so this
# pins the matrix over real stub processes where a real SIGTERM lands: a day-old orphaned
# browser in a fleet temp root is stopped, and the same browser when fresh, under the
# captain's own profile, or with a live owning worker is left alone. Then the job-ended
# owner signal (a live launcher left in a heavy job's ended scope) with its keep cases, over
# fixture rows and, where a systemd user manager runs, a real transient scope. Then its stop
# log and fleet event, the off switch, the real /proc scanner, and the load alarm.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

home=$(jg_test_tmproot jg-browser-reaper)
state=$home/home/state config=$home/home/config roots=$home/tmp
mkdir -p "$state" "$config" "$roots/jg-stale/chrome"
export JG_HOME=$home/home JG_STATE_OVERRIDE=$state JG_CONFIG_OVERRIDE=$config JG_TEST_SEAM=1
unset JG_TASK_ID # a stub must name a task only where a case says so, never the lane running this suite
# shellcheck source=/dev/null
. "$ROOT/bin/jg-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/jg-reaper-lib.sh"
log=$state/browser-reaper.log table=$home/ps.tsv
export JG_REAPER_PS=$table
printf '%s\n' "$roots" >"$config/reaper-roots"

# Every stub this suite starts, so a failure cannot leave a process holding a pipe open;
# tests/lib.sh owns the temp-root cleanup this chains to.
pids=()
cleanup() { local p; if [ "${#pids[@]}" -gt 0 ]; then for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null || true; done; fi; jg_test_cleanup; }
trap cleanup EXIT INT TERM
wakes() { [ -f "$JG_WAKE_QUEUE" ] && wc -l <"$JG_WAKE_QUEUE" | tr -d ' ' || printf '0\n'; }
alive() { kill -0 "$1" 2>/dev/null; }
row() { printf '%s\t%s\t%s\tchrome\t%s\n' "$1" "$2" "$3" "${4:-$roots/jg-stale/chrome}"; }

# A pid that has exited and been reaped: the worker that owned the folder, gone.
bash -c 'exit 0' &
dead=$!
wait "$dead" 2>/dev/null || true
[ ! -d "/proc/$dead" ] || fail "fixture: $dead is still alive"

sleep 60 >/dev/null 2>&1 & stop=$! pids+=("$stop")
sleep 60 >/dev/null 2>&1 & fresh=$! pids+=("$fresh")
sleep 60 >/dev/null 2>&1 & captain=$! pids+=("$captain")
sleep 60 >/dev/null 2>&1 & owned=$! pids+=("$owned")
{
  row "$stop" 90000 "$dead"
  row "$fresh" 60 "$dead"
  row "$captain" 90000 "$dead" "$HOME/.config/chromium/Default"
  row "$owned" 90000 "$$"
} >"$table"
before=$(wakes)
jg_reaper_sweep; sleep 0.2
alive "$stop" && fail "a day-old orphaned browser in a fleet temp root must be stopped"
pass "a day-old orphaned browser in a fleet temp root is stopped"
for kept in "$fresh" "$captain" "$owned"; do
  alive "$kept" || fail "the fresh, captain-profile and live-worker browsers must all be left alone"
done
pass "the fresh, captain-profile and live-worker browsers are left alone"
assert_grep "stopped pid=$stop age=90000s profile=$roots/jg-stale/chrome" "$log" "the stop log names pid, age and profile"
assert_grep "owning-worker-gone" "$log" "the stop log names the reason"
assert_no_grep "pid=$captain" "$log" "the captain's own profile never reaches the log"
assert_equals "$((before + 1))" "$(wakes)" "a sweep that stopped something posts exactly one fleet event"
assert_grep "browser reaper stopped 1 stale test browsers" "$JG_WAKE_QUEUE" "the fleet event names the stop count"
assert_equals "check browser-reaper" "$(tail -1 "$JG_WAKE_QUEUE" | cut -f3,4 | tr '\t' ' ')" "the fleet event is a check row keyed browser-reaper"
kill "$fresh" "$captain" "$owned" 2>/dev/null || true

# The leak seen on the host: a heavy job (systemd-run scope run-p<main>-i<n>) ended,
# but the launcher daemon it started stayed alive in the scope, so the browser's
# parent is live for days. The job's main pid is the owner, and its leaving the
# scope says the job is over. A job still running, a task whose record still exists,
# a profile outside every fleet root and a browser's own child are all left alone.
row6() { printf '%s\t%s\t%s\tchrome\t%s\t%s\n' "$1" "$2" "$3" "${5:-$roots/jg-job/chrome}" "$4"; }
if ! grep -q '^0::/' "/proc/$$/cgroup" 2>/dev/null; then
  printf 'SKIP job-ended matrix: this host has no unified cgroup to scope a job by\n'
else
  mkdir -p "$home/other/state"
  : >"$home/other/state/t-live.meta"
  sleep 60 >/dev/null 2>&1 & ended=$! pids+=("$ended")
  sleep 60 >/dev/null 2>&1 & running=$! pids+=("$running")
  JG_TASK_ID=t-live JG_HOME=$home/other JG_STATE_OVERRIDE='' sleep 60 >/dev/null 2>&1 & tasklive=$! pids+=("$tasklive")
  JG_TASK_ID=t-gone JG_HOME=$home/other JG_STATE_OVERRIDE='' sleep 60 >/dev/null 2>&1 & taskgone=$! pids+=("$taskgone")
  sleep 60 >/dev/null 2>&1 & outside=$! pids+=("$outside")
  sleep 60 >/dev/null 2>&1 & young=$! pids+=("$young")
  sleep 60 >/dev/null 2>&1 & child=$! pids+=("$child")
  {
    row6 "$ended" 90000 "$$" "$dead"
    row6 "$running" 90000 "$$" "$$" "$roots/jg-job/running"
    row6 "$tasklive" 90000 "$$" "$dead" "$roots/jg-job/task-live"
    row6 "$taskgone" 90000 "$$" "$dead" "$roots/jg-job/task-gone"
    row6 "$outside" 90000 "$$" "$dead" "$home/elsewhere/chrome"
    row6 "$young" 60 "$$" "$dead" "$roots/jg-job/young"
    row6 "$child" 90000 "$young" "$dead" "$roots/jg-job/young"
  } >"$table"
  : >"$log"
  jg_reaper_sweep; sleep 0.2
  alive "$ended" && fail "an old fleet browser whose job ended must be stopped though its launcher lives"
  alive "$taskgone" && fail "a browser naming a task with no record must be stopped once its job ended"
  pass "an old fleet browser whose job ended is stopped though its launcher lives"
  assert_grep "stopped pid=$ended age=90000s profile=$roots/jg-job/chrome reason=age-over-21600s,fleet-profile-root,job-ended" "$log" \
    "the stop log names the ended job as the reason"
  for kept in "$running" "$tasklive" "$outside" "$young" "$child"; do
    alive "$kept" || fail "pid $kept (a running job, a live task, an outside profile, a young browser or its child) must be left alone"
  done
  pass "a running job, a live task, an outside profile, a young browser and its child are left alone"
  assert_equals 2 "$(grep -c 'stopped pid=' "$log")" "exactly the two abandoned browsers reach the stop log"
  kill "$running" "$tasklive" "$outside" "$young" "$child" 2>/dev/null || true
fi

# The real scanner over a real systemd-run scope, where a user manager runs one: the
# scope's main exits at once and leaves a launcher holding a browser, as the memory
# gate's jobs do. The table must name that main pid as the browser's job, and the
# sweep must stop the browser once it is old (only the age is supplied).
if command -v systemd-run >/dev/null 2>&1 && systemd-run --user --scope --quiet --collect -- true >/dev/null 2>&1; then
  # launcher.sh <profile> <browser-pid-file> <launcher-pid-file>: holds a browser, outlives main.
  cat >"$home/launcher.sh" <<'LAUNCHER'
#!/usr/bin/env bash
bash -c 'while :; do sleep 1; done' jg-reaper-scope-browser --user-data-dir="$1" &
echo "$!" >"$2"
echo "$$" >"$3"
wait
LAUNCHER
  # main.sh <launcher> <profile> <browser-pid-file> <main-pid-file> <launcher-pid-file>: the job.
  cat >"$home/main.sh" <<'MAIN'
#!/usr/bin/env bash
echo "$$" >"$4"
"$1" "$2" "$3" "$5" >/dev/null 2>&1 &
exit 0
MAIN
  chmod +x "$home/launcher.sh" "$home/main.sh"
  systemd-run --user --scope --quiet --collect -- "$home/main.sh" "$home/launcher.sh" "$roots/jg-scope/chrome" \
    "$home/browser.pid" "$home/main.pid" "$home/launcher.pid" >/dev/null 2>&1
  for _ in $(seq 50); do [ -s "$home/browser.pid" ] && [ -s "$home/launcher.pid" ] && break; sleep 0.1; done
  sbrowser=$(cat "$home/browser.pid" 2>/dev/null) slauncher=$(cat "$home/launcher.pid" 2>/dev/null) smain=$(cat "$home/main.pid" 2>/dev/null)
  pids+=("$sbrowser" "$slauncher")
  unset JG_REAPER_PS
  scope_row=$(jg_reaper_table | awk -F'\t' -v p="$sbrowser" '$1 == p')
  export JG_REAPER_PS=$table
  assert_equals "$smain" "$(cut -f6 <<<"$scope_row")" "the real scanner names the scope's main pid as the browser's job"
  alive "$slauncher" || fail "fixture: the launcher must outlive the scope's main"
  awk -F'\t' 'BEGIN { OFS = FS } { $2 = 90000; print }' <<<"$scope_row" >"$table"
  : >"$log"
  jg_reaper_sweep; sleep 0.3
  alive "$sbrowser" && fail "a real scope's browser must be stopped once its job ended"
  assert_grep "stopped pid=$sbrowser age=90000s profile=$roots/jg-scope/chrome reason=age-over-21600s,fleet-profile-root,job-ended" "$log" \
    "the real scope's browser is stopped as job-ended"
  pass "a real systemd-run scope whose job ended has its browser stopped while the launcher lives"
  kill "$slauncher" 2>/dev/null || true
else
  printf 'SKIP real scope: no systemd user manager to start a transient scope\n'
fi

# Nothing eligible, then the off switch through the public entry point.
{ row "$$" 90000 "$$"; row "$$" 10 "$dead"; } >"$table"
before=$(wakes)
jg_reaper_sweep
assert_equals "$before" "$(wakes)" "a sweep that stopped nothing posts no event"
sleep 60 >/dev/null 2>&1 & off=$! pids+=("$off")
row "$off" 90000 "$dead" >"$table"
: >"$config/reaper-off"
jg_reaper_tick; sleep 0.2
alive "$off" || fail "config/reaper-off must stop every stop"
pass "config/reaper-off leaves even an eligible browser alone"
rm -f "$config/reaper-off"; jg_reaper_tick; sleep 0.2
alive "$off" && fail "the tick must run the sweep once reaper-off is gone"

# The real scanner: a live process whose own argv carries the profile token.
unset JG_REAPER_PS
bash -c 'while :; do sleep 1; done' jg-reaper-real --user-data-dir="$roots/jg-real/chrome" >/dev/null 2>&1 &
real=$! pids+=("$real")
sleep 0.3
real_row=$(jg_reaper_table | awk -F'\t' -v p="$real" '$1 == p')
assert_contains "$real_row" "$roots/jg-real/chrome" "the real scanner reads --user-data-dir from argv"
real_age=$(cut -f2 <<<"$real_row")
case $real_age in '' | *[!0-9]*) fail "the real scanner reports a numeric age (got '$real_age')" ;; esac
[ "$real_age" -lt 60 ] || fail "the real scanner reports the process age (got ${real_age}s)"
pass "the real scanner reports each process age and profile"

kill "$real" 2>/dev/null || true

# The load alarm: one sample is not an episode; ten minutes of them is one wake.
printf '999.0 900.0 800.0 1/1 42\n' >"$home/load-high"
printf '0.10 0.10 0.10 1/1 42\n' >"$home/load-low"
export JG_REAPER_LOADAVG=$home/load-high JG_REAPER_PS=$table
{
  for _ in 1 2 3; do row "$$" 90000 "$dead"; done
  printf '%s\t90000\t%s\tnode\t%s\n' "$$" "$dead" "$roots/jg-stale/chrome"
} >"$table"
before=$(wakes); jg_reaper_load_alarm
assert_present "$state/.browser-reaper-load" "a load above the limit starts an episode"
assert_equals "$before" "$(wakes)" "the first high sample raises nothing"
printf '%s\n' "$(($(date +%s) - 700))" >"$state/.browser-reaper-load"; jg_reaper_load_alarm
assert_equals "$((before + 1))" "$(wakes)" "ten minutes above the limit posts exactly one wake"
assert_grep "machine load 999.0" "$JG_WAKE_QUEUE" "the load event names the load"
assert_grep "chrome 3 (oldest" "$JG_WAKE_QUEUE" "the load event names the top process group by count and age"
jg_reaper_load_alarm; assert_equals "$((before + 1))" "$(wakes)" "one wake per episode, not one per sample"
JG_REAPER_LOADAVG=$home/load-low jg_reaper_load_alarm
assert_absent "$state/.browser-reaper-load" "a load back under the limit ends the episode"
pass "the load alarm raises one wake per ten-minute episode"

# Machine load is one host fact, so its one owner is the main home: a lead home under
# the same load gets no wake, while its own stale-browser stop still wakes it. Run
# through the watcher's tick in a separate process, as a lead's own watcher would.
lead=$home/lead
mkdir -p "$lead/state" "$lead/config"
printf 'growthmap\n' >"$lead/.jg-squad-lead-home"
printf '%s\n' "$roots" >"$lead/config/reaper-roots"
printf '%s\n' "$(($(date +%s) - 700))" >"$lead/state/.browser-reaper-load"
sleep 60 >/dev/null 2>&1 & lead_stale=$! pids+=("$lead_stale")
row "$lead_stale" 90000 "$dead" >"$home/lead-ps.tsv"
JG_HOME=$lead JG_STATE_OVERRIDE=$lead/state JG_CONFIG_OVERRIDE=$lead/config STATE='' CONFIG='' \
  JG_WAKE_QUEUE='' JG_REAPER_PS=$home/lead-ps.tsv JG_REAPER_LOADAVG=$home/load-high \
  bash -c '. "$1/bin/jg-wake-lib.sh"; . "$1/bin/jg-reaper-lib.sh"; jg_reaper_tick' _ "$ROOT"
sleep 0.2
assert_no_grep "machine load" "$lead/state/.wake-queue" "a lead home gets no wake for the host load"
assert_absent "$lead/state/.browser-reaper-load.raised" "a lead home raises no load episode"
alive "$lead_stale" && fail "the lead's own sweep must still stop its stale browser"
assert_grep "browser reaper stopped 1 stale test browsers" "$lead/state/.wake-queue" "a lead's own stop still wakes the lead"
pass "the host load wakes the main home only; a lead's own alert still wakes the lead"

printf 'PASS jg-browser-reaper\n'
