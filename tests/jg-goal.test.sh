#!/usr/bin/env bash
# Behavior tests for bin/jg-goal.sh. The guards run against a recording stand-in for bin/jg-beads.sh.
# The real store cases need the pinned builds named by JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT, and skip
# plainly without them. Every store sits in a throwaway folder outside any git tree.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GOAL="$ROOT/bin/jg-goal.sh" T=$(jg_test_tmproot jg-goal)
mkdir -p "$T/home/config" "$T/home/data"
export JG_HOME=$T/home LOG=$T/beads.log
unset JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE GOAL_BEADS_DIR

# A stand-in wrapper: it records each call, and its `check` can refuse as the real one does with an unpinned tool.
cat > "$T/beads" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG"
if [ "$1" = check ] && [ -e "$LOG.refuse" ]; then echo "jg-beads: bd is not the pinned bd 1.3.4" >&2; exit 2; fi
[ "$1" != create ] || echo goal-fake
SH
chmod +x "$T/beads"
export JG_GOAL_BEADS_BIN=$T/beads
fails() {  # <wanted text> <args...>: refused with exit 2, naming the reason.
  local want=$1 out code
  shift
  out=$("$GOAL" "$@" 2>&1)
  code=$?
  expect_code 2 "$code" "$*"
  assert_contains "$out" "$want" "$*"
}

# Declare judges the proof before it touches any store.
rm -f "$LOG"
fails "needs --ask" declare --repo o/r -- false
fails "needs --repo" declare --ask x -- false
fails "needs a proof command" declare --ask x --repo o/r
fails "already exits 0" declare --ask x --repo o/r -- true
fails "cannot run (exit 127)" declare --ask x --repo o/r -- /nonexistent/proof
fails "cannot run (exit 126)" declare --ask x --repo o/r -- "$T"
fails "limits must be whole numbers" declare --ask x --repo o/r --attempts 0 -- false
assert_absent "$LOG" "a refused proof must not reach the store"

# A home with no store named, then a store the wrapper refuses.
fails "no Goal store" declare --ask x --repo o/r -- false
printf '%s\n' "$T/store/.beads" > "$T/home/config/goal-beads-dir"
touch "$LOG.refuse"
out=$("$GOAL" declare --ask x --repo o/r -- false 2>&1)
expect_code 2 "$?" "an unpinned tool"
assert_contains "$out" "is not the pinned bd 1.3.4" "the wrapper's refusal must be the message"
assert_contains "$out" "Goal store is not ready" "declare must say it stopped"
assert_not_contains "$(cat "$LOG")" create "an unpinned tool must not start a Goal"
rm -f "$LOG.refuse"

# Declare writes the epic, five blocked steps and the finish record.
rm -f "$LOG"
out=$("$GOAL" declare --ask "ship it" --repo o/r -- false) || fail "declare against the stand-in"
assert_equals "$out" "goal-fake" "declare must print the Goal id"
assert_contains "$(cat "$LOG")" "create Goal: ship it -t epic --labels goal" "the Goal is a labelled epic"
assert_equals "$(grep -c '^create ' "$LOG")" 6 "an epic and five steps"
assert_equals "$(grep -c '^dep add ' "$LOG")" 4 "each step waits on the one before"
assert_equals "$(jq -c .proof "$T/home/data/goals/goal-fake/finish.json")" '["false"]' "the finish line is recorded"
printf '#!/bin/sh\nexit 1\n' > "$T/p.sh"; chmod +x "$T/p.sh"
"$GOAL" declare --ask "ship it" --repo o/r -- "$T/p.sh" >/dev/null || fail "declare with a proof script"
assert_present "$T/home/data/goals/goal-fake/proof-script" "the proof script is copied beside the finish line"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  pass "jg-goal guards"
  exit 0
fi

# The real pinned tools, through the real wrapper.
unset JG_GOAL_BEADS_BIN
export JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
mkdir -p "$T/real" "$T/fold"
rm -rf "$T/home/data/goals"
for s in real fold; do
  BEADS_DIR=$T/$s/.beads "$ROOT/bin/jg-beads.sh" init --prefix goal >/dev/null 2>&1 || fail "init the $s store"
done
printf '%s\n' "$T/real/.beads" > "$T/home/config/goal-beads-dir"
id=$("$GOAL" declare --ask "make it live" --repo o/r --where "this home" --attempts 4 -- test -f "$T/live") || fail "real declare"
out=$("$GOAL" show "$id")
assert_contains "$out" "ask: make it live" "show must print the ask"
assert_contains "$out" "state: open" "a new Goal is open"
assert_contains "$out" "proof: test -f $T/live" "show must print the proof"
for step in ship merged released running proven; do assert_contains "$out" "$step open" "step $step"; done
assert_contains "$("$GOAL" show)" "make it live" "show with no id lists the open Goals"
rows=$(BEADS_DIR=$T/real/.beads "$ROOT/bin/jg-beads.sh" show "$id" --json 2>/dev/null)
assert_equals "$(jq -r '.[0].metadata.goal.limits.attempts' <<< "$rows")" 4 "the attempts limit is kept, and the fix steps default"
assert_equals "$(jq -r '.[0].metadata.goal.limits.fix_steps' <<< "$rows")" 5 "the fix steps limit defaults to 5"
assert_equals "$(jq -c .proof "$T/home/data/goals/$id/finish.json" | tr -d '\n')" "[\"test\",\"-f\",\"$T/live\"]" "the finish line is on disk"
hash=$(jq -r '.[0].metadata.goal.finish_hash' <<< "$rows")
assert_equals "$(jq -Sc . "$T/home/data/goals/$id/finish.json" | tr -d '\n' | sha256sum | cut -d' ' -f1)" "$hash" "the stored hash is the hash of the finish line"
ready=$(BEADS_DIR=$T/real/.beads "$ROOT/bin/jg-beads.sh" ready --parent "$id" --json 2>/dev/null | jq -r '.[].title')
assert_equals "$ready" "ship" "only the first step is ready"

# The fold: a second store takes the Goal by export and import with its ids, edges and finish line.
BEADS_DIR=$T/real/.beads "$ROOT/bin/jg-beads.sh" export > "$T/goals.jsonl" 2>/dev/null || fail "export the Goal store"
BEADS_DIR=$T/fold/.beads "$ROOT/bin/jg-beads.sh" import "$T/goals.jsonl" >/dev/null 2>&1 || fail "import into the second store"
assert_equals "$(GOAL_BEADS_DIR=$T/fold/.beads "$GOAL" show "$id")" "$out" "the second store must show the same Goal"
folded=$(BEADS_DIR=$T/fold/.beads "$ROOT/bin/jg-beads.sh" show "$id" --json 2>/dev/null)
assert_equals "$(jq -r '.[0].metadata.goal.finish_hash' <<< "$folded")" "$hash" "the fold must keep the finish line hash"
assert_equals "$(BEADS_DIR=$T/fold/.beads "$ROOT/bin/jg-beads.sh" ready --parent "$id" --json 2>/dev/null | jq -r '.[].title')" "ship" "the fold must keep the step order"

# Cancel closes the open rows and the epic, and tears nothing down.
mkdir -p "$T/work/tree" && echo unlanded > "$T/work/tree/change.txt"
"$GOAL" cancel "$id" 2>/dev/null && fail "cancel must name a reason"
out=$("$GOAL" cancel "$id" --reason "owner said stop") || fail "real cancel"
assert_contains "$out" "cancelled $id" "cancel must say so"
out=$("$GOAL" show "$id")
assert_contains "$out" "state: closed" "a cancelled Goal is closed"
assert_not_contains "$out" " open" "no step stays open"
assert_equals "$(cat "$T/work/tree/change.txt")" unlanded "cancel must leave work in place"
assert_equals "$("$GOAL" show)" "" "a cancelled Goal leaves the open list"
out=$("$GOAL" cancel goal-none --reason x 2>&1)
expect_code 2 "$?" "cancel of an unknown Goal"
assert_contains "$out" "no Goal goal-none" "cancel must name the missing Goal"
pass "jg-goal"
