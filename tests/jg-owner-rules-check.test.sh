#!/usr/bin/env bash
# jg-owner-rules-check.test.sh - `bin/jg-owner-rules.sh check` on a fixture surface:
# the lead sees each owner rule that still has no kind, or whose enforcement text
# names no file that exists, and the check only reports - recording a correction
# is never refused because of it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RULES="$ROOT/bin/jg-owner-rules.sh"
TMP_ROOT=$(jg_test_tmproot jg-owner-rules-check)

complete_entry() {
  cat <<'EOF'
## 2026-10-25 - Complete rule
- Kind: owner
- Scope: every report
- Enforced by: bin/jg-pr-merge.sh; AGENTS.md
- Owner's words: "a rule that is already complete"
EOF
}

write_fixture() {  # <surface>
  {
    printf '# Owner rules\n\nHeader prose that names bin/ and docs/ is not an entry.\n\n'
    complete_entry
    cat <<'EOF'

## 2026-10-26 - No kind, real file
- Scope: s
- Enforced by: `bin/jg-live-claim.sh`.
- Owner's words: "a rule with a file and no kind"

## 2026-10-27 - Prose only
- Kind: Owner
- Scope: s
- Enforced by: the trunk lander in the docs and bin defaults
- Owner's words: "a rule enforced by prose alone"

## 2026-10-28 - Gone script
- Kind: product
- Scope: s
- Enforced by: bin/jg-not-a-script.sh
- Owner's words: "a rule whose script was deleted"

## 2026-10-29 - Odd kind, folder
- Kind: taste
- Scope: s
- Enforced by: core/merge-on-green (the watcher)
- Owner's words: "a rule with an unknown kind"

## 2026-10-30 - Nothing at all
- Scope: s
- Owner's words: "a rule with neither a kind nor an enforcement line"
EOF
  } > "$1"
}

test_check_lists_each_unfinished_rule_and_changes_nothing() {
  local home surface before out rc
  home="$TMP_ROOT/findings"
  mkdir -p "$home/data"
  surface="$home/data/owner-rules.md"
  write_fixture "$surface"
  before=$(cat "$surface")

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" check 2>&1); rc=$?
  assert_equals 1 "$rc" "a surface with unfinished rules did not exit 1"
  assert_contains "$out" "no kind: 2026-10-26 - No kind, real file" "a rule with no kind line was not listed"
  assert_contains "$out" "no kind: 2026-10-29 - Odd kind, folder (kind 'taste' is neither owner nor product)" \
    "a rule with an unknown kind was not listed with the kind it carries"
  assert_contains "$out" "no kind: 2026-10-30 - Nothing at all" "a rule with no lines at all was not listed for its kind"
  assert_contains "$out" "no check file: 2026-10-27 - Prose only [enforced by: the trunk lander in the docs and bin defaults]" \
    "prose that only mentions folder names counted as a check file"
  assert_contains "$out" "no check file: 2026-10-28 - Gone script [enforced by: bin/jg-not-a-script.sh]" \
    "an enforcement path that does not exist counted as a check file"
  assert_contains "$out" "no check file: 2026-10-30 - Nothing at all [enforced by: nothing]" \
    "a rule with no enforcement line was not listed"
  assert_not_contains "$out" "Complete rule" "a complete rule was listed"
  assert_not_contains "$out" "no check file: 2026-10-26" "a quoted enforcement path with a full stop was not found"
  assert_not_contains "$out" "no check file: 2026-10-29" "an existing core/ folder did not count as a check file"
  assert_not_contains "$out" "no kind: 2026-10-27" "a capitalised owner kind was not read"
  assert_not_contains "$out" "no kind: 2026-10-28" "a product kind was listed as missing"
  assert_contains "$out" "rules: 6" "the rule count is wrong"
  assert_contains "$out" "without a kind: 3" "the no-kind count is wrong"
  assert_contains "$out" "without a check file: 3" "the no-check-file count is wrong"
  assert_contains "$out" 'fix: give each rule above a "- Kind: owner"' "the report does not say how to finish a rule"
  assert_equals "$before" "$(cat "$surface")" "check changed the surface it reports on"

  assert_equals "$out" "$(JG_HOME="$TMP_ROOT/elsewhere" JG_ROOT_OVERRIDE="$ROOT" "$RULES" check --surface "$surface" 2>&1)" \
    "--surface did not read the same rules as the home's own surface"
  pass "check lists each rule with no kind or no existing check file, with the counts, and changes nothing"
}

test_check_never_blocks_recording_a_correction() {
  local home surface out rc
  home="$TMP_ROOT/record"
  mkdir -p "$home/data"
  surface="$home/data/owner-rules.md"
  write_fixture "$surface"

  JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" check >/dev/null 2>&1
  assert_equals 1 "$?" "the fixture surface did not report findings"
  JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" add --kind owner \
    --words "record the correction before it is tidy" --scope "every correction" \
    --enforce bin/jg-owner-rules.sh --date 2026-11-09 >/dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "add refused a correction while check had findings"
  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" check 2>&1)
  assert_contains "$out" "rules: 7" "the recorded correction is not counted"
  assert_not_contains "$out" "record the correction before it is tidy" "a complete recorded rule was listed"
  pass "add records a correction while check reports unfinished rules"
}

test_check_is_clean_or_refuses_plainly() {
  local home surface out rc
  home="$TMP_ROOT/clean"
  mkdir -p "$home/data"
  surface="$home/data/owner-rules.md"

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" check 2>&1); rc=$?
  assert_equals 2 "$rc" "a missing surface did not exit 2"
  assert_contains "$out" "no rules surface at $surface" "a missing surface was not named"

  JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" init >/dev/null 2>&1 || fail "init did not write the surface"
  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" check 2>&1); rc=$?
  assert_equals 0 "$rc" "an empty surface was not clean"
  assert_contains "$out" "rules: 0" "an empty surface counted a rule"

  complete_entry >> "$surface"
  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" check 2>&1); rc=$?
  assert_equals 0 "$rc" "a surface of complete rules was not clean"
  assert_contains "$out" "clean: every rule has a kind and names a check file that exists" "the clean result was not stated"

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" check --fix 2>&1); rc=$?
  assert_equals 2 "$rc" "an unknown argument was accepted"
  pass "check is clean on complete rules and refuses a missing surface or an unknown argument"
}

test_check_lists_each_unfinished_rule_and_changes_nothing
test_check_never_blocks_recording_a_correction
test_check_is_clean_or_refuses_plainly
