#!/usr/bin/env bash
# Behavior: a seeded Squad Lead home leaves with the two pieces that make its
# merges visible - the primary's config/fleet-board and an executable
# config/merge-gate - and bin/jg-fleet-proof-check.sh names a registered home
# that lacks either while passing over the seeded one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/jg-fleet-proof-check.sh"
SEED="$ROOT/bin/jg-home-seed.sh"
TMP_ROOT=$(jg_test_tmproot jg-fleet-proof-check)

# build_primary <primary> <board-path>: a fixture primary home with one
# direct-PR project whose origin is a local bare repo, plus the board link.
build_primary() {
  local primary=$1 board=$2
  mkdir -p "$primary/bin" "$primary/data" "$primary/state" "$primary/config" "$primary/projects"
  : > "$board"
  printf '%s\n' "$board" > "$primary/config/fleet-board"
  printf '%s\n' '- alpha [direct-PR] - fixture project (added 2026-10-31)' > "$primary/data/projects.md"
  jg_git_init_commit "$primary/projects/alpha"
  jg_git_add_origin "$primary/projects/alpha" "$TMP_ROOT/alpha.origin.git"
}

# seed_home <primary> <home>: run the real seeding path for one home.
seed_home() {
  local primary=$1 home=$2
  mkdir -p "$home/bin"
  printf '%s\n' '# fixture home' > "$home/AGENTS.md"
  JG_HOME="$primary" JG_ROOT_OVERRIDE="$ROOT" \
    JG_DATA_OVERRIDE="$primary/data" JG_PROJECTS_OVERRIDE="$primary/projects" \
    JG_STATE_OVERRIDE="$primary/state" \
    JG_SQUAD_LEAD_CHARTER='Fixture mate for the proof wiring test.' \
    JG_SQUAD_LEAD_SCOPE='fixture routing scope' \
    "$SEED" mate "$home" alpha
}

# unseeded_home <home>: a home an earlier seed left without either piece.
unseeded_home() {
  local home=$1
  mkdir -p "$home/config" "$home/bin"
  printf '%s\n' '# fixture home' > "$home/AGENTS.md"
}

test_seeded_home_carries_the_proof_wiring() {
  local primary="$TMP_ROOT/primary" home="$TMP_ROOT/seeded" out rc
  build_primary "$primary" "$TMP_ROOT/board.json"

  out=$(seed_home "$primary" "$home" 2>&1); rc=$?
  assert_equals 0 "$rc" "seeding the fixture home failed: $out"

  assert_equals "$(cat "$primary/config/fleet-board")" "$(cat "$home/config/fleet-board")" \
    "the seeded home does not carry the primary's fleet board link"
  [ -x "$home/config/merge-gate" ] \
    || fail "the seeded home has no executable config/merge-gate"
  [ -f "$home/config/owner-rules" ] \
    || fail "the seeded home has no config/owner-rules for the gate it runs"
  pass "a seeded home inherits the primary board link and an executable merge gate"
}

test_check_names_only_the_home_without_the_wiring() {
  local primary="$TMP_ROOT/primary" unseeded="$TMP_ROOT/unseeded" out rc
  unseeded_home "$unseeded"
  printf -- '- mate-unseeded - unseeded fixture (home: %s; scope: fixture; projects: ; added 2026-10-31)\n' \
    "$unseeded" >> "$primary/data/squad_leads.md"

  out=$(JG_HOME="$primary" JG_DATA_OVERRIDE="$primary/data" "$CHECK" 2>&1); rc=$?
  assert_equals 1 "$rc" "the check accepted a registered home with neither piece: $out"
  assert_contains "$out" "FAIL mate-unseeded: no config/fleet-board" \
    "the check did not name the unseeded home's missing board link"
  assert_contains "$out" "no executable config/merge-gate" \
    "the check did not name the unseeded home's missing gate"
  assert_not_contains "$out" "FAIL mate:" \
    "the check failed the seeded home it just inspected: $out"

  grep -v -- '- mate-unseeded ' "$primary/data/squad_leads.md" > "$TMP_ROOT/seeded-only.md"
  cp "$TMP_ROOT/seeded-only.md" "$primary/data/squad_leads.md"
  out=$(JG_HOME="$primary" JG_DATA_OVERRIDE="$primary/data" "$CHECK" 2>&1); rc=$?
  assert_equals 0 "$rc" "the check failed an all-seeded fleet: $out"
  assert_contains "$out" "ok mate" "the check did not pass the seeded home: $out"
  pass "the check fails only the registered home that lacks the proof wiring"
}

test_seeded_home_carries_the_proof_wiring
test_check_names_only_the_home_without_the_wiring
