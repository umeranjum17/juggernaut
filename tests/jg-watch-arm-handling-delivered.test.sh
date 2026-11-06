#!/usr/bin/env bash
# bin/jg-watch-arm.sh --handling-delivered: the outcome contract the Pi watcher
# extension reads (.pi/extensions/jg-primary-pi-watch.ts confirmHandlingDelivery).
#   0 confirmed   - a live successor holds the lock and the marker advanced
#   3 superseded  - the episode is already acknowledged, or moved past the generation
#   1 refused     - a genuine refusal: dead successor, lock held by another
#                   watcher, or an unusable marker
# An acknowledged generation must never read as a refusal, even when the
# successor that was being confirmed has exited since (docs/watcher-continuity.md).
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-watch-arm-handling-delivered)
ARM="$ROOT/bin/jg-watch-arm.sh"
GEN=g1.100.abc
# shellcheck source=bin/jg-wake-lib.sh
. "$ROOT/bin/jg-wake-lib.sh"

# <case> <marker-token|-> <live|dead|other-watcher>: lays out the home and lock.
# Sets DIR, HOLDER (the pid named to the arm script).
setup_case() {
  DIR=$(make_case "$1")
  mkdir -p "$DIR/state/.watch.lock"
  HOLDER=
  if [ "$3" = dead ]; then
    HOLDER=$(bash -c 'echo $$')   # an exited shell's pid
  else
    sleep 60 >/dev/null 2>&1 &
    HOLDER=$!
    SLEEPERS="${SLEEPERS:-} $HOLDER"
  fi
  printf '%s\n' "$HOLDER" > "$DIR/state/.watch.lock/pid"
  printf '%s\n' "$DIR" > "$DIR/state/.watch.lock/jg-home"
  printf '%s\n' "$ROOT/bin/jg-watch.sh" > "$DIR/state/.watch.lock/watcher-path"
  [ "$3" != other-watcher ] || printf '%s\n' "$DIR/elsewhere/jg-watch.sh" > "$DIR/state/.watch.lock/watcher-path"
  jg_pid_identity "$HOLDER" > "$DIR/state/.watch.lock/pid-identity" 2>/dev/null \
    || printf 'dead-identity\n' > "$DIR/state/.watch.lock/pid-identity"
  [ "$2" = - ] || { printf '%s\n' "$2" > "$DIR/state/.watcher-down"; chmod 0600 "$DIR/state/.watcher-down"; }
}

run_arm() { # <generation>; prints stderr to $DIR/err, returns the arm status
  JG_HOME="$DIR" JG_STATE_OVERRIDE="$DIR/state" "$ARM" --handling-delivered "$1" --watcher-pid "$HOLDER" \
    > "$DIR/out" 2> "$DIR/err"
}

cleanup() { local p; for p in ${SLEEPERS:-}; do kill "$p" 2>/dev/null; done; wait 2>/dev/null || true; }
trap cleanup EXIT

expect_status() { # <want> <label>
  local got=$?
  [ "$got" -eq "$1" ] || fail "$2: want status $1, got $got ($(cat "$DIR/err" "$DIR/out" 2>/dev/null))"
}

# The false alarm: the drain acknowledged the generation, then the successor was gone.
setup_case acked-dead "acked:handling:$GEN" dead
run_arm "$GEN"; expect_status 3 "acknowledged generation with an exited successor"
setup_case acked-live "acked:handling:$GEN" live
run_arm "$GEN"; expect_status 3 "acknowledged generation with a live successor"
setup_case acked-downtime "acked:downtime:$GEN" dead
run_arm "$GEN"; expect_status 3 "acknowledged downtime generation"
[ "$(cat "$DIR/state/.watcher-down")" = "acked:downtime:$GEN" ] || fail "the acknowledged marker was rewritten"
pass "an acknowledged generation is superseded (3), not refused, and leaves the marker alone"

# Controls: a live matching successor still confirms; a newer generation is superseded.
setup_case pending-live "pending:handling:$GEN" live
run_arm "$GEN"; expect_status 0 "live successor over a pending marker"
setup_case newer "acked:handling:other.1.z" live
run_arm "$GEN"; expect_status 3 "marker moved past the generation"
pass "a live successor still confirms and a newer generation is still superseded"

# Genuine refusals keep failing, including over a marker that is not acknowledged.
setup_case pending-dead "pending:handling:$GEN" dead
run_arm "$GEN"; expect_status 1 "dead successor over a pending marker"
setup_case pending-other "pending:handling:$GEN" other-watcher
run_arm "$GEN"; expect_status 1 "lock that names another watcher"
setup_case nomarker - live
run_arm "$GEN"; expect_status 1 "absent marker"
setup_case unreadable "pending:downtime:$GEN" live
chmod 0000 "$DIR/state/.watcher-down"
run_arm "$GEN"; got=$?
chmod 0600 "$DIR/state/.watcher-down"
[ "$got" -eq 1 ] || fail "unreadable marker: want status 1, got $got"
[ "$(cat "$DIR/state/.watcher-down")" = "pending:downtime:$GEN" ] || fail "the refused marker advanced"
pass "a dead successor, a foreign lock, an absent marker, and an unreadable marker still refuse (1)"

printf 'ok - %s\n' "handling-delivered outcome contract"
