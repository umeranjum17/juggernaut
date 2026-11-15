#!/usr/bin/env bash
# tests/jg-design-card-mocks.test.sh - a design-pick card carries one mock per
# option. The card tool (bin/jg-question-card.sh) posts through the real
# sign-off-axi into a throwaway board, so the board record is the one the
# captain's board reads: three options give three mocks in its `mocks` field,
# files in the board's mocks folder. A card whose mocks and options differ is
# refused and nothing reaches the board.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v sign-off-axi >/dev/null 2>&1 || { printf 'skip - sign-off-axi is not installed\n'; exit 0; }

TMP_ROOT=$(jg_test_tmproot jg-design-card-mocks)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
CARD="$ROOT/bin/jg-question-card.sh"
KEY=pick-the-layout

setup() {  # <name> -> the case dir: a home, a board, and three mock files in its mocks folder
  local d=$TMP_ROOT/$1 v
  mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/so/.sign-off/mocks/$KEY"
  jg_test_raising_ticket "$d/home"
  printf '{"schema":2,"items":[]}\n' > "$d/so/.sign-off/decisions.json"
  printf 'leash: matters\n' > "$d/so/.sign-off/config.yaml"
  printf 'set mode off\n' > "$d/channel-off"
  for v in a b c; do
    printf '<!doctype html><title>Layout %s</title><p>Layout %s</p>\n' "$v" "$v" > "$d/so/.sign-off/mocks/$KEY/$v.html"
  done
  printf '%s\n' "$d"
}

post() {  # <case dir> [post flags...]: one design card, options a, b and c
  local d=$1
  shift
  env JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" JG_CAPTAIN_CHANNEL="$d/channel-off" \
    SIGN_OFF_HOME="$d/so" SIGN_OFF_FILER=card-test \
    "$CARD" post --route main --ask-ref jg-m1 --must design-pick --raised-by jg-m1 --key "$KEY" \
    --title "Which layout should the list use?" \
    --option a="A: one column" --option b="B: two columns" --option c="C: cards" --recommend b "$@" 2>&1
}

mocks() { printf -- '--mock a=mocks/%s/a.html --mock b=mocks/%s/b.html --mock c=mocks/%s/c.html' "$KEY" "$KEY" "$KEY"; }
board() { printf '%s/so/.sign-off/decisions.json' "$1"; }

test_three_mocks_reach_the_board_record() {
  local d out
  d=$(setup three)
  # shellcheck disable=SC2046  # the mock flags are words by design
  out=$(post "$d" $(mocks)) || fail "a design card with three mocks was refused: $out"
  assert_contains "$out" "$KEY" "the card key was not printed"
  assert_equals "design" "$(jq -r --arg k "$KEY" '.items[] | select(.key == $k) | .type' "$(board "$d")")" \
    "the card is not a design on the board"
  assert_equals "3" "$(jq -r --arg k "$KEY" '.items[] | select(.key == $k) | .mocks | length' "$(board "$d")")" \
    "the board record does not list three mocks"
  assert_equals "a=mocks/$KEY/a.html b=mocks/$KEY/b.html c=mocks/$KEY/c.html" \
    "$(jq -r --arg k "$KEY" '.items[] | select(.key == $k) | [.mocks[] | "\(.value)=\(.path)"] | join(" ")' "$(board "$d")")" \
    "a mock is listed under the wrong option or file"
  assert_contains "$out" "mock b: mocks/$KEY/b.html" "the tool did not list each mock for the poster"
  pass "a design-pick with three mocks lists three mocks on the board record"
}

test_a_mock_missing_for_an_option_is_refused() {
  local d out
  d=$(setup missing)
  out=$(post "$d" --mock "a=mocks/$KEY/a.html" --mock "b=mocks/$KEY/b.html") && fail "a card with two mocks for three options was posted: $out"
  assert_contains "$out" "have no --mock" "the refusal did not say a mock is missing"
  assert_equals "0" "$(jq '.items | length' "$(board "$d")")" "a refused card reached the board"
  pass "an option with no mock refuses the card"
}

test_a_mock_for_no_option_or_twice_is_refused() {
  local d out
  d=$(setup extra)
  out=$(post "$d" --mock "z=mocks/$KEY/a.html") && fail "a mock for an option the card lacks was posted: $out"
  assert_contains "$out" "names no --option" "the refusal did not name the stray mock"
  out=$(post "$d" --mock "a=mocks/$KEY/a.html" --mock "a=mocks/$KEY/b.html") && fail "two mocks for one option were posted: $out"
  assert_contains "$out" "two mocks" "the refusal did not say an option has two mocks"
  assert_equals "0" "$(jq '.items | length' "$(board "$d")")" "a refused card reached the board"
  pass "a stray or doubled mock refuses the card"
}

test_a_mock_on_a_card_that_is_not_a_design_is_refused() {
  local d out
  d=$(setup notdesign)
  out=$(env JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" JG_CAPTAIN_CHANNEL="$d/channel-off" SIGN_OFF_HOME="$d/so" \
    "$CARD" post --route main --ask-ref jg-m1 --must money --title "Should we pay for it?" \
    --outcome yes="It is paid." --outcome no="It is not." --mock "yes=mocks/$KEY/a.html" 2>&1) \
    && fail "a mock on a money card was posted: $out"
  assert_contains "$out" "belongs to a design card" "the refusal did not say a mock needs a design card"
  assert_equals "0" "$(jq '.items | length' "$(board "$d")")" "a refused card reached the board"
  pass "a mock on a card that is not a design pick is refused"
}

test_three_mocks_reach_the_board_record
test_a_mock_missing_for_an_option_is_refused
test_a_mock_for_no_option_or_twice_is_refused
test_a_mock_on_a_card_that_is_not_a_design_is_refused
