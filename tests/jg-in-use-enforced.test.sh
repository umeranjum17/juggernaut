#!/usr/bin/env bash
# Acceptance test for "In use means enforced" (section 11 of the plan; slices S1 to S10): one change that declares switches goes
# through the real landing, the real go-live, the real delivery observer and the real claim rule, and its word follows its switches.
# Through tests/jg-trunk-fixture.sh it runs a fixture fleet (Main, a Squad Lead home that runs the project, two more homes), the
# real bin/jg-trunk.sh, bin/jg-update.sh, bin/jg-switch.sh, core/machines/observers/delivery.sh and bin/jg-live-claim.sh.
#
# T1 A commit that adds a wiring fragment with a `Change:` trailer, its changes.tsv row and three switch rows (wiring auto, file and
#    policy owner) lands under switch-decl=refuse; the go-live says `In homes` with the count, the go-live row of every home ends
#    switches-off:2, Main reads in-homes-off through the Squad Lead's record, the board word names the two switches, and the claim
#    "fixed fx-feature" is downgraded (exit 3).
# T2 The owner turns the two switches on in every home (the policy one through jg-switch.sh apply, which refuses without his word):
#    the word becomes in-use in Main and in the lead, the claim stands, and the next go-live says `In use`.
# T3 A commit that adds a wiring fragment with no `Change:` trailer is reported under switch-decl=report and refused under refuse.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

OBSERVER="$ROOT/core/machines/observers/delivery.sh"
SWITCH="$ROOT/bin/jg-switch.sh"
CLAIM="$ROOT/bin/jg-live-claim.sh"

# A declared change: one commit with the fragment, its trailer, its change row and its three switch rows.
declare_lane() {  # <id>
  local wt="$W/lanes/$1"
  lane "$1" 'echo wire' core/fx/wiring.sh "Change: fx-feature"
  mkdir -p "$wt/core/machines"
  printf 'fx-feature\tproj\t-\t-\t-\ta fixture change behind two owner switches\n' > "$wt/core/machines/changes.tsv"
  printf 'fx-feature\twiring\ttickets-sync\t-\tauto\t-\twired by the move\nfx-feature\tfile\tfx-flag\tpresent\towner\t-\tneeds the flag file\nfx-feature\tpolicy\tfx-key@proj\ton\towner\t-\tneeds the policy line\n' > "$wt/core/machines/switches.tsv"
  git -C "$wt" add -f core/machines/changes.tsv core/machines/switches.tsv
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -q --amend --no-edit
  prove "$1"
}

# Main: a home of its own that runs no project; its registry names the Squad Lead home that does (S1).
main_home() {
  MAIN="$W/main"; mkdir -p "$MAIN/state" "$MAIN/data" "$MAIN/config"
  printf -- '- code-lead - fixture (home: %s; scope: x; projects: proj; added 2026-11-09)\n' "$HOME_D" > "$MAIN/data/squad_leads.md"
}

delivery() { JG_HOME="$1" JG_DELIVERY_CHANGES="$W/changes.tsv" JG_SWITCH_MANIFEST="$W/switches.tsv" bash "$OBSERVER" "${@:2}"; }

test_a_declared_change_reads_in_homes_until_its_switches_are_on_then_in_use() {
  local out c h rc
  fleet_world acceptance
  printf 'protected-landing=gate\nswitch-decl@proj=refuse\n' >> "$HOME_D/config/trunk-policy"
  declare_lane g1; c=$(git -C "$PROJ" rev-parse fm/g1)
  fleet_sweeps "landed g1" >/dev/null; await_green || fail "the landing under switch-decl=refuse must move the green pin: a declared change lands"
  [ "$(tip)" = "$c" ] || fail "the declared change must be on the trunk"
  git -C "$PROJ" show "trunk:core/machines/changes.tsv" > "$W/changes.tsv"; git -C "$PROJ" show "trunk:core/machines/switches.tsv" > "$W/switches.tsv"
  export JG_SWITCH_MANIFEST="$W/switches.tsv"
  main_home

  # The go-live moves every home, counts the two owner switches still off in each, and says In homes, not In use (S4).
  age_landings 25 25
  out=$(trunk autolive "$PROJ" 2>&1)
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "autolive: In homes at ${c:0:12} on every home (0 skipped, 3 homes still have a switch off" "the go-live says In homes with the count"
  for h in lead-a lead-b; do
    grep -q "^proj:$h	$c	[0-9]*	live,switches-off:2" "$HOME_D/data/trunk-in-use.tsv" || fail "the go-live row of $h must end switches-off:2: $(cat "$HOME_D/data/trunk-in-use.tsv")"
  done
  assert_not_contains "$out" "autolive: In use at" "a go-live that left a switch off never says In use"

  # Every reader says the same thing: Main through the lead's record, the lead itself, the board word, the claim (S1, S3, S5).
  [ "$(delivery "$MAIN" fx-feature)" = in-homes-off ] || fail "Main must read in-homes-off through the lead's record: $(delivery "$MAIN" fx-feature)"
  [ "$(delivery "$HOME_D" fx-feature)" = in-homes-off ] || fail "the lead must read in-homes-off: $(delivery "$HOME_D" fx-feature)"
  assert_equals "In homes - off: fx-flag, fx-key@proj" "$(delivery "$MAIN" stage fx-feature)" "the board word names the two switches"
  rc=0; out=$(JG_HOME="$MAIN" JG_DELIVERY_OBSERVER="$OBSERVER" JG_DELIVERY_CHANGES="$W/changes.tsv" bash "$CLAIM" "done" "fixed fx-feature" 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "the claim must be downgraded (exit 3), got $rc: $out"
  assert_contains "$out" "not live" "the downgrade says the change is not live"

  # The owner turns the switches on. The policy row needs his word (S2); the file row is his to create.
  rc=0; bash "$SWITCH" apply fx-feature fx-key@proj --home "$HOME_D" >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "apply of an owner row must be refused without his word"
  for h in "$MAIN" "$HOME_D" "$W/lead-a" "$W/lead-b"; do
    mkdir -p "$h/config"; : > "$h/config/fx-flag"
    bash "$SWITCH" apply fx-feature fx-key@proj --home "$h" --owner-word "ok" >/dev/null 2>&1 || fail "apply with his word must write the policy line in $h"
  done
  grep -qx 'fx-key@proj=on' "$HOME_D/config/trunk-policy" || fail "apply appends the policy line: $(cat "$HOME_D/config/trunk-policy")"
  bash "$SWITCH" verify --home "$HOME_D" fx-feature >/dev/null 2>&1 || fail "verify must pass once every manifest row is on in the lead"

  [ "$(delivery "$MAIN" fx-feature)" = in-use ] || fail "Main must read in-use once every switch is on: $(delivery "$MAIN" fx-feature --detail 2>&1)"
  [ "$(delivery "$HOME_D" fx-feature)" = in-use ] || fail "the lead must read in-use once every switch is on"
  assert_equals "In use" "$(delivery "$MAIN" stage fx-feature)" "the board word is In use"
  rc=0; out=$(JG_HOME="$MAIN" JG_DELIVERY_OBSERVER="$OBSERVER" JG_DELIVERY_CHANGES="$W/changes.tsv" bash "$CLAIM" "done" "fixed fx-feature" 2>&1) || rc=$?
  assert_contains "$out" "fixed fx-feature" "the claim keeps its words"
  assert_not_contains "$out" "not live" "the claim is no longer downgraded"

  # The next go-live (a plain commit, no declared switch) says In use.
  age_live; lane g2 two work.txt; fleet_sweeps "landed g2" >/dev/null; await_green || fail "g2's landing must move the green pin"
  c=$(tip); age_landings 25 25
  assert_contains "$(trunk autolive "$PROJ" 2>&1 | tail -n 1)" "autolive: In use at ${c:0:12} on every home" "the next go-live says In use"
  unset JG_SWITCH_MANIFEST
  pass 'a declared change reads In homes with its two switches until the owner turns them on, then In use, in Main, in the lead, on the board and in the claim'
}

test_an_undeclared_wiring_fragment_is_reported_then_refused() {
  local out
  unset CODE_ROOT; world undeclared; printf 'protected-landing=gate\n' >> "$HOME_D/config/trunk-policy"
  lane u1 'echo wire' core/x/wiring.sh
  out=$(trunk land u1 2>&1) || fail "the default (report) must land the lane: $out"
  assert_contains "$out" "adds core/x/wiring.sh" "report names the fragment"
  assert_contains "$out" "does not list x" "report says the plan array was not edited, so the fragment never runs"
  printf 'switch-decl@proj=refuse\n' >> "$HOME_D/config/trunk-policy"
  lane u2 'echo wire' core/y/wiring.sh
  refused 'an undeclared wiring fragment under refuse' u2 'adds core/y/wiring.sh'
  pass 'a wiring fragment with no declaration is reported by default and refused under switch-decl=refuse'
}

test_a_declared_change_reads_in_homes_until_its_switches_are_on_then_in_use
test_an_undeclared_wiring_fragment_is_reported_then_refused
printf 'jg-in-use-enforced: ok\n'
