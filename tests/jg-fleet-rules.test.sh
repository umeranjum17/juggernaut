#!/usr/bin/env bash
# tests/jg-fleet-rules.test.sh - the one rules shape (bin/jg-preferred-stack-lib.sh):
# a checkable rule names a check that really exists, a judgement rule names none,
# a malformed file is one warning instead of advice, and a scaffolded brief
# carries the engineering rules this home wrote.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/jg-preferred-stack-lib.sh
. "$ROOT/bin/jg-preferred-stack-lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-fleet-rules)
RULES=config/engineering-rules.json

# A home config that holds one engineering-rules file with the given rule objects.
write_rules() {  # <dir> <rules-json>
  mkdir -p "$1/config"
  printf '{"rules": [%s]}\n' "$2" > "$1/$RULES"
}

test_every_documented_example_parses() {
  local file count=0
  for file in "$ROOT"/docs/examples/*.json; do
    jq -e . "$file" >/dev/null 2>&1 || fail "docs/examples/$(basename "$file") does not parse"
    count=$((count + 1))
  done
  [ "$count" -ge 4 ] || fail "expected the documented examples, found $count files"
  assert_equals "" "$(jg_rules_problem "$ROOT/defaults/engineering-rules.json")" \
    "the shipped default must pass the loader's own validation"
  pass "every documented example and the shipped default parse"
}

test_a_checkable_rule_needs_a_real_check_and_a_judgement_rule_needs_none() {
  write_rules "$TMP_ROOT/no-check" \
    '{"id": "x-rule", "when": "w", "use": {"text": "t"}, "why": "y", "kind": "checkable"}'
  assert_contains "$(jg_rules_problem "$TMP_ROOT/no-check/$RULES")" \
    "a checkable rule needs enforcedBy" "a checkable rule with no enforcement must be refused"

  write_rules "$TMP_ROOT/missing-check" \
    '{"id": "x-rule", "when": "w", "use": {"text": "t"}, "why": "y", "kind": "checkable", "enforcedBy": "bin/not-a-real-check.sh"}'
  assert_contains "$(jg_rules_problem "$TMP_ROOT/missing-check/$RULES")" \
    "does not exist in this checkout" "an enforcedBy naming a missing path must be refused"

  write_rules "$TMP_ROOT/real-check" \
    '{"id": "x-rule", "when": "w", "use": {"text": "t"}, "why": "y", "kind": "checkable", "enforcedBy": "bin/jg-live-claim.sh"}'
  assert_equals "" "$(jg_rules_problem "$TMP_ROOT/real-check/$RULES")" \
    "a checkable rule naming a real check must be accepted"

  write_rules "$TMP_ROOT/judgement-with-check" \
    '{"id": "x-rule", "when": "w", "use": {"text": "t"}, "why": "y", "kind": "judgement", "enforcedBy": "bin/jg-live-claim.sh"}'
  assert_contains "$(jg_rules_problem "$TMP_ROOT/judgement-with-check/$RULES")" \
    "a judgement rule must not name enforcedBy" "advice nothing checks must not claim a check"
  pass "a checkable rule needs a real check and a judgement rule needs none"
}

test_an_unknown_kind_and_a_repeated_id_are_refused() {
  write_rules "$TMP_ROOT/kind" \
    '{"id": "x-rule", "when": "w", "use": {"text": "t"}, "why": "y", "kind": "maybe"}'
  assert_contains "$(jg_rules_problem "$TMP_ROOT/kind/$RULES")" \
    "kind must be checkable or judgement" "an unknown kind must be refused"

  write_rules "$TMP_ROOT/repeated-id" \
    '{"id": "same", "when": "a", "use": {"text": "t"}, "why": "y", "kind": "judgement"}, {"id": "same", "when": "b", "use": {"text": "t"}, "why": "y", "kind": "judgement"}'
  assert_contains "$(jg_rules_problem "$TMP_ROOT/repeated-id/$RULES")" \
    "an id is used twice in one file" "one id may name only one rule"
  pass "an unknown kind and a repeated id are refused"
}

test_the_section_separates_advice_from_checks() {
  local out expected
  printf -v expected "x-check: \`%s\`" bin/jg-live-claim.sh
  write_rules "$TMP_ROOT/section" \
    '{"id": "x-advice", "when": "You claim it works.", "use": {"text": "Show the real product."}, "why": "A claim is not proof.", "kind": "judgement"}, {"id": "x-check", "when": "You report it fixed.", "use": {"text": "Name the version."}, "why": "A merge is not a release.", "kind": "checkable", "enforcedBy": "bin/jg-live-claim.sh"}'
  out=$(jg_rules_section "$TMP_ROOT/section/config")
  assert_contains "$out" "# Engineering rules" "the brief section heading is missing"
  assert_contains "$out" "Show the real product." "a judgement rule must print as advice"
  assert_not_contains "$out" "Name the version." "a checkable rule must not print as advice"
  assert_contains "$out" "$expected" "a checkable rule must print its check"
  pass "the section separates advice from checks"
}

test_a_broken_file_is_one_warning_and_no_advice() {
  local out err
  mkdir -p "$TMP_ROOT/broken/config"
  printf '%s\n' '{"rules": [' > "$TMP_ROOT/broken/$RULES"
  out=$(jg_rules_section "$TMP_ROOT/broken/config" 2>"$TMP_ROOT/broken/err")
  err=$(cat "$TMP_ROOT/broken/err")
  assert_equals "" "$out" "a malformed rules file must print no advice"
  assert_contains "$err" "FLEET_RULES: invalid $RULES - malformed JSON" \
    "a malformed rules file must warn once with its name"
  pass "a broken file is one warning and no advice"
}

# The shipped default is what a fresh home starts from, so it must reach a
# scaffolded brief, not only the library's own callers.
test_a_scaffolded_brief_carries_the_engineering_rules() {
  local home=$TMP_ROOT/brief-home
  mkdir -p "$home/config" "$home/data"
  cp "$ROOT/defaults/engineering-rules.json" "$home/$RULES"
  JG_HOME="$home" JG_DATA_OVERRIDE="$home/data" JG_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/jg-brief.sh" fleet-rules-test juggernaut --mode local-only \
    --design-call no --design-reason "config files and brief output" >/dev/null 2>&1 \
    || fail "the brief scaffold failed in a home holding the shipped rules default"
  assert_contains "$(cat "$home/data/fleet-rules-test/brief.md")" "# Engineering rules" \
    "a scaffolded brief must carry this home's engineering rules"
  pass "a scaffolded brief carries the engineering rules"
}

test_every_documented_example_parses
test_a_checkable_rule_needs_a_real_check_and_a_judgement_rule_needs_none
test_an_unknown_kind_and_a_repeated_id_are_refused
test_the_section_separates_advice_from_checks
test_a_broken_file_is_one_warning_and_no_advice
test_a_scaffolded_brief_carries_the_engineering_rules
echo "all jg-fleet-rules tests passed"
