#!/usr/bin/env bash
# tests/jg-hold-reason-gate.test.sh - a hold carries a reason: a blank one is
# refused on both hold paths, and a real one reaches the board with its ticket
# named (bin/jg-captain-hold.sh, bin/jg-tasks-axi.sh, bin/jg-procevent-signoff.sh).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
TASKS_AXI_BIN=$(command -v tasks-axi)
TMP_ROOT=$(jg_test_tmproot jg-hold-reason)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

setup() {  # <name> -> the case dir
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/data" "$d/home/state" "$d/home/config" "$d/fakebin"
  jg_test_tasks_toml "$d/home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$d/home/data/backlog.md"
  cat > "$d/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SIGNOFF_LOG"
case "${1-}" in --version) echo 'sign-off-axi stub' ;; raise) echo raised ;; esac
SH
  chmod +x "$d/fakebin/sign-off-axi"
  printf '%s\n' "$d"
}

run() {  # <case dir> <command...>
  local d=$1
  shift
  env PATH="$d/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" JG_CODE_ROOT="$ROOT" \
    JG_HOME="$d/home" JG_ROOT_OVERRIDE="$ROOT" \
    JG_STATE_OVERRIDE="$d/home/state" JG_DATA_OVERRIDE="$d/home/data" \
    JG_CONFIG_OVERRIDE="$d/home/config" SIGNOFF_LOG="$d/signoff.log" "$@" 2>&1
}

test_a_blank_reason_is_refused_before_anything_is_recorded() {
  local d out
  d=$(setup blank)
  out=$(run "$d" "$ROOT/bin/jg-captain-hold.sh" hold ask-a --title "Which name?" --reason '   ') \
    && fail "a blank reason held a task: $out"
  assert_contains "$out" 'what the captain has to decide' "the refusal did not say what is missing"
  assert_no_grep 'ask-a' "$d/home/data/backlog.md" "a refused hold still wrote the row"
  out=$(run "$d" "$ROOT/bin/jg-captain-hold.sh" hold ask-b --title "Which name?") \
    && fail "a missing reason held a task: $out"
  pass "a hold with no readable reason is refused and nothing is recorded"
}

test_the_tasks_axi_hold_path_refuses_a_blank_reason() {
  local d out
  d=$(setup taxi)
  out=$(run "$d" "$ROOT/bin/jg-tasks-axi.sh" hold task-a --reason '  ') && fail "the tasks-axi hold path accepted a blank reason: $out"
  assert_contains "$out" 'a hold needs a non-blank --reason' "the second path did not name the missing reason"
  pass "the tasks-axi hold path refuses a blank reason too"
}

test_a_real_reason_reaches_the_board_with_its_ticket() {
  local d out log ticket
  d=$(setup feed)
  run "$d" "$ROOT/bin/jg-tasks-axi.sh" add ship-a "[feature] Ship the page" \
    --body "Why: the page is the way a reader reaches the tool." >/dev/null 2>&1 \
    || fail "the fixture could not create its task"
  mkdir -p "$d/home/state/procevent"
  : > "$d/home/state/procevent/signoff.source"
  # core/signoff is the default card path and posts only an authored owner ask, so
  # this test names the one card path (bin/jg-question-card.sh post) through the
  # JG_SIGNOFF_SCRIPT seam that bin/jg-captain-hold.sh documents.
  out=$(run "$d" env JG_SIGNOFF_SCRIPT="$ROOT/bin/jg-procevent-signoff.sh" "$ROOT/bin/jg-captain-hold.sh" hold ship-a --must design-pick --reason "Pick the launch word or it waits") \
    || fail "a real reason was refused: $out"
  log=$(cat "$d/signoff.log" 2>/dev/null)
  assert_contains "$log" 'Pick the launch word or it waits' "the hold's reason did not reach the board"
  ticket=$(run "$d" "$ROOT/bin/jg-ticket.sh" id ship-a)
  assert_contains "$log" "--ticket $ticket" "the card does not name the ticket it puts on hold"
  pass "a real hold reason reaches the board, and its card names the ticket"
}

test_a_blank_reason_is_refused_before_anything_is_recorded
test_the_tasks_axi_hold_path_refuses_a_blank_reason
test_a_real_reason_reaches_the_board_with_its_ticket
