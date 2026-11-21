#!/usr/bin/env bash
# A watcher cycle that exits 1 at a silent `|| exit 1` site must say where, on
# its own output and in the owning home's cycle ledger (state/.watch-cycle-exits.log).
# Before: the arm printed only "exited 1 without an actionable reason" and the
# ledger row carried no cause, so a Pi primary saw an unexplained status 1.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-watch-silent-exit)

dir=$(make_case silent-exit)
state="$dir/state"
farm="$dir/farm"
mkdir -p "$farm/bin"
for item in "$ROOT"/* "$ROOT"/.[!.]*; do
  [ -e "$item" ] || continue
  [ "$(basename "$item")" = bin ] || ln -s "$item" "$farm/$(basename "$item")"
done
for item in "$ROOT"/bin/*; do ln -s "$item" "$farm/bin/$(basename "$item")"; done
# The real watcher with one injected silent failure right after it takes the lock.
rm "$farm/bin/jg-watch.sh"
awk '{print} /^trap watcher_cleanup EXIT$/ && !done {print "false || exit 1"; done=1}' \
  "$ROOT/bin/jg-watch.sh" > "$farm/bin/jg-watch.sh"
chmod +x "$farm/bin/jg-watch.sh"
grep -q '^false || exit 1$' "$farm/bin/jg-watch.sh" || fail "could not inject the silent exit"

PATH="$dir/fakebin:$PATH" JG_HOME="$dir" JG_STATE_OVERRIDE="$state" JG_ROOT_OVERRIDE="$farm" \
  "$farm/bin/jg-watch-arm.sh" > "$dir/arm.out" 2> "$dir/arm.err"
rc=$?
[ "$rc" -eq 1 ] || fail "want the cycle to exit 1, got $rc ($(cat "$dir/arm.out" "$dir/arm.err"))"
grep -Eq 'watcher: FAILED - exited 1 at jg-watch.sh line [0-9]+ in main' "$dir/arm.out" \
  || fail "the cycle output does not name the exit site: $(cat "$dir/arm.out" "$dir/arm.err")"
row=$(tail -1 "$state/.watch-cycle-exits.log" 2>/dev/null)
case "$row" in
  *reason=nonzero-exit*"$(printf '\t')"detail=watcher:\ FAILED\ -\ exited\ 1\ at\ jg-watch.sh\ line*) ;;
  *) fail "the ledger row carries no cause: $row" ;;
esac
pass "a silent exit 1 names its site in the cycle output and the ledger row"

# Consecutive crash exits back off exponentially: each re-arm waits out the next,
# longer step, measured from the previous crash's end, before it forks a watcher.
# Before: every owner retry forked a fresh watcher at once, so an idle home that
# crashed on startup cycled every 1-2 seconds.
field() { printf '%s\n' "$1" | tr '\t' '\n' | sed -n "s/^$2=//p"; }
prev_end=$(field "$row" ended_at)
run=0
for step in 2 4 8; do
  run=$((run + 1))
  PATH="$dir/fakebin:$PATH" JG_HOME="$dir" JG_STATE_OVERRIDE="$state" JG_ROOT_OVERRIDE="$farm" \
    JG_WATCH_CRASH_BACKOFF="2 4 8" "$farm/bin/jg-watch-arm.sh" > "$dir/arm.out" 2> "$dir/arm.err"
  rc=$?
  [ "$rc" -eq 1 ] || fail "crash $run: want the cycle to exit 1, got $rc ($(cat "$dir/arm.out" "$dir/arm.err"))"
  grep -Eq "^watcher: backing off [0-9]+s after $run consecutive crash exits \(step ${step}s\)$" "$dir/arm.out" \
    || fail "crash $run: the arm did not back off by the ${step}s step: $(cat "$dir/arm.out")"
  row=$(tail -1 "$state/.watch-cycle-exits.log")
  start=$(field "$row" started_at)
  [ "$start" -ge $((prev_end + step)) ] \
    || fail "crash $run: the watcher started ${start}, before the ${step}s step after the last crash ended at ${prev_end}"
  prev_end=$(field "$row" ended_at)
done
pass "consecutive crash exits wait 2s, 4s, then 8s before the next watcher starts"
printf 'ok - %s\n' "watcher silent-exit reason"
