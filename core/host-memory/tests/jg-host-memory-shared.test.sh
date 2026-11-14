#!/usr/bin/env bash
# Integration: one host memory sampler serves every home on the machine.
# Starts the sampler for two homes through the real lifecycle entry (jg_memory_sampler_ensure), as each
# home's watcher does, and reads the processes and records it leaves:
#   1. both homes are served by the same one process, and each records its own samples;
#   2. a home whose watcher has gone is dropped from the loop, which keeps serving the other;
#   3. the last home to stop ends the sampler, and a second sampler never starts beside a running one.
# Usage: bash core/host-memory/tests/jg-host-memory-shared.test.sh   exit 0 = PASS.
set -u

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../../../tests/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-host-memory-shared)
SAMPLER="$ROOT/core/host-memory/bin/jg-host-memory-sampler.sh"
export JG_HOST_MEMORY_MACHINE_DIR="$TMP_ROOT/machine" JG_HOST_MEMORY_SECS=1
export JG_HOST_MEMORY_PROC="$TMP_ROOT/proc" JG_HOST_MEMORY_CGROUP_ROOT="$TMP_ROOT/no-cgroup"
mkdir -p "$TMP_ROOT/proc/pressure"
printf 'MemAvailable: 41943040 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$TMP_ROOT/proc/meminfo"
printf 'some avg10=0 avg60=0 avg300=0 total=0\n' > "$TMP_ROOT/proc/pressure/memory"
watchers=()
cleanup() {
  local f
  kill -TERM "${watchers[@]}" 2>/dev/null
  for f in "$TMP_ROOT"/*/state/.host-memory-sampler.pid "$JG_HOST_MEMORY_MACHINE_DIR/pid"; do
    [ ! -r "$f" ] || kill -TERM "$(cut -f1 "$f")" 2>/dev/null
  done
}
trap cleanup EXIT

new_home() { # <name>: sets HOME_DIR to a home with a stand-in watcher of ours recorded in the lock the sampler checks
  local h=$TMP_ROOT/$1 w
  mkdir -p "$h/state/.watch.lock" "$h/config"
  sleep 600 >/dev/null 2>&1 & w=$!
  watchers+=("$w")
  printf '%s\n' "$w" > "$h/state/.watch.lock/pid"
  printf '%s\n' "$h" > "$h/state/.watch.lock/jg-home"
  printf '%s\n' "$ROOT/bin/jg-watch.sh" > "$h/state/.watch.lock/watcher-path"
  bash -c '. "$1/bin/jg-wake-lib.sh"; jg_pid_identity "$2"' _ "$ROOT" "$w" > "$h/state/.watch.lock/pid-identity"
  HOME_DIR=$h
}

lifecycle() { # <home> <ensure|stop>: the watcher's own call for that home
  JG_HOME=$1 JG_STATE_OVERRIDE=$1/state JG_CONFIG_OVERRIDE=$1/config bash -c '
    SCRIPT_DIR=$2/bin STATE=$JG_STATE_OVERRIDE CONFIG=$JG_CONFIG_OVERRIDE
    . "$SCRIPT_DIR/jg-wake-lib.sh"; . "$SCRIPT_DIR/jg-backend.sh"; . "$3"
    jg_memory_sampler_$4' _ "$1" "$ROOT" "$SAMPLER" "$2"
}

wait_for() { # <command...>: true within 10 s
  local i=0
  while [ "$i" -lt 100 ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
has_samples() { [ -s "$1/state/host-memory.tsv" ]; }
gone() { ! kill -0 "$1" 2>/dev/null; }

new_home alpha; alpha=$HOME_DIR
new_home beta; beta=$HOME_DIR
lifecycle "$alpha" ensure || fail "ensure failed for the first home"
lifecycle "$beta" ensure || fail "ensure failed for the second home"
pa=$(cut -f1 "$alpha/state/.host-memory-sampler.pid")
pb=$(cut -f1 "$beta/state/.host-memory-sampler.pid")
[ -n "$pa" ] && [ "$pa" = "$pb" ] || fail "the two homes are served by two samplers ($pa, $pb)"
[ "$(pgrep -fc "jg-host-memory-sampler.sh run$" || true)" -le 1 ] || fail "more than one sampler process runs"
wait_for has_samples "$alpha" || fail "the first home recorded no sample"
wait_for has_samples "$beta" || fail "the second home recorded no sample"
lifecycle "$beta" ensure || fail "a repeated ensure failed"
[ "$(cut -f1 "$beta/state/.host-memory-sampler.pid")" = "$pa" ] || fail "a repeated ensure started another sampler"
pass "one sampler serves two homes and each records its own samples"

# The second home's watcher goes away: the loop drops that home and keeps the first.
kill -TERM "${watchers[1]}"; wait "${watchers[1]}" 2>/dev/null
wait_for test ! -e "$JG_HOST_MEMORY_MACHINE_DIR/homes/${beta//\//%}" || fail "a home with no watcher stayed registered"
kill -0 "$pa" 2>/dev/null || fail "the sampler ended while a home still needed it"
pass "a home whose watcher is gone is dropped and the sampler keeps serving the others"

lifecycle "$alpha" stop
wait_for gone "$pa" || fail "the sampler outlived its last home"
[ ! -e "$alpha/state/.host-memory-sampler.pid" ] || fail "stop left the home's sampler record"
lifecycle "$alpha" ensure || fail "a stopped home could not start the sampler again"
pn=$(cut -f1 "$alpha/state/.host-memory-sampler.pid")
[ "$pn" != "$pa" ] || fail "no new sampler after the last one ended"
pass "the last home to stop ends the sampler, and a later ensure starts one again"
echo 'PASS one host memory sampler per machine'
