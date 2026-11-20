#!/usr/bin/env bash
# Behavior tests for bin/jg-goal.sh. The guards run against a recording stand-in for the tables' bd_compat.py
# (JG_GOAL_BEADS_BIN); the real cases run on the home's tickets tables. Every home sits in a throwaway folder
# outside any git tree.
# This is also the test that owns journeys/goal-loop.sh (the done-done journey that drives a Goal from
# ask to one finish message on a fake forge), so a change to that journey selects this script.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GOAL="$ROOT/bin/jg-goal.sh" T=$(jg_test_tmproot jg-goal)
mkdir -p "$T/home/config" "$T/home/data"
export JG_HOME=$T/home LOG=$T/beads.log
unset JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE
COMPAT=$ROOT/core/item-store/adapters/bd_compat.py

# The journey this test owns ships with it, and runs under done-done where the pinned tools are set up.
# No CI lane parses journeys/, so this owner is the cheap gate that it is present and still parses.
[ -x "$ROOT/journeys/goal-loop.sh" ] || fail 'journeys/goal-loop.sh is missing or not executable'
bash -n "$ROOT/journeys/goal-loop.sh" || fail 'journeys/goal-loop.sh does not parse'
pass 'the goal-loop journey is present and parses'

# A stand-in for the tables: it records each call.
cat > "$T/beads" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG"
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

# A home whose tables do not exist yet: the tables' refusal is the message, and no Goal starts.
out=$("$GOAL" declare --ask x --repo o/r -- false 2>&1)
expect_code 2 "$?" "a home with no tables"
assert_contains "$out" "tickets: no tables" "the tables' refusal must be the message"
assert_contains "$out" "Goal store is not ready" "declare must say it stopped"
assert_absent "$LOG" "a home with no tables must not start a Goal"
python3 -I "$COMPAT" create "seed row" --id goal-seed --force >/dev/null || fail "make the home's tables"

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

pass "jg-goal guards"

# The real tables of the home, and a second home for the fold.
unset JG_GOAL_BEADS_BIN
rm -rf "$T/home/data/goals"
mkdir -p "$T/fold/config" "$T/fold/data"
real() { python3 -I "$COMPAT" "$@" 2>/dev/null; }
id=$("$GOAL" declare --ask "make it live" --repo o/r --where "this home" --attempts 4 -- test -f "$T/live") || fail "real declare"
out=$("$GOAL" show "$id")
assert_contains "$out" "ask: make it live" "show must print the ask"
assert_contains "$out" "state: open" "a new Goal is open"
assert_contains "$out" "proof: test -f $T/live" "show must print the proof"
for step in ship merged released running proven; do assert_contains "$out" "$step open" "step $step"; done
assert_contains "$("$GOAL" show)" "make it live" "show with no id lists the open Goals"
rows=$(real show "$id" --json 2>/dev/null)
assert_equals "$(jq -r '.[0].metadata.goal.limits.attempts' <<< "$rows")" 4 "the attempts limit is kept, and the fix steps default"
assert_equals "$(jq -r '.[0].metadata.goal.limits.fix_steps' <<< "$rows")" 5 "the fix steps limit defaults to 5"
assert_equals "$(jq -c .proof "$T/home/data/goals/$id/finish.json" | tr -d '\n')" "[\"test\",\"-f\",\"$T/live\"]" "the finish line is on disk"
hash=$(jq -r '.[0].metadata.goal.finish_hash' <<< "$rows")
assert_equals "$(jq -Sc . "$T/home/data/goals/$id/finish.json" | tr -d '\n' | sha256sum | cut -d' ' -f1)" "$hash" "the stored hash is the hash of the finish line"
ready=$(real ready --parent "$id" --json 2>/dev/null | jq -r '.[].title')
assert_equals "$ready" "ship" "only the first step is ready"

# The fold: a second home takes the Goal by export and import with its ids, edges and finish line.
real export > "$T/goals.jsonl" || fail "export the Goal rows"
JG_HOME=$T/fold python3 -I "$COMPAT" import "$T/goals.jsonl" >/dev/null 2>&1 || fail "import into the second home"
assert_equals "$(JG_HOME=$T/fold "$GOAL" show "$id")" "$out" "the second home must show the same Goal"
folded=$(JG_HOME=$T/fold python3 -I "$COMPAT" show "$id" --json 2>/dev/null)
assert_equals "$(jq -r '.[0].metadata.goal.finish_hash' <<< "$folded")" "$hash" "the fold must keep the finish line hash"
assert_equals "$(JG_HOME=$T/fold python3 -I "$COMPAT" ready --parent "$id" --json 2>/dev/null | jq -r '.[].title')" "ship" "the fold must keep the step order"

# The released ref is kept on the epic, and the finish message claims it live only where the release record names it.
fails "needs a Goal id and the released ref" released "$id"
assert_equals "$("$GOAL" released "$id" v9)" "released $id: v9" "released must say what it kept"
rows=$(real show "$id" --json 2>/dev/null)
assert_equals "$(jq -r '.[0].metadata.released_ref' <<< "$rows")" v9 "the released ref is on the epic"
close_steps() {  # <goal>: close every step, as the lead and the proof would
  for row in $(real list --parent "$1" --json 2>/dev/null | jq -r '.[].id' | sort); do
    "$ROOT/bin/jg-backlog.sh" "done" "$row" >/dev/null 2>&1
  done
}
mkdir -p "$T/probes"
export JG_LIVE_SERVICES_PROBES=$T/probes
fin=$("$GOAL" declare --ask "ref goal" --repo o/r --where "this home" -- false) || fail "declare the finish goal"
"$GOAL" released "$fin" v9 >/dev/null
close_steps "$fin"
assert_contains "$("$GOAL" finish "$fin")" "Landed, not in use: the Goal is done: ref goal - Released, v9; live: v9 @ this home" "a ref the release record does not name is not live"
fin=$("$GOAL" declare --ask "ref goal" --repo o/r --where "this home" -- false) || fail "declare the second finish goal"
"$GOAL" released "$fin" v9 >/dev/null
close_steps "$fin"
printf 'v9 prs=1\n' > "$T/home/data/releases"
assert_contains "$("$GOAL" finish "$fin")" "finished - the Goal is done: ref goal - Released, v9; live: v9 @ this home; carries: #1; waiting: none" "a recorded ref in running services is live"
unset JG_LIVE_SERVICES_PROBES

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
