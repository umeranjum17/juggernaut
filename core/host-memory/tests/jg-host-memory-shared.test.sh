#!/usr/bin/env bash
# Integration: one host memory sampler serves every home on the machine.
# Starts the sampler for three homes through the real lifecycle entry (jg_memory_sampler_ensure), as each
# home's watcher does, and reads the processes and records it leaves:
#   1. the homes are served by the same one process, and each records its own samples, even when a home
#      runs its own copy of the sampler script, as homes in separate checkouts do, and all homes
#      see the same single machine measurement in each interval while applying their own thresholds;
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
mkdir -p "$TMP_ROOT/python"
# Give each actual meminfo open a distinct available-memory reading. The guard still reads the
# fixture file through its normal CLI. Equality across homes now proves reuse even within one second.
cat > "$TMP_ROOT/python/sitecustomize.py" <<'PY'
import os
import sys
from pathlib import Path

meminfo = Path(os.environ["JG_HOST_MEMORY_PROC"]) / "meminfo"
reads = meminfo.with_name("meminfo-reads")

def tag_measurement(event, args):
    if event == "open" and args[:2] == (str(meminfo), "r"):
        with reads.open("a") as f:
            f.write("x")
        next_value = meminfo.with_suffix(".next")
        next_value.write_text(f"MemAvailable: {41943040 + reads.stat().st_size} kB\n")
        next_value.replace(meminfo)

sys.addaudithook(tag_measurement)
PY
export PYTHONPATH="$TMP_ROOT/python${PYTHONPATH:+:$PYTHONPATH}"
printf 'some avg10=0 avg60=0 avg300=0 total=0\n' > "$TMP_ROOT/proc/pressure/memory"
watchers=()
cleanup() {
  local f
  kill -TERM "${watchers[@]}" 2>/dev/null
  for f in "$TMP_ROOT"/*/state/.host-memory-sampler.pid "$JG_HOST_MEMORY_MACHINE_DIR/pid"; do
    [ ! -r "$f" ] || kill -TERM "$(cut -f1 "$f")" 2>/dev/null
  done
  jg_test_cleanup
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

lifecycle() { # <home> <ensure|stop> [sampler script]: the watcher's own call for that home
  JG_HOME=$1 JG_STATE_OVERRIDE=$1/state JG_CONFIG_OVERRIDE=$1/config bash -c '
    SCRIPT_DIR=$2/bin STATE=$JG_STATE_OVERRIDE CONFIG=$JG_CONFIG_OVERRIDE
    . "$SCRIPT_DIR/jg-wake-lib.sh"; . "$SCRIPT_DIR/jg-backend.sh"; . "$3"
    jg_memory_sampler_$4' _ "$1" "$ROOT" "${3:-$SAMPLER}" "$2"
}

wait_for() { # <command...>: true within 10 s
  local i=0
  while [ "$i" -lt 100 ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
has_two_samples() { [ -s "$1/state/host-memory.tsv" ] && [ "$(wc -l < "$1/state/host-memory.tsv")" -ge 2 ]; }
gone() { ! kill -0 "$1" 2>/dev/null; }

new_home alpha; alpha=$HOME_DIR
new_home beta; beta=$HOME_DIR
new_home gamma; gamma=$HOME_DIR
printf 'alert_available_gb=41\n' > "$beta/config/host-memory"
# The second home has its own checkout, so its watcher sources a sampler script at another path.
BETA_SAMPLER=$TMP_ROOT/beta-checkout/core/host-memory/bin/jg-host-memory-sampler.sh
mkdir -p "${BETA_SAMPLER%/*}" && cp "$SAMPLER" "$BETA_SAMPLER"
lifecycle "$alpha" ensure || fail "ensure failed for the first home"
lifecycle "$beta" ensure "$BETA_SAMPLER" || fail "ensure failed for a second home whose checkout holds its own sampler copy"
lifecycle "$gamma" ensure || fail "ensure failed for the third home"
pa=$(cut -f1 "$alpha/state/.host-memory-sampler.pid")
pb=$(cut -f1 "$beta/state/.host-memory-sampler.pid")
pc=$(cut -f1 "$gamma/state/.host-memory-sampler.pid")
[ -n "$pa" ] && [ "$pa" = "$pb" ] && [ "$pa" = "$pc" ] || fail "the three homes did not share one sampler ($pa, $pb, $pc)"
# Count only this test's sampler scripts: the host may run its own sampler.
[ "$(pgrep -fa "jg-host-memory-sampler.sh run$" | awk -v a="$SAMPLER" -v b="$BETA_SAMPLER" '$3 == a || $3 == b' | wc -l)" -le 1 ] || fail "more than one sampler process runs"
wait_for has_two_samples "$gamma" || fail "the third home did not record two samples"
awk -F '\t' '
  FILENAME == ARGV[1] { if ($5 == "OK") alpha[$2] = $1; next }
  FILENAME == ARGV[2] { if ($5 == "ALERT") beta[$2] = $1; next }
  {
    if (!($2 in alpha) || !($2 in beta) || alpha[$2] != $1 || beta[$2] != $1 || $5 != "OK") exit 1
    if (seen && $2 != previous + 1) exit 1
    previous = $2
    if (++seen == 2) exit 0
  }
' "$alpha/state/host-memory.tsv" "$beta/state/host-memory.tsv" "$gamma/state/host-memory.tsv" \
  || fail "the homes did not share one measurement per interval with independent verdicts"
wait_for test -s "$beta/state/.wake-queue" || fail "the home above its alert floor received no alert"
assert_grep 'available memory below 41 GB' "$beta/state/.wake-queue" "the wake must explain the threshold that triggered it"
[ ! -s "$alpha/state/.wake-queue" ] && [ ! -s "$gamma/state/.wake-queue" ] \
  || fail "the alert reached a home that did not cross its threshold"
pass "three homes reuse one reading per interval and only the home crossing its threshold gets an alert"
lifecycle "$gamma" stop || fail "could not unregister the third home"
lifecycle "$beta" ensure "$BETA_SAMPLER" || fail "a repeated ensure failed"
[ "$(cut -f1 "$beta/state/.host-memory-sampler.pid")" = "$pa" ] || fail "a repeated ensure started another sampler"
pass "one sampler serves two homes in separate checkouts and each records its own samples"

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
