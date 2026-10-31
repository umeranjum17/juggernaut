#!/usr/bin/env bash
# Behavior tests for bin/jg-prior-art-gate.sh.
#
# New or complex work starts from what already exists (AGENTS.md section 7):
# bin/jg-brief.sh scaffolds every ship brief with a `# Prior art` section, and
# bin/jg-prior-art-gate.sh refuses it while the section is missing, still holds
# the scaffold placeholder, or names a pick with no licence decision.
# These tests drive the real scaffold and the real gate, so the repro (a brief
# with no prior-art record), the fix (it carries one) and both verdicts are
# pinned through their public interfaces rather than by matching brief prose.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/jg-prior-art-gate.sh"
BRIEF_TOOL="$ROOT/bin/jg-brief.sh"
TMP_ROOT=$(jg_test_tmproot jg-prior-art-gate)
HOME_DIR="$TMP_ROOT/home"

# Replace the scaffold's fill-me survey line with a recorded pick, exactly as a
# worker fills the section in before reporting done.
record_pick() {  # <brief> <pick> <licence>
  local brief=$1 pick=$2 licence=$3
  awk -v pick="$pick" -v licence="$licence" '
    /^Prior art \(survey\):/ { print "Prior art pick: " pick; print "Licence: " licence; next }
    { print }
  ' "$brief" > "$brief.t" && mv "$brief.t" "$brief"
}

scaffold_ship_brief() {  # <task-id> -> echoes the brief path
  local id=$1
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/config"
  : > "$HOME_DIR/config/delivery-risk-loose"
  JG_HOME="$HOME_DIR" "$BRIEF_TOOL" "$id" somerepo --mode direct-PR >/dev/null 2>&1 \
    || fail "jg-brief.sh $id --mode direct-PR should scaffold"
  printf '%s\n' "$HOME_DIR/data/$id/brief.md"
}

fixture_brief() {  # <name> <body>
  local name=$1 body=$2 path
  path="$TMP_ROOT/$name.md"
  printf '%s\n' "$body" > "$path"
  printf '%s\n' "$path"
}

test_ship_brief_carries_the_prior_art_step() {
  local brief
  brief=$(scaffold_ship_brief brief-prior-art)
  assert_grep "# Prior art" "$brief" "a ship brief carries no '# Prior art' section"
  assert_grep "prior-art\` skill" "$brief" "the prior-art step does not name the skill"
  assert_grep "search online for similar products and open-source projects" "$brief" \
    "the prior-art step does not require an online search"
  assert_grep "check each candidate's licence" "$brief" "the prior-art step does not require the licence check"
  assert_grep "three to five real options" "$brief" "the prior-art step does not require an options comparison"
  assert_grep "jg-prior-art-gate.sh" "$brief" "the prior-art step does not name its gate"
  pass "jg-brief.sh: a ship brief carries the prior-art step"
}

test_empty_scaffold_is_refused_and_a_recorded_pick_passes() {
  local brief out rc
  brief=$(scaffold_ship_brief brief-gate)
  out=$(bash "$GATE" "$brief" 2>&1); rc=$?
  expect_code 1 "$rc" "an unreplaced prior-art section should be refused (got: $out)"
  assert_contains "$out" "records no prior art" "the refusal did not say the section records nothing"

  record_pick "$brief" "ripgrep 14" "MIT - usable here"
  out=$(bash "$GATE" "$brief" 2>&1); rc=$?
  expect_code 0 "$rc" "a recorded pick with its licence should pass (got: $out)"
  assert_contains "$out" "prior art recorded: ripgrep 14" "the pass line did not name the pick"
  pass "jg-prior-art-gate.sh: the scaffold is refused and a recorded pick passes"
}

test_none_needed_is_accepted() {
  local brief out rc
  brief=$(fixture_brief none-needed '# Task
text

# Prior art
Prior art: none needed - one-line typo fix in an existing message

# Setup
text')
  out=$(bash "$GATE" "$brief" 2>&1); rc=$?
  expect_code 0 "$rc" "an explicit none-needed record should pass (got: $out)"
  assert_contains "$out" "none needed - one-line typo fix" "the pass line did not carry the reason"
  pass "jg-prior-art-gate.sh: 'none needed' with a reason passes"
}

test_missing_section_is_refused() {
  local brief out rc
  brief=$(fixture_brief no-section '# Task
text

# Setup
text')
  out=$(bash "$GATE" "$brief" 2>&1); rc=$?
  expect_code 1 "$rc" "a brief with no prior-art section should be refused (got: $out)"
  assert_contains "$out" "no '# Prior art' section" "the refusal did not name the missing section"
  pass "jg-prior-art-gate.sh: a brief with no section is refused"
}

test_pick_without_a_licence_decision_is_refused() {
  local brief out rc
  brief=$(fixture_brief pick-no-licence '# Prior art
Prior art pick: some-library
Options: a; b; c

# Setup
text')
  out=$(bash "$GATE" "$brief" 2>&1); rc=$?
  expect_code 1 "$rc" "a pick with no licence decision should be refused (got: $out)"
  assert_contains "$out" "no 'Licence: ...' line" "the refusal did not name the missing licence line"

  printf 'Prior art pick: <name>\nLicence: <licence>\n' >> "$brief"
  out=$(bash "$GATE" "$brief" 2>&1); rc=$?
  expect_code 1 "$rc" "an unreplaced <...> placeholder should still be refused (got: $out)"
  pass "jg-prior-art-gate.sh: a pick needs its licence decision and no placeholders"
}

test_usage_and_missing_file_are_refused() {
  local out rc
  out=$(bash "$GATE" 2>&1); rc=$?
  expect_code 1 "$rc" "no argument should be refused (got: $out)"
  assert_contains "$out" "usage:" "the refusal did not print usage"

  out=$(bash "$GATE" "$TMP_ROOT/absent-brief.md" 2>&1); rc=$?
  expect_code 1 "$rc" "a missing brief should be refused (got: $out)"
  assert_contains "$out" "no brief at" "the refusal did not say the brief is absent"
  pass "jg-prior-art-gate.sh: usage and a missing brief are refused"
}

test_ship_brief_carries_the_prior_art_step
test_empty_scaffold_is_refused_and_a_recorded_pick_passes
test_none_needed_is_accepted
test_missing_section_is_refused
test_pick_without_a_licence_decision_is_refused
test_usage_and_missing_file_are_refused
