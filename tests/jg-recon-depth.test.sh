#!/usr/bin/env bash
# Behavior tests for bin/jg-recon-depth.sh.
#
# Intake picks a Recon's depth from the words of the ask. The tests feed sample
# asks through the real script and check the level; the level is the word
# bin/jg-brief.sh --scout --depth takes, which tests/jg-brief.test.sh covers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEPTH="$ROOT/bin/jg-recon-depth.sh"

check_ask() {  # <expected> <ask>
  local want=$1 ask=$2 got
  got=$(bash "$DEPTH" "$ask") || fail "recon-depth: exited non-zero for: $ask"
  [ "$got" = "$want" ] || fail "recon-depth: '$ask' gave '$got', wanted '$want'"
}

test_sample_asks_map_to_levels() {
  check_ask deep "Do an in depth discovery of how the queue works"
  check_ask deep "Research this properly and give me a detailed report"
  check_ask deep "Write a plan with slices for the migration"
  check_ask deep "I want the deep version of the retry investigation"
  check_ask quick "what version of node does the repo pin"
  check_ask quick "which port does the bus use"
  check_ask standard "Investigate why the build is flaky"
  check_ask standard "Compare the options for caching the session store"
  check_ask standard "Audit the retry code and tell me what is wrong"
  pass "recon-depth.sh: sample asks map to quick, standard and deep"
}

test_the_captain_naming_a_level_wins() {
  check_ask quick "a quick recon of the queue, but go in depth on the locks"
  check_ask standard "standard recon please: discovery of the bus"
  check_ask deep "depth: deep - which port does the bus use"
  check_ask quick "depth: quick, plan with slices"
  pass "recon-depth.sh: a level the captain names wins over the words of the ask"
}

test_ask_from_stdin_and_usage_errors() {
  local got rc
  got=$(printf 'in depth look at the bus\n' | bash "$DEPTH" -)
  [ "$got" = deep ] || fail "recon-depth: stdin ask gave '$got'"
  bash "$DEPTH" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "recon-depth: no argument must be a usage error"
  bash "$DEPTH" "" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "recon-depth: an empty ask must be a usage error"
  pass "recon-depth.sh: reads the ask from stdin and refuses a missing or empty ask"
}

test_sample_asks_map_to_levels
test_the_captain_naming_a_level_wins
test_ask_from_stdin_and_usage_errors
