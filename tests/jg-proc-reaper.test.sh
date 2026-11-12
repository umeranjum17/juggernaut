#!/usr/bin/env bash
# tests/jg-proc-reaper.test.sh - a process started through bin/jg-run-owned.sh is ended inside 2 ticks once its owner has
# exited, or once it is past its limit, and a process with no record is named and never touched
# (core/tmp-reaper/proc.sh, core/tmp-reaper/wiring.sh, bin/jg-run-owned.sh).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-proc-reaper)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
H=$TMP_ROOT/home
mkdir -p "$H/state" "$H/config" "$H/bin"
for f in "$ROOT"/bin/*; do ln -s "$f" "$H/bin/${f##*/}"; done
export JG_HOME=$H
unset JG_STATE_OVERRIDE
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill -KILL -- "-$p" "$p" 2>/dev/null; done; }
trap cleanup EXIT
alive() { kill -0 "$1" 2>/dev/null && [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" != Z ]; }

env -u JG_STATE_OVERRIDE bash "$ROOT/core/tmp-reaper/wiring.sh" "$H" >/dev/null 2>&1 || fail "wiring did not arm the checks"
CHECK=$H/state/proc-reaper.check.sh
[ -x "$CHECK" ] || fail "wiring left no state/proc-reaper.check.sh"
tick() { bash "$CHECK"; }

# The wrapper refuses a start with no owner or no limit.
bash "$ROOT/bin/jg-run-owned.sh" --limit 60 -- sleep 1 2>/dev/null && fail "started with no owner"
bash "$ROOT/bin/jg-run-owned.sh" --owner t1 -- sleep 1 2>/dev/null && fail "started with no limit"
pass "the wrapper needs an owner and a limit"

# 1. Owner exits: the child the owner started dies inside 2 ticks.
OWNER_OUT=$TMP_ROOT/owner.out
bash -c 'bash "$1" --owner t-owner --limit 3600 -- sleep 600 & echo $! > "$2"; wait' _ "$ROOT/bin/jg-run-owned.sh" "$OWNER_OUT" &
OWNER=$!
for _ in $(seq 50); do [ -s "$OWNER_OUT" ] && ls "$H"/state/owned-procs/*.rec >/dev/null 2>&1 && break; sleep 0.1; done
CHILD=$(cat "$OWNER_OUT"); PIDS+=("$CHILD")
alive "$CHILD" || fail "the owned child did not start"
tick; alive "$CHILD" || fail "a child with a living owner was ended"
kill -KILL "$OWNER" 2>/dev/null; wait "$OWNER" 2>/dev/null
tick; tick
sleep 0.3
alive "$CHILD" && fail "the child of an exited owner was still alive after 2 ticks"
assert_grep "term $CHILD owner=t-owner why=owner-gone" "$H/state/proc-reaper.log" "the end was not logged"
pass "a child whose owner exited is ended inside 2 ticks"

# 2. A tick-owned process (owner pid none) lives to its limit, then is ended.
bash "$ROOT/bin/jg-run-owned.sh" --owner tick:demo --limit 3 --owner-pid none -- sleep 600 &
T=$!; PIDS+=("$T")
sleep 0.3; tick; alive "$T" || fail "a process within its limit was ended"
sleep 3.2; tick; tick; sleep 0.3
alive "$T" && fail "a process past its limit was still alive after 2 ticks"
wait "$T" 2>/dev/null
pass "a process past its limit is ended inside 2 ticks"

# 3. A process with no record is named by list and never touched; a gone process loses its record.
mkdir -p "$TMP_ROOT/fake"; ln -s "$(command -v sleep)" "$TMP_ROOT/fake/claude"
JG_TASK_ID=ghost-task "$TMP_ROOT/fake/claude" 600 &
U=$!; PIDS+=("$U")
sleep 0.3
out=$(bash "$ROOT/core/tmp-reaper/proc.sh" list "$H"); tick; tick
case $out in *"unowned $U claude ghost-task"*) ;; *) fail "the process with no record was not named: $out" ;; esac
alive "$U" || fail "a process with no record was touched"
ls "$H"/state/owned-procs/*.rec >/dev/null 2>&1 && fail "records of ended processes were kept"
pass "a process with no record is named and not touched"

env -u JG_STATE_OVERRIDE bash "$ROOT/core/tmp-reaper/unwiring.sh" "$H" >/dev/null 2>&1 || fail "unwiring failed"
[ ! -e "$CHECK" ] || fail "unwiring left the proc check"
pass "unwiring removes the proc check"
