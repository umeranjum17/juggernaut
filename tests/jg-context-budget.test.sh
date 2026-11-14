#!/usr/bin/env bash
# bin/jg-context-load.sh and the ceilings of defaults/token-caps, through their real callers:
# the shipped tree is green at today's values; a fixture file one byte over a line fails and
# names it; a made-up Claude Code transcript prints its known total and is recorded once per
# role and day; a reading over its line fails; a home line overrides a shipped one; the brief
# lint takes its budget from the ceiling; the daily growth check reports a ceiling that is over.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(jg_test_tmproot jg-context-budget)
LOAD="$ROOT/bin/jg-context-load.sh"
CAP=$("$LOAD" cap ctx-agents-md) || fail "defaults/token-caps has no ctx-agents-md line"

# A fixture home: a root holding AGENTS.md of <bytes> bytes, its own data and config folders.
home() {  # <name> <agents-md-bytes>
  local h=$TMP_ROOT/$1
  mkdir -p "$h/root" "$h/data" "$h/config" "$h/state"
  head -c "$2" /dev/zero | tr '\0' 'x' > "$h/root/AGENTS.md"
  echo "$h"
}
load() {  # <home> <args>...
  local h=$1; shift
  JG_HOME="$h" JG_ROOT_OVERRIDE="$h/root" JG_DATA_OVERRIDE="$h/data" JG_CONFIG_OVERRIDE="$h/config" \
    JG_CONTEXT_LOAD_DATE=2026-11-14 "$LOAD" "$@"
}

test_shipped_tree_is_green() {
  local out code
  out=$("$LOAD" check); code=$?
  assert_equals 0 "$code" "the shipped tree is within each ceiling: $out"
  assert_contains "$out" "ok ctx-agents-md $(wc -c < "$ROOT/AGENTS.md" | tr -d ' ') $CAP measured" "AGENTS.md is measured against its line"
  pass "the test is green on today's tree with today's values as ceilings"
}

test_one_byte_over_fails_and_names_the_line() {
  local h out code
  h=$(home at "$CAP")
  out=$(load "$h" check); code=$?
  assert_equals 0 "$code" "a file at its ceiling passes"
  h=$(home over "$((CAP + 1))")
  out=$(load "$h" check); code=$?
  assert_equals 1 "$code" "a file one byte over its ceiling fails"
  assert_contains "$out" "over ctx-agents-md $((CAP + 1)) $CAP measured" "the line is named with its value and ceiling"
  assert_contains "$out" "over ctx-supervisor-contract $((CAP + 1))" "the supervisor contract line holds the same file"
  pass "a fixture file one byte over a line fails and names it"
}

test_reader_prints_known_total_and_records_once_a_day() {
  local h f out rows
  h=$(home read 10); f=$TMP_ROOT/session.jsonl
  {
    echo '{"type":"api-request-shape","shape":{"tools":[{"name":"Bash"},{"name":"Read"}]}}'
    echo '{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":3,"cache_creation_input_tokens":4000,"cache_read_input_tokens":1000}}}'
    echo '{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":9,"cache_creation_input_tokens":9,"cache_read_input_tokens":9}}}'
  } > "$f"
  out=$(load "$h" read "$f" worker)
  assert_contains "$out" "worker first call: 5003 tokens" "the first model call's three counts are summed"
  out=$(load "$h" read "$f" worker)
  assert_contains "$out" "already read: worker ctx-worker-first-call on 2026-11-14" "a repeat the same day is refused"
  load "$h" read "$f" lead >/dev/null
  rows=$(wc -l < "$h/data/context-load.tsv" | tr -d ' ')
  assert_equals 4 "$rows" "one first-call and one tool-schema row for each of two roles"
  assert_equals "2026-11-14	worker	ctx-worker-first-call	5003	tok	session.jsonl" "$(sed -n 1p "$h/data/context-load.tsv")" "the row names date, role, item, value, unit and source"
  out=$(load "$h" read "$TMP_ROOT/none.jsonl" worker 2>&1); [ $? -eq 2 ] || fail "an unreadable transcript exits 2"
  out=$(load "$h" read "$f" cook 2>&1); [ $? -eq 2 ] || fail "an unknown role exits 2"
  pass "a made-up session record prints its known total and is kept once per role per day"
}

test_reading_over_its_line_fails_and_home_line_overrides() {
  local h out code
  h=$(home reading 10)
  load "$h" record worker ctx-worker-first-call 64731 tok >/dev/null
  out=$(load "$h" check); code=$?
  assert_equals 0 "$code" "a reading at its ceiling passes: $out"
  load "$h" record worker ctx-worker-first-call 64732 tok 2026-11-15 >/dev/null
  out=$(load "$h" check); code=$?
  assert_equals 1 "$code" "a newer reading one token over fails"
  assert_contains "$out" "over ctx-worker-first-call 64732 64731 reading" "the reading and its ceiling are named"
  printf 'ctx-worker-first-call 70000\n' > "$h/config/token-caps"
  out=$(load "$h" check); code=$?
  assert_equals 0 "$code" "a home line raises its own ceiling: $out"
  pass "a reading over its line fails, and config/token-caps overrides a shipped line"
}

test_brief_lint_reads_the_ceiling() {
  local f=$TMP_ROOT/brief.md budget out code
  budget=$("$LOAD" cap ctx-worker-brief)
  head -c "$budget" /dev/zero | tr '\0' 'x' > "$f"
  out=$("$ROOT/bin/jg-brief-lint.sh" "$f"); code=$?
  assert_equals 0 "$code" "a brief at the ceiling is clean: $out"
  printf 'x' >> "$f"
  out=$("$ROOT/bin/jg-brief-lint.sh" "$f"); code=$?
  assert_equals 1 "$code" "a brief one byte over the ceiling is reported"
  assert_contains "$out" "over-budget ctx-worker-brief: $((budget + 1)) bytes, budget $budget" "the finding names the line"
  ! grep -q '^budget' "$ROOT/defaults/brief-lint-rules.tsv" || fail "the shipped rule table holds no budget row"
  pass "the brief lint takes its budget from the ctx-worker-brief line"
}

test_growth_check_reports_an_over_ceiling() {
  local h out
  h=$(home growth "$((CAP + 1))")
  out=$(JG_HOME="$h" JG_ROOT_OVERRIDE="$h/root" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$h/data" \
    JG_CONFIG_OVERRIDE="$h/config" "$ROOT/bin/jg-startup-growth-check.sh" check 2>&1)
  assert_contains "$out" "context ceiling ctx-agents-md $((CAP + 1)) $CAP measured owner=bin/jg-context-load.sh" "the daily check names the line that is over"
  h=$(home growth-ok "$CAP")
  out=$(JG_HOME="$h" JG_ROOT_OVERRIDE="$h/root" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$h/data" \
    JG_CONFIG_OVERRIDE="$h/config" "$ROOT/bin/jg-startup-growth-check.sh" check 2>&1)
  assert_not_contains "$out" "context ceiling" "a file at its ceiling raises no finding"
  pass "the daily growth check reports a ceiling that is over and stays silent at it"
}

test_shipped_tree_is_green
test_one_byte_over_fails_and_names_the_line
test_reader_prints_known_total_and_records_once_a_day
test_reading_over_its_line_fails_and_home_line_overrides
test_brief_lint_reads_the_ceiling
test_growth_check_reports_an_over_ceiling
echo "context budget: each ceiling holds today's value, a byte over fails, one reading per role per day"
