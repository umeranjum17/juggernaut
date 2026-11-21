#!/usr/bin/env bash
# tests/jg-auto-dispatch-retry.test.sh - the dispatch check (core/auto-dispatch/dispatch.sh) runs one pass at a time per
# home, and a start the spawn defers (exit 75) is tried again in seconds, not on the next 300 s beat.
# Journey: a home whose backlog, spawn, captain-hold and project-mode commands are stand-ins (JG_AUTO_DISPATCH_*), with the
# switch on. T1 retry, T2 retry off, T3 one pass at a time, T4 a mark made while the holder releases, T5 one retry per
# home, T6 marks made during the third pass.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-auto-dispatch-retry)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
CHECK="$ROOT/core/auto-dispatch/dispatch.sh"

# make_home <dir> <lane-target> <ticket>...: the home, the stand-ins and one approved ticket with a brief for each id.
# The backlog stand-in counts its `ready --spawnable` calls (one a pass) in backlog.calls and sleeps $BACKLOG_SLEEP seconds.
# The spawn stand-in counts its calls per task in spawn.<task>; its exit is 75 while the count is at most
# `defer-<task>` (a number kept in a file), else it publishes the lane record state/<task>.meta and exits 0.
make_home() {
  local d=$1 lanes=$2 id
  shift 2
  mkdir -p "$d/state/dispatch-approved" "$d/config" "$d/data/auto-dispatch"
  printf 'on\n' > "$d/config/auto-dispatch"
  printf '%s\n' "$lanes" > "$d/config/lane-target"
  cat > "$d/backlog" <<'SH'
#!/usr/bin/env bash
here=$(cd "$(dirname "$0")" && pwd)
[ "$1 $2" = "ready --spawnable" ] || exit 1
echo x >> "$here/backlog.calls"
sleep "$(cat "$here/backlog-sleep" 2>/dev/null || echo 0)"
cat "$here/ready.tsv"
SH
  cat > "$d/spawn" <<'SH'
#!/usr/bin/env bash
here=$(cd "$(dirname "$0")" && pwd)
echo x >> "$here/spawn.$1"
if [ "$(wc -l < "$here/spawn.$1")" -le "$(cat "$here/defer-$1" 2>/dev/null || echo 0)" ]; then
  echo "deferred: pool for the project is full; task $1 stays queued" >&2; exit 75
fi
printf 'kind=ship\n' > "$here/state/$1.meta"
SH
  printf '#!/usr/bin/env bash\necho "blocking-batch: ok"\n' > "$d/hold"
  printf '#!/usr/bin/env bash\nprintf "proj off\\n"\n' > "$d/mode"
  chmod +x "$d/backlog" "$d/spawn" "$d/hold" "$d/mode"
  : > "$d/ready.tsv"
  for id in "$@"; do
    printf '%s\tproj\n' "$id" >> "$d/ready.tsv"
    printf 'approved-by=test\napproved-at=1\nharness=claude\nmodel=sonnet\neffort=medium\n' > "$d/state/dispatch-approved/$id"
    mkdir -p "$d/data/$id"
    # shellcheck disable=SC2016  # the backquotes are the brief's own text
    printf 'Delivery contract: mode=local-trunk\n1. First action: create your branch: `git checkout -b feature/%s --`\n' "$id" > "$d/data/$id/brief.md"
  done
}

# run_check <dir> [VAR=value...]: one check call with the stand-ins named. The detached passes it starts inherit them.
run_check() {
  local d=$1
  shift
  env JG_HOME="$d" JG_AUTO_DISPATCH_BACKLOG="$d/backlog" JG_AUTO_DISPATCH_SPAWN="$d/spawn" JG_AUTO_DISPATCH_HOLD="$d/hold" \
    JG_AUTO_DISPATCH_PROJECT_MODE="$d/mode" JG_AUTO_DISPATCH_ALERT=/bin/true "$@" bash "$CHECK" check "$d" 2>&1
}

calls() { { wc -l < "$1/backlog.calls"; } 2>/dev/null || echo 0; }   # <dir>: the backlog stand-in's calls, one a pass
spawns() { { wc -l < "$1/spawn.$2"; } 2>/dev/null || echo 0; }        # <dir> <task>
results() { grep -h '^result=' "$1"/data/auto-dispatch/"$2".start.* 2>/dev/null | sort | uniq -c | sed "s/^ *//" | tr '\n' ' '; }   # <dir> <id>
# wait_until <seconds> <command...>: poll every 0.1 s until the command succeeds.
wait_until() { local n s=$1; shift; for n in $(seq 1 $((s * 10))); do "$@" && return 0; sleep 0.1; done; return 1; }
has_result() { grep -qx "result=$3" "$1"/data/auto-dispatch/"$2".start.* 2>/dev/null; }   # <dir> <id> <result>
calls_ge() { [ "$(calls "$1")" -ge "$2" ]; }                     # <dir> <count>
idle() { [ ! -e "$1/data/auto-dispatch/.check.lock" ] && [ ! -e "$1/data/auto-dispatch/.retry-pending" ]; }   # <dir>

# T1 retry: the spawn defers its first call and starts on its second. One check, no second call from the test.
D1=$TMP_ROOT/t1
make_home "$D1" 2 a
printf '1\n' > "$D1/defer-a"
run_check "$D1" JG_DISPATCH_RETRY_DELAY=1 >/dev/null || fail "T1: the check failed"
wait_until 8 has_result "$D1" a started || fail "T1: the deferred start was not tried again within 8 s ($(results "$D1" a))"
assert_equals "$(spawns "$D1" a)" 2 "T1: the spawn was called twice: the deferral and the retry"
assert_present "$D1/state/a.meta" "T1: the retry published the lane record"
wait_until 8 idle "$D1" || fail "T1: the retry mark was not cleared"
pass "T1: a deferred start is tried again in seconds, with no second check call"

# T2 off: JG_DISPATCH_RETRY_DELAY=0 is today's behaviour: the deferral waits for the next beat.
D2=$TMP_ROOT/t2
make_home "$D2" 2 a
printf '1\n' > "$D2/defer-a"
run_check "$D2" JG_DISPATCH_RETRY_DELAY=0 >/dev/null || fail "T2: the check failed"
wait_until 8 has_result "$D2" a deferred || fail "T2: the start did not record its deferral"
sleep 5
assert_equals "$(results "$D2" a)" "1 result=deferred " "T2: five seconds later the record still shows deferred and nothing retried"
assert_equals "$(spawns "$D2" a)" 1 "T2: the spawn was called once"
assert_absent "$D2/data/auto-dispatch/.retry-pending" "T2: no retry waits"
pass "T2: with the retry off a deferral waits for the next beat"

# T3 one pass: three checks at once make two passes (the first, and one for the marks of the other two); no ticket starts twice.
D3=$TMP_ROOT/t3
make_home "$D3" 5 a b
printf '2\n' > "$D3/backlog-sleep"
run_check "$D3" JG_DISPATCH_RETRY_DELAY=0 >/dev/null &
run_check "$D3" JG_DISPATCH_RETRY_DELAY=0 >/dev/null &
run_check "$D3" JG_DISPATCH_RETRY_DELAY=0 >/dev/null &
wait
assert_equals "$(calls "$D3")" 2 "T3: three checks at once made exactly two passes"
assert_equals "$(spawns "$D3" a)" 1 "T3: a was started once"
assert_equals "$(spawns "$D3" b)" 1 "T3: b was started once"
assert_absent "$D3/data/auto-dispatch/.check.again" "T3: no mark is left"
assert_absent "$D3/data/auto-dispatch/.check.lock" "T3: the lock is released"
pass "T3: three checks at once make two passes and start nothing twice"

# T4 lost mark: a call that marks while the holder still holds the lock, just before its release, still gets its pass.
D4=$TMP_ROOT/t4
make_home "$D4" 5 a
printf '1\n' > "$D4/backlog-sleep"
run_check "$D4" JG_DISPATCH_RETRY_DELAY=0 JG_DISPATCH_TEST_RELEASE_DELAY=3 >/dev/null &
holder=$!
wait_until 5 calls_ge "$D4" 1 || fail "T4: the holder made no pass"
sleep 2   # the pass is over; the holder keeps the lock for the 3 s release delay
[ -d "$D4/data/auto-dispatch/.check.lock" ] || fail "T4: the holder does not hold the lock in its release delay"
run_check "$D4" JG_DISPATCH_RETRY_DELAY=0 >/dev/null
assert_present "$D4/data/auto-dispatch/.check.again" "T4: the call that could not take the lock left its mark"
wait "$holder"
assert_equals "$(calls "$D4")" 2 "T4: the marking call got its pass from the holder"
assert_absent "$D4/data/auto-dispatch/.check.again" "T4: no mark is left"
pass "T4: a mark made while the holder releases is never lost"

# T5 one retry per home: two tickets deferred in one pass leave one retry waiting, and that one retry starts both.
D5=$TMP_ROOT/t5
make_home "$D5" 5 a b
printf '1\n' > "$D5/defer-a"; printf '1\n' > "$D5/defer-b"
run_check "$D5" JG_DISPATCH_RETRY_DELAY=4 >/dev/null || fail "T5: the check failed"
wait_until 5 has_result "$D5" a deferred || fail "T5: a did not record its deferral"
wait_until 5 has_result "$D5" b deferred || fail "T5: b did not record its deferral"
sleep 1
assert_equals "$(find "$D5/data/auto-dispatch" -maxdepth 1 -name '.retry-pending*' | wc -l | tr -d ' ')" 1 "T5: two deferrals leave one retry waiting"
assert_present "$D5/data/auto-dispatch/.retry-pending" "T5: the mark of the retry is there"
wait_until 10 has_result "$D5" a started || fail "T5: a was not started by the retry"
wait_until 5 has_result "$D5" b started || fail "T5: b was not started by the retry"
assert_equals "$(calls "$D5")" 2 "T5: the one retry made one more pass"
wait_until 5 idle "$D5" || fail "T5: the retry did not finish"
pass "T5: two deferred tickets leave one retry, and it starts both"

# T6 kicks during the third pass: each pass is 2 s. One check; one call during each of its first, second and third passes and
# three more during the third. The marks are never left for the next beat: the holder starts one detached pass after its
# third, which runs by itself.
D6=$TMP_ROOT/t6
make_home "$D6" 5 a
printf '2\n' > "$D6/backlog-sleep"
run_check "$D6" JG_DISPATCH_RETRY_DELAY=0 >/dev/null &
holder=$!
for n in 1 2 3; do
  wait_until 8 calls_ge "$D6" "$n" || fail "T6: pass $n did not start"
  run_check "$D6" JG_DISPATCH_RETRY_DELAY=0 >/dev/null
done
for _ in 1 2 3; do run_check "$D6" JG_DISPATCH_RETRY_DELAY=0 >/dev/null; done
wait_until 8 calls_ge "$D6" 4 || fail "T6: the marks of the third pass got no pass (calls: $(calls "$D6"))"
wait "$holder"
wait_until 8 idle "$D6" || fail "T6: the detached pass did not finish"
assert_absent "$D6/data/auto-dispatch/.check.again" "T6: no mark is left on disk"
assert_equals "$(spawns "$D6" a)" 1 "T6: the ticket was started once"
pass "T6: marks made during the third pass get a detached pass and none is left"
