#!/usr/bin/env bash
# tests/jg-finished-work.test.sh - finished work is never silently acknowledged (jg-279).
#
# The case that started it: Main swept two Recon done lines and the undelivered pages of their refused relays with one
# `jg-wake-drain.sh --outcomes-before <now> --classified handled`, and nothing brought them back for 30 minutes. Now:
#   1. the sweep is refused whole, and names each lane and the step it still owes, while any finished Recon in range owes one;
#   2. a Recon or critic done line with no next action in 10 minutes raises the done-unhandled P1, which an acknowledgement
#      never closes and only the step taken does (the turn-end guard cases are in tests/jg-turnend-guard.test.sh);
#   3. both read one definition, bin/jg-facts-lib.sh jg_fact_next_step, shown here for every lane and phase through the real
#      Recon handoff commands.
# Every step drives the real CLIs over a throwaway home: the drain, the undelivered-alert check, jg-move.sh,
# jg-recon-handoff.sh, jg-alert.sh and core/next-step/next-step.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/jg-wake-drain.sh"
TMP_ROOT=$(jg_test_tmproot jg-finished-work-tests)

# A home: its state and data directories under one case directory. Prints the case directory.
make_home() { # <name>
  local dir
  dir=$(make_case "$1"); mkdir -p "$dir/data"
  printf '%s\n' "$dir"
}
drain() { # <dir> <drain arguments>
  local dir=$1; shift
  JG_STATE_OVERRIDE="$dir/state" JG_DATA_OVERRIDE="$dir/data" "$DRAIN" "$@"
}
nxt() { # <dir> <next-step command>
  local dir=$1; shift
  JG_STATE_OVERRIDE="$dir/state" JG_DATA_OVERRIDE="$dir/data" bash "$ROOT/core/next-step/next-step.sh" "$@" "$dir"
}
alertcmd() { # <dir> <jg-alert arguments>
  local dir=$1; shift
  JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" bash "$ROOT/bin/jg-alert.sh" "$@"
}
relay() { # <dir> <ticket>: the one step Main takes to relay a Recon's findings (bin/jg-move.sh records it)
  JG_HOME="$1" JG_DATA_OVERRIDE="$1/data" bash "$ROOT/bin/jg-move.sh" "$2" relayed
}
fact() { # <dir> <lane>
  JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" JG_DATA_OVERRIDE="$1/data" bash "$ROOT/bin/jg-machine-guard.sh" fact next-step "$2"
}
val() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { print $2; exit }'; }
status_line() { # <dir> <lane> <verb> <epoch> <text>
  printf '%s [at=%s]: %s\n' "$3" "$4" "$5" >> "$1/state/$2.status"
}
add_lane() { # <dir> <lane> <ticket> <kind>
  printf 'kind=%s\nticket=%s\n' "$4" "$3" > "$1/state/$2.meta"
  mkdir -p "$1/data/$2"
}
signal() { # <dir> <lane>
  append_wake "$1/state" signal "$2.status" "signal: $2.status" >/dev/null || fail "could not queue the signal row of $2"
}

check_step() { # <facts> <want> <what>
  local got; got=$(val "$1" step)
  [ "$got" = "$2" ] || fail "$3: wanted step $2, got $got ($(val "$1" reason))"
}

# A captain message the voice check refused: the row the captain channel keeps, and the real undelivered-alert check over it.
refuse_captain_message() { # <dir> <ticket> <expected page number>
  local dir=$1
  printf '{"at":%s,"target":"captain","error":"voice check refused the Recon report","event":{"kind":"recon-report","key":"%s"}}\n' \
    "$(date +%s)" "$2" >> "$dir/state/captain-channel-undelivered.jsonl"
  bash "$ROOT/core/undelivered-alert/undelivered-alert.sh" check "$dir" || fail "the undelivered-alert check failed"
  [ "$(alertcmd "$dir" word "undelivered--captain-message-$3")" = open ] || fail "the refused message $3 did not raise its page"
}

# --- 1. the sweep, replaying the case ----------------------------------------------------------------------------------------
test_a_sweep_over_two_finished_recons_is_refused_and_named() {
  local dir state now cut n
  dir=$(make_home replay); state=$dir/state; now=$(date +%s)
  add_lane "$dir" rec-a T-a scout; add_lane "$dir" rec-b T-b scout
  status_line "$dir" rec-a working $((now - 900)) reading
  status_line "$dir" rec-a "done" $((now - 800)) "report ready in data/rec-a/report.md"
  status_line "$dir" rec-b "done" $((now - 700)) "report ready in data/rec-b/report.md"
  signal "$dir" rec-a; signal "$dir" rec-b
  : > "$state/captain-channel-undelivered.jsonl"
  bash "$ROOT/core/undelivered-alert/undelivered-alert.sh" check "$dir" || fail "the first undelivered-alert run failed"   # records the count
  refuse_captain_message "$dir" T-a 1
  refuse_captain_message "$dir" T-b 2
  drain "$dir" > "$dir/out" 2> "$dir/err" || fail "the drain failed: $(tail -3 "$dir/err")"
  grep -F 'alert-undelivered--captain-message-1' "$dir/out" >/dev/null || fail "the first undelivered page was not presented"
  grep -F 'alert-undelivered--captain-message-2' "$dir/out" >/dev/null || fail "the second undelivered page was not presented"
  [ "$(grep -c '^OUTCOME_REQUIRED: ' "$dir/out")" = 2 ] || fail "the two done lines are not two open outcomes"
  cut=$(( $(date +%s) + 1 ))

  # The sweep Main ran: refused whole, nothing classified, both lanes named with the step and how to take it.
  drain "$dir" --outcomes-before "$cut" --classified handled > "$dir/sweep.out" 2> "$dir/sweep.err"; n=$?
  expect_code 3 "$n" "the sweep over two finished Recons must be refused"
  assert_contains "$(cat "$dir/sweep.err")" 'sweep refused; 2 finished lane(s)' "the refusal must count the lanes"
  assert_contains "$(cat "$dir/sweep.err")" 'rec-a: relay owed by Main - relay the findings, then record it: bin/jg-move.sh T-a relayed' "the refusal must name rec-a and its step"
  assert_contains "$(cat "$dir/sweep.err")" 'rec-b: relay owed by Main - relay the findings, then record it: bin/jg-move.sh T-b relayed' "the refusal must name rec-b and its step"
  assert_not_contains "$(cat "$dir/sweep.err")" 'bulk classification failed' "a refused sweep is not a malformed one"
  [ "$(jq '[.[].events[] | select(.disposition != null)] | length' "$state/.wake-status-main.json")" = 0 ] \
    || fail "a refused sweep classified an outcome"
  if ack_drain_err "$state" "$dir/err" 2> "$dir/ack.err"; then fail "the acknowledgement landed over two open outcomes"; fi
  grep -F 'acknowledgement refused; 2 outcome(s) in 2 task(s)' "$dir/ack.err" >/dev/null || fail "the outcomes are not still open: $(head -2 "$dir/ack.err")"
  [ "$(alertcmd "$dir" word undelivered--captain-message-1)" = open ] || fail "the refused sweep closed an undelivered page"

  # Taking one step narrows the refusal to the other lane; taking both lets the same sweep through.
  relay "$dir" T-a || fail "could not record the relay of rec-a"
  drain "$dir" --outcomes-before "$cut" --classified handled > /dev/null 2> "$dir/sweep2.err" && fail "the sweep passed with rec-b unrelayed"
  assert_contains "$(cat "$dir/sweep2.err")" 'sweep refused; 1 finished lane(s)' "one lane is left"
  assert_not_contains "$(cat "$dir/sweep2.err")" 'rec-a:' "a relayed Recon is no longer named"
  assert_contains "$(cat "$dir/sweep2.err")" 'rec-b: relay owed by Main' "the unrelayed one is still named"
  relay "$dir" T-b || fail "could not record the relay of rec-b"
  drain "$dir" --outcomes-before "$cut" --classified handled > "$dir/sweep3.out" 2>&1 || fail "the sweep refused after both relays: $(cat "$dir/sweep3.out")"
  assert_contains "$(cat "$dir/sweep3.out")" "classified 2 outcome(s) presented before $cut" "the sweep classifies both once they are relayed"
  pass "a sweep over two finished Recons and their undelivered pages is refused and names both, nothing is classified, and each relay narrows it until it passes"
}

# What the sweep always did still holds: a ship lane's done line, a lane with no record and an unrelated Recon note are classified as before.
test_a_sweep_with_nothing_owed_still_classifies() {
  local dir state now cut
  dir=$(make_home sweep-clean); state=$dir/state; now=$(date +%s)
  add_lane "$dir" ship-1 T-s ship
  status_line "$dir" ship-1 "done" $((now - 100)) "ready in branch fix/x (local-trunk)"
  status_line "$dir" nometa "done" $((now - 100)) "a lane with no record here"
  add_lane "$dir" rec-w T-w scout
  status_line "$dir" rec-w "done" $((now - 100)) "report ready"
  status_line "$dir" rec-w working $((now - 50)) "taking the follow-up the owner asked for"
  signal "$dir" ship-1; signal "$dir" nometa; signal "$dir" rec-w
  drain "$dir" > "$dir/out" 2> "$dir/err" || fail "the drain failed: $(tail -3 "$dir/err")"
  cut=$(( $(date +%s) + 1 ))
  drain "$dir" --outcomes-before "$cut" --classified 'bulk: read in the digest' > "$dir/sweep" 2>&1 || fail "the sweep was refused with nothing owed: $(cat "$dir/sweep")"
  assert_contains "$(cat "$dir/sweep")" "classified 3 outcome(s) presented before $cut" "the ship lane's, the record-less lane's and the resumed Recon's done lines are classified"
  pass "a sweep with no finished Recon owing a step classifies as before (a ship done line, a lane with no record, a Recon that went back to work)"
}

# --- 2. the P1 alert -----------------------------------------------------------------------------------------------------------
test_a_done_line_with_no_next_action_raises_a_p1_that_only_the_step_closes() {
  local dir state now rec
  dir=$(make_home p1); state=$dir/state; now=$(date +%s)
  add_lane "$dir" rec-a T-a scout; add_lane "$dir" rec-b T-b scout
  status_line "$dir" rec-a "done" $((now - 700)) "report ready"
  status_line "$dir" rec-b "done" $((now - 100)) "report ready"
  nxt "$dir" tick || fail "the tick failed"
  [ "$(alertcmd "$dir" word done-unhandled--rec-a)" = open ] || fail "a Recon done line 700 s old with no relay raised no alert"
  [ -z "$(alertcmd "$dir" word done-unhandled--rec-b 2>/dev/null)" ] || fail "a done line 100 s old raised an alert before its 10 minutes"
  rec=$(alertcmd "$dir" show done-unhandled--rec-a)
  assert_contains "$rec" 'precedence=P1' "the alert is a P1"
  assert_contains "$rec" 'rung=3' "its first holder is Main"
  assert_contains "$rec" 'ticket=T-a' "it names the Recon's ticket"
  assert_contains "$rec" 'bin/jg-move.sh T-a relayed' "it says how the step is taken"
  drain "$dir" > "$dir/out" 2>&1 || fail "the drain failed"
  grep -F 'done-unhandled--rec-a' "$dir/out" >/dev/null || fail "the page did not reach the wake queue Main drains"

  # Nothing but the step closes it: not an acknowledgement, not a drained and acknowledged wake row, not another tick.
  alertcmd "$dir" ack done-unhandled--rec-a > /dev/null || fail "could not acknowledge the alert"
  ack_drain_err "$state" "$dir/out" > /dev/null 2>&1 || true
  nxt "$dir" tick || fail "the second tick failed"
  [ "$(alertcmd "$dir" word done-unhandled--rec-a)" = acknowledged ] || fail "an acknowledged, drained page was closed without the step: $(alertcmd "$dir" word done-unhandled--rec-a)"
  nxt "$dir" open > "$dir/open" || fail "the open list is empty while the alert is live"
  assert_contains "$(cat "$dir/open")" 'rec-a: relay owed by Main' "the open list names the lane and its step"

  relay "$dir" T-a || fail "could not record the relay"
  nxt "$dir" tick || fail "the tick after the relay failed"
  [ "$(alertcmd "$dir" word done-unhandled--rec-a)" = resolved ] || fail "the relay did not close the alert"
  assert_contains "$(alertcmd "$dir" show done-unhandled--rec-a)" 'relayed' "the close names the relay as its proof"
  nxt "$dir" open > /dev/null && fail "the open list still holds a closed alert"
  pass "a done Recon line with no relay in 10 minutes raises one P1 to Main that an acknowledgement and a drained wake never close, and the relay does"
}

# --- 3. one definition, every lane and phase ----------------------------------------------------------------------------------
test_the_one_definition_names_the_step_of_every_lane_and_phase() {
  local dir now h f
  dir=$(make_home table); now=$(date +%s); h="$ROOT/bin/jg-recon-handoff.sh"
  handoff() { JG_HOME="$dir" JG_DATA_OVERRIDE="$dir/data" bash "$h" "$@" > /dev/null || fail "jg-recon-handoff.sh $* failed"; }
  add_lane "$dir" rec-d T-d scout; add_lane "$dir" crit-1 T-c1 scout; add_lane "$dir" crit-2 T-c2 scout
  status_line "$dir" rec-d "done" $((now - 900)) "draft ready"
  status_line "$dir" crit-1 working $((now - 900)) "reading the draft"
  f=$(fact "$dir" rec-d); check_step "$f" relay "a Recon with no handoff record owes the relay"
  printf 'v1\n' > "$dir/data/rec-d/report.md"
  handoff draft rec-d
  f=$(fact "$dir" rec-d); check_step "$f" assign "a drafted Recon owes a critic"; assert_contains "$(val "$f" owner)" 'the lead' "the lead names the critic"
  handoff assign rec-d --critic crit-1
  f=$(fact "$dir" rec-d); check_step "$f" none "a Recon whose critic holds the draft owes nothing"
  f=$(fact "$dir" crit-1); check_step "$f" none "a critic still working owes nothing"
  status_line "$dir" crit-1 "done" $((now - 5)) "verdict ready"
  f=$(fact "$dir" crit-1); check_step "$f" verdict "a critic done with no verdict recorded owes it"
  handoff verdict rec-d --critic crit-1 --hash "$(sha256sum "$dir/data/rec-d/report.md" | cut -d' ' -f1)" --gaps 2
  f=$(fact "$dir" crit-1); check_step "$f" revise "a critic whose verdict found gaps leaves the revision owed"; assert_contains "$(val "$f" owner)" 'the researcher' "the researcher revises"
  f=$(fact "$dir" rec-d); check_step "$f" revise "the Recon owes the same revision"
  printf 'v2\n' > "$dir/data/rec-d/report.md"
  handoff revise rec-d
  f=$(fact "$dir" crit-1); check_step "$f" none "a verdict that was acted on owes nothing"
  f=$(fact "$dir" rec-d); check_step "$f" assign "the revised draft owes a critic again"
  add_lane "$dir" crit-2 T-c2 scout
  handoff assign rec-d --critic crit-2
  status_line "$dir" crit-2 "done" $((now - 1)) "verdict ready"
  handoff verdict rec-d --critic crit-2 --hash "$(sha256sum "$dir/data/rec-d/report.md" | cut -d' ' -f1)" --gaps 0
  f=$(fact "$dir" crit-2); check_step "$f" relay "an accepted draft leaves the relay owed"; assert_contains "$(val "$f" how)" 'bin/jg-move.sh T-d relayed' "the relay is recorded on the Recon's ticket"
  f=$(fact "$dir" rec-d); check_step "$f" relay "the Recon owes the same relay"
  relay "$dir" T-d || fail "could not record the relay"
  f=$(fact "$dir" crit-2); check_step "$f" none "the relay takes the step for the critic's lane"
  f=$(fact "$dir" rec-d); check_step "$f" none "and for the Recon's"
  f=$(fact "$dir" ghost); check_step "$f" none "a lane with no record owes nothing"
  pass "the one definition names relay, assign, verdict and revise for each lane and phase, and each move of the real handoff takes the step"
}
test_a_sweep_over_two_finished_recons_is_refused_and_named
test_a_sweep_with_nothing_owed_still_classifies
test_a_done_line_with_no_next_action_raises_a_p1_that_only_the_step_closes
test_the_one_definition_names_the_step_of_every_lane_and_phase

echo "# jg-finished-work.test.sh: all assertions passed"
