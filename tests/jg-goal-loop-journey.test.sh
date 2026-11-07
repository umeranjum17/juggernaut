#!/usr/bin/env bash
# This is also the test that owns journeys/goal-loop.sh (the done-done journey is that script itself).
# A Goal goes from ask to one finish message on a fake forge, in real time.
# Needs JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT naming the pinned builds, and skips without them.
# The journey runs its own checks and exits non-zero on one failure; this file requires its exit 0 and
# the evidence it writes, so a green journey with a missing record is still red.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=tests/lib.sh disable=SC1091
. "$HERE/lib.sh"
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi
if [ ! -x "$JG_BEADS_TEST_BD" ] || [ ! -x "$JG_BEADS_TEST_DOLT" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT must name executable pinned builds\n'
  exit 0
fi
T=$(jg_test_tmproot jg-goal-loop-journey)
trap 'rm -rf -- "$T"' EXIT
ev=$T/evidence
mkdir -p "$ev"
out=$T/journey.log
GOAL_PINNED_BIN=$(dirname "$JG_BEADS_TEST_BD") DONE_DONE_EVIDENCE_ROOT=$ev \
  bash "$ROOT/journeys/goal-loop.sh" >"$out" 2>&1 || fail "the journey must exit 0; its log is $out"

# The journey's own checks are the proof; a FAIL line there is a red run even beside exit 0.
if grep -q '^FAIL' "$ev/checks.txt"; then
  fail "the journey recorded a failed check: $(grep -m1 '^FAIL' "$ev/checks.txt")"
fi
assert_contains "$(cat "$ev/messages.txt")" 'the Goal is done' "the journey must reach a finished Goal"
assert_contains "$(cat "$ev/messages.txt")" 'finished - ' "the journey must record the one finish message"
assert_contains "$(cat "$ev/timeline.txt")" 'proof' "the journey must run the proof it declared"
for f in steps.json timeline.txt checks.txt messages.txt forge.log; do
  [ -s "$ev/$f" ] || fail "the journey must write evidence/$f"
done
pass "jg-goal-loop-journey"
