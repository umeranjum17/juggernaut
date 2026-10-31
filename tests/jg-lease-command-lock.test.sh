#!/usr/bin/env bash
# tests/jg-lease-command-lock.test.sh - the lease-command lock delivers or
# refuses, never blocks.
#
# jg-send takes the lease-command lock before it may deliver anything, so a
# holder that never releases it used to stop every send in the home forever: a
# leaked steal directory whose recorded pid was recycled onto a live process
# refuses every reclaimer, and the acquire had no wall-clock bound at all. The
# contract now is "deliver or refuse", and these cases drive the real
# executables over a stubbed terminal to pin it:
#   1. A holder killed mid-lock leaves a dead owner record, and the next send
#      delivers within the bound.
#   2. A live holder produces a refusal that names its pid and task, within the
#      bound, and nothing is delivered.
#   3. No steal directory survives a run - neither an ordinary send nor a holder
#      a signal kills while it owns the steal mutex.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/jg-send.sh"
WAKE_LIB="$ROOT/bin/jg-wake-lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-lease-command-lock)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# The send's terminal work is stubbed exactly as tests/jg-send-inbox.test.sh
# does: the inbox plane only needs a composer read and a successful submit.
make_stubs() { # <dir>
  jg_fake_exit0 "$(jg_fakebin "$1")" tmux sleep
}

setup_case() { # <name> -> echoes case dir with home/state + t1 meta
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  jg_write_meta "$dir/home/state/t1.meta" "window=sess:jg-t1" "kind=ship" "harness=claude"
  # A lease file is what makes jg-send's guard engage the lease-command lock; a
  # dead recorded pid is ordinary staleness the guard clears once it holds the lock.
  printf 'main\t%d\t0\n' 999999 >"$dir/home/state/.lease-t1"
  printf '%s\n' "$dir"
}

run_send() { # <case-dir> <err-file> [env...] -- <jg-send args...>
  local dir=$1 err=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  env PATH="$dir/fakebin:$PATH" \
    JG_ROOT_OVERRIDE="$dir/home" JG_HOME="$dir/home" \
    JG_SEND_SETTLE=0 ${envs[@]+"${envs[@]}"} \
    "$SEND" "$@" >/dev/null 2>"$err"
}

# wait_for_file <path> <poll-count>: bound the wait for a child's ready marker so
# a regression in the child fails the case instead of hanging the suite.
wait_for_file() {
  local path=$1 polls=${2:-100}
  while [ ! -e "$path" ]; do
    polls=$((polls - 1))
    [ "$polls" -gt 0 ] || return 1
    sleep 0.1
  done
}

# start_holder <state> <ready-marker> <bash-body>: run <body> in a child that has
# the lock libraries sourced and $STATE set, and set HOLDER_PID to that child.
# The pid travels in a variable, never on stdout: a command substitution would
# wait on the child's inherited stdout until the child exits.
HOLDER_PID=
start_holder() {
  local state=$1 ready=$2 body=$3
  # shellcheck disable=SC2016 # the inner shell expands $1/$2/$3, not this one.
  env JG_ROOT_OVERRIDE="${state%/state}" JG_STATE_OVERRIDE="$state" \
    bash -c '. "$1"; . "$2"; STATE=$3; '"$body" \
    _ "$WAKE_LIB" "$ROOT/bin/jg-lease-lib.sh" "$state" "$ready" &
  HOLDER_PID=$!
  wait_for_file "$ready" || {
    kill -9 "$HOLDER_PID" 2>/dev/null
    fail "the holder never took the lock"
  }
}

# wait_gone <path> <poll-count>: the trap that drops a stolen mutex runs between
# the holder's own commands (bash defers a trap until its current foreground
# command returns), so the acquire's short waits make it prompt without making
# the removal synchronous.
wait_gone() {
  local path=$1 polls=${2:-40}
  while [ -e "$path" ]; do
    polls=$((polls - 1))
    [ "$polls" -gt 0 ] || return 1
    sleep 0.1
  done
}

# no_steal_scratch <state> <label>: no steal directory may survive a run.
no_steal_scratch() {
  local state=$1 label=$2 left
  left=$(find "$state" -maxdepth 1 -name '*.steal*' -print 2>/dev/null)
  [ -z "$left" ] || fail "$label left steal scratch behind: $left"
}

test_killed_holder_lets_the_next_send_deliver() {
  local dir state pid err start elapsed rc record
  dir=$(setup_case killed-holder)
  state="$dir/home/state"
  # shellcheck disable=SC2016 # the holder's own shell expands $STATE, not this one.
  start_holder "$state" "$dir/ready" \
    'jg_lease_command_lock_acquire "$STATE/.jg-lease-command.lock" "holder" || exit 9
     printf ready >"$4"
     sleep 60'
  pid=$HOLDER_PID
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  start=$(date +%s)
  rc=0
  run_send "$dir" "$dir/send.err" JG_LEASE_COMMAND_LOCK_WAIT_SECS=10 -- t1 "deliver after the crash" || rc=$?
  elapsed=$(( $(date +%s) - start ))
  expect_code 0 "$rc" "the send after a killed holder should deliver"$'\n'"$(cat "$dir/send.err")"
  record="$state/t1.inbox/001.msg"
  [ -f "$record" ] || fail "the steer after a killed holder was not recorded at $record"
  [ "$elapsed" -le 10 ] || fail "the send waited ${elapsed}s past its 10s bound for a dead holder"
  no_steal_scratch "$state" "the send after a killed holder"
  pass "lease-command lock: a killed holder's dead record still lets the next send deliver"
}

test_live_holder_is_refused_not_waited_on() {
  local dir state pid err start elapsed rc out record
  dir=$(setup_case live-holder)
  state="$dir/home/state"
  sleep 60 &
  pid=$!
  # The live holder's own record, written the way the acquire writes it.
  mkdir -p "$state/.jg-lease-command.lock.owner.test"
  printf '%s\n' "$pid" >"$state/.jg-lease-command.lock.owner.test/pid"
  printf 'rebase-the-api\n' >"$state/.jg-lease-command.lock.owner.test/task"
  ln -s "$state/.jg-lease-command.lock.owner.test" "$state/.jg-lease-command.lock"

  start=$(date +%s)
  rc=0
  run_send "$dir" "$dir/send.err" JG_LEASE_COMMAND_LOCK_WAIT_SECS=2 -- t1 "must not hang" || rc=$?
  err="$dir/send.err"
  elapsed=$(( $(date +%s) - start ))
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  [ "$rc" -ne 0 ] || fail "a live lock holder must refuse, not let the send through"
  [ "$elapsed" -le 12 ] || fail "the refusal took ${elapsed}s against a 2s bound (a hang, not a refusal)"
  out=$(cat "$err")
  assert_contains "$out" "refused after 2s" "the refusal should name its bound"
  assert_contains "$out" "$pid" "the refusal should name the holding pid"
  assert_contains "$out" "rebase-the-api" "the refusal should name the holder's task"
  assert_not_contains "$out" "still held by pid unknown" "the refusal should read the recorded pid"
  record="$state/t1.inbox/001.msg"
  [ ! -f "$record" ] || fail "a refused send must not record a steer"
  pass "lease-command lock: a live holder produces a refusal naming its pid and task"
}

test_no_steal_directory_survives_a_run() {
  local dir state pid err rc start elapsed
  dir=$(setup_case steal-scratch)
  state="$dir/home/state"
  rc=0
  run_send "$dir" "$dir/send.err" JG_LEASE_COMMAND_LOCK_WAIT_SECS=10 -- t1 "ordinary send" || rc=$?
  expect_code 0 "$rc" "an ordinary send should deliver"$'\n'"$(cat "$dir/send.err")"
  no_steal_scratch "$state" "an ordinary send"

  # A leftover steal directory whose recorded pid was recycled onto this live
  # test process cannot be proven dead, so its age is the only proof left; the
  # send must age it out instead of waiting on it forever.
  #
  # The lease file is what makes jg-send's guard engage the lease-command lock
  # (bin/jg-lease-lib.sh jg_lease_guard): the ordinary send above cleared the
  # stale one, and a host with no coding-agent marker and no supervision host - a
  # CI runner - then skips the lock and never looks at this scratch at all. Write
  # the precondition again so the case drives the lock on every host.
  printf 'main\t%d\t0\n' 999999 >"$state/.lease-t1"
  mkdir -p "$state/.jg-lease-command.lock.steal.owner.recycled"
  printf '%s\n' "$$" >"$state/.jg-lease-command.lock.steal.owner.recycled/pid"
  ln -s "$state/.jg-lease-command.lock.steal.owner.recycled" "$state/.jg-lease-command.lock.steal"
  touch -h -d '-1 day' "$state/.jg-lease-command.lock.steal"
  start=$(date +%s)
  rc=0
  run_send "$dir" "$dir/send.err" JG_LEASE_COMMAND_LOCK_WAIT_SECS=3 -- t1 "send past a recycled steal" || rc=$?
  elapsed=$(( $(date +%s) - start ))
  expect_code 0 "$rc" "a recycled-pid steal directory must be aged out, not waited on"$'\n'"$(cat "$dir/send.err")"
  [ "$elapsed" -le 15 ] || fail "the send waited ${elapsed}s on an abandoned steal directory"
  no_steal_scratch "$state" "a send past a recycled-pid steal"

  # A signal must not strand the steal directory either: hold it exactly as the
  # acquire does, then kill the holder while it waits the way the acquire waits.
  # shellcheck disable=SC2016 # the holder's own shell expands $STATE, not this one.
  start_holder "$state" "$dir/ready-steal" \
    'jg_lock_steal_hold "$STATE/x.lock.steal" 5 || exit 9
     printf ready >"$4"
     while :; do sleep 0.1; done'
  pid=$HOLDER_PID
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  wait_gone "$state/.jg-lease-command.lock.steal" || fail "a TERM left the steal mutex behind"
  no_steal_scratch "$state" "a TERM while holding the steal mutex"
  pass "lease-command lock: no steal directory survives a send or a signal"
}

test_killed_holder_lets_the_next_send_deliver
test_live_holder_is_refused_not_waited_on
test_no_steal_directory_survives_a_run
