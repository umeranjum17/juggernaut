#!/usr/bin/env bash
# Behavior tests for core/goal-loop: the check reduces every Goal to finished, stopped, waiting or next with no
# model, wakes the lead once for each new next step, and wires and unwires as a registered watcher check.
# The reduction runs on recorded Goal rows; the real-store case needs JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT
# and skips plainly without them.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=tests/lib.sh disable=SC1091
. "$HERE/../../../tests/lib.sh"

LOOP="$ROOT/core/goal-loop/goal-loop.sh" T=$(jg_test_tmproot goal-loop)
H=$T/home
mkdir -p "$H/state" "$H/config" "$H/data"
unset GOAL_BEADS_DIR JG_GOAL_RESURFACE_SECS

# A stand-in `jg-goal.sh rows`: it prints the recorded rows, or refuses with the recorded reason.
cat > "$T/goal" <<'SH'
#!/usr/bin/env bash
[ "$1" = rows ] || exit 2
if [ -s "$ROWS.refuse" ]; then cat "$ROWS.refuse" >&2; exit 2; fi
cat "$ROWS"
SH
chmod +x "$T/goal"
export JG_GOAL_BIN=$T/goal ROWS=$T/rows.json

# rows <status of ship merged released running proven> [<extra row status>]: one open Goal and its steps.
rows() {
  jq -nc --arg s "$*" '($s | split(" ")) as $a
    | [{id:"goal-a", title:"Goal: ship it", status:"open", issue_type:"epic", metadata:{goal:{ask:"ship it"}}}]
      + ([["ship","merged","released","running","proven"], $a[0:5]] | transpose
         | to_entries | map({id:"goal-a.\(.key + 1)", title:.value[0], status:.value[1], issue_type:"task", parent:"goal-a", metadata:{kind:.value[0]}}))
      + (if ($a | length) > 5 then [{id:"goal-a.6", title:"stop", status:$a[5], issue_type:"task", parent:"goal-a", metadata:{hold_reason:"owner must say"}}] else [] end)' > "$ROWS"
}
wake() { "$LOOP" check "$H"; }
state() { "$LOOP" state "$H" | cut -f2,3; }

# A home with no Goal store named is silent and writes nothing.
rows open open open open open
assert_equals "$(wake)" "" "a home with no Goal store is silent"
assert_absent "$H/data/jg-goal-loop" "a home with no Goal store keeps no records"
printf '%s\n' "$T/store/.beads" > "$H/config/goal-beads-dir"

# One Goal, walked step by step: a new next step rings once, a taken step is waiting, and a close moves it on.
out=$(wake)
assert_contains "$out" "goal-a is ready for its ship step (ship it)" "the first open step is the next step"
assert_equals "$(wake)" "" "the same next step does not ring twice"
assert_equals "$(state)" $'next\tship' "state names the next step"
rows in_progress open open open open
assert_equals "$(wake)$(state)" $'waiting\tship' "a taken step is waiting, not a wake"
rows open open open open open
assert_contains "$(wake)" "ship step" "a step that returns to open rings at once"
for pair in "closed open open open open:merged" "closed closed open open open:released" "closed closed closed open open:running" "closed closed closed closed open:proven"; do
  # shellcheck disable=SC2086  # the five statuses are separate words on purpose
  rows ${pair%%:*}
  assert_contains "$(wake)" "ready for its ${pair##*:} step" "step ${pair##*:} rings when its turn comes"
  assert_equals "$(wake)" "" "step ${pair##*:} rings once"
done
rows closed closed closed closed closed
assert_equals "$(wake)$(state)" $'finished\t' "every step closed is finished and raises nothing"
assert_absent "$H/data/jg-goal-loop/goal-a.next" "a finished Goal leaves no wake record"

# Resurface: the same open step rings again once the wait has run past the limit.
rows closed closed open open open
wake >/dev/null
assert_equals "$(wake)" "" "inside the limit the step stays quiet"
assert_contains "$(JG_GOAL_RESURFACE_SECS=0 "$LOOP" check "$H")" "released step" "past the limit the open step rings again"

# A stop is the owner's or a blocker's call: the check reports it as stopped and never raises a step.
rows closed open open open open on_hold
assert_equals "$(wake)" "" "a stopped Goal raises no step"
assert_equals "$(state)" $'stopped\tgoal-a.6' "state names the stop row"

# A closed Goal is ignored and its record goes.
rows open open open open open
wake >/dev/null
jq 'map(if .id == "goal-a" then .status = "closed" else . end)' "$ROWS" > "$ROWS.new" && mv "$ROWS.new" "$ROWS"
assert_equals "$(wake)" "" "a closed Goal raises nothing"
assert_equals "$(state)" "" "a closed Goal is not listed"
assert_absent "$H/data/jg-goal-loop/goal-a.next" "a closed Goal leaves no wake record"
printf '[]\n' > "$ROWS"
assert_equals "$(wake)" "" "an empty store is silent"

# A store that cannot be read: one wake per reason, the wrapper's text is the reason, a read that works clears it.
echo "jg-beads: bd is not the pinned bd 1.3.4" > "$ROWS.refuse"
out=$(wake)
assert_contains "$out" "the Goal store could not be read - jg-beads: bd is not the pinned bd 1.3.4" "the refusal text is the reason"
assert_equals "$(wake)" "" "the same refusal rings once"
echo "jg-beads: dolt is missing" > "$ROWS.refuse"
assert_contains "$(wake)" "dolt is missing" "a new reason rings"
rm -f "$ROWS.refuse"; wake >/dev/null
echo "jg-beads: dolt is missing" > "$ROWS.refuse"
assert_contains "$(wake)" "dolt is missing" "a refusal after a good read rings again"
rm -f "$ROWS.refuse"
echo "not json" > "$ROWS"
"$LOOP" check "$H" >/dev/null 2>&1
expect_code 1 "$?" "rows that are not JSON"

# Wiring: the shim runs the installed copy for this home, the check is registered, and unwiring removes all three.
mkdir -p "$T/w/bin" "$T/w/state" "$T/share"
cat > "$T/w/bin/jg-check-register.sh" <<'SH'
#!/bin/sh
echo "$1" >> "$JG_HOME/registered"
SH
cat > "$T/w/bin/jg-check-unregister.sh" <<'SH'
#!/bin/sh
rm -f "$JG_HOME/state/$1.check.sh"
SH
chmod +x "$T/w/bin/"*.sh
E=(env HOME="$T/user" XDG_DATA_HOME="$T/share")
"${E[@]}" "$ROOT/core/goal-loop/wiring.sh" --dry-run "$T/w" | grep -q "would copy" || fail "wiring dry run must say what it would do"
assert_absent "$T/w/state/goal-loop.check.sh" "a dry run writes nothing"
"${E[@]}" "$ROOT/core/goal-loop/wiring.sh" "$T/w" >/dev/null || fail "wiring"
"${E[@]}" "$ROOT/core/goal-loop/wiring.sh" "$T/w" >/dev/null || fail "wiring twice"
assert_equals "$(cat "$T/w/registered")" $'goal-loop\ngoal-loop' "the check is registered by name"
assert_contains "$(cat "$T/w/state/goal-loop.check.sh")" "$T/share/jg-goal-loop/goal-loop.sh check $T/w" "the shim runs the installed check for the home"
assert_equals "$(stat -c %a "$T/w/state/goal-loop.check.sh")" 700 "the shim is private"
"${E[@]}" "$ROOT/core/goal-loop/unwiring.sh" "$T/w" >/dev/null || fail "unwiring"
assert_absent "$T/w/state/goal-loop.check.sh" "unwiring removes the shim"
assert_absent "$T/share/jg-goal-loop" "unwiring removes the installed check"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  pass "goal-loop"
  exit 0
fi

# The real pinned store: a declared Goal walks from ship to proven as its step rows close.
export JG_GOAL_BIN=$ROOT/bin/jg-goal.sh JG_HOME=$H JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
mkdir -p "$T/real"
BEADS_DIR=$T/real/.beads "$ROOT/bin/jg-beads.sh" init --prefix goal >/dev/null 2>&1 || fail "init the store"
printf '%s\n' "$T/real/.beads" > "$H/config/goal-beads-dir"
id=$("$ROOT/bin/jg-goal.sh" declare --ask "make it live" --repo o/r -- test -f "$T/live") || fail "real declare"
assert_contains "$(wake)" "$id is ready for its ship step (make it live)" "a declared Goal rings for its first step"
steps=(ship merged released running proven)
for i in 0 1 2 3 4; do
  BEADS_DIR=$T/real/.beads "$ROOT/bin/jg-beads.sh" close "$id.$((i + 1))" --reason "test" >/dev/null 2>&1 || fail "close ${steps[$i]}"
  [ "$i" -lt 4 ] || break
  assert_contains "$(wake)" "ready for its ${steps[$((i + 1))]} step" "closing ${steps[$i]} moves the Goal on"
done
assert_equals "$(state)" $'finished\t' "the real Goal ends finished"
pass "goal-loop"
