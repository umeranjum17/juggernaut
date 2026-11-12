#!/usr/bin/env bash
# tests/jg-project-mode.test.sh - the delivery-route default (bin/jg-project-mode.sh):
# a project nobody registered ships as a direct pull request, while a registered
# line keeps the posture its owner wrote, a typo and a legacy bracket-less line
# included.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-project-mode)
MODE="$ROOT/bin/jg-project-mode.sh"

mode_of() {  # <home> <project> -> the "<mode> <yolo>" line
  JG_HOME="$1" JG_DATA_OVERRIDE="$1/data" "$MODE" "$2" 2>/dev/null
}

test_an_unregistered_project_defaults_to_a_direct_pr() {
  local home=$TMP_ROOT/unregistered
  mkdir -p "$home/data"
  assert_equals "direct-PR off" "$(mode_of "$home" anything)" "a home with no registry must default to a direct PR"
  printf -- '- known [local-only] - a registered project (added 2026-10-30)\n' > "$home/data/projects.md"
  assert_equals "direct-PR off" "$(mode_of "$home" stranger)" "a project missing from the registry must default to a direct PR"
  pass "an unregistered project defaults to a direct PR"
}

test_a_registered_posture_is_never_lowered() {
  local home=$TMP_ROOT/registered
  mkdir -p "$home/data"
  {
    printf -- '- strict [no-mistakes] - registered for the pipeline (added 2026-10-30)\n'
    printf -- '- legacy - registered before modes existed (added 2026-10-30)\n'
    printf -- '- typo [no-mistake] - a misspelled mode (added 2026-10-30)\n'
  } > "$home/data/projects.md"
  assert_equals "direct-PR off" "$(mode_of "$home" strict)" "a project registered with the retired word no-mistakes runs as direct-PR"
  assert_equals "direct-PR off" "$(mode_of "$home" legacy)" "a legacy bracket-less line reads as direct-PR"
  assert_equals "direct-PR off" "$(mode_of "$home" typo)" "a misspelled mode resolves to direct-PR"
  pass "a registered posture is never lowered by the default"
}

# The branch prefix comes from the kind of work unless the registry names one.
test_the_branch_prefix_follows_the_kind_and_a_registered_prefix_wins() {
  local home=$TMP_ROOT/prefix k
  mkdir -p "$home/data"
  {
    printf -- '- plain [direct-PR] - no prefix registered (added 2026-11-03)\n'
    printf -- '- own [direct-PR branch=cap/] - prefix registered (added 2026-11-03)\n'
  } > "$home/data/projects.md"
  prefix_of() { JG_HOME="$home" JG_DATA_OVERRIDE="$home/data" "$MODE" --branch-prefix "$@" 2>/dev/null; }
  assert_equals "fm/" "$(prefix_of plain)" "no kind keeps the legacy prefix"
  assert_equals "feature/" "$(prefix_of --kind '[feature]' plain)" "a feature gets feature/"
  for k in bug fix hotfix; do
    assert_equals "fix/" "$(prefix_of --kind "$k" plain)" "$k gets fix/"
  done
  for k in chore docs test; do
    assert_equals "chore/" "$(prefix_of --kind "$k" plain)" "$k gets chore/"
  done
  assert_equals "feature/" "$(prefix_of --kind feature stranger)" "an unregistered project follows the kind too"
  assert_equals "cap/" "$(prefix_of --kind feature own)" "an explicit registry prefix wins over the kind"
  assert_equals "" "$(prefix_of --registered plain)" "a project with no registered prefix reports none"
  assert_equals "cap/" "$(prefix_of --registered own)" "a registered prefix is reported as registered"
  pass "the branch prefix follows the kind and a registered prefix wins"
}

test_an_unregistered_project_defaults_to_a_direct_pr
test_a_registered_posture_is_never_lowered
test_the_branch_prefix_follows_the_kind_and_a_registered_prefix_wins
