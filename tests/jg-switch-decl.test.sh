#!/usr/bin/env bash
# Integration test for the landing's switch declaration check (core/machines/switch-decl.sh, asked by bin/jg-trunk.sh land).
# Through tests/jg-trunk-fixture.sh it lands real one-commit lanes through the real landing command.
#
# T1 A commit that adds core/<x>/wiring.sh, an empty-default key to jg_trunk_policy, a toolchain.versions row or a file under
#    core/machines/tables/ is flagged when it has no Change: trailer with changes.tsv rows. The default (switch-decl=report) lands it
#    and says so on stderr and in data/switch-decl.tsv; a wiring fragment outside the plan array of bin/jg-host-wiring.sh is named.
# T2 switch-decl@<project>=refuse refuses each of the four, names the addition and leaves the trunk alone; a trailer with no row refuses.
# T3 A trailer with its row in core/machines/changes.tsv lands under refuse; a commit that adds none of the four lands untouched; off asks nothing.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
JG_TRUNK_FIXTURE_CACHE=1

# decl_lane <id> <file> <content> [<change id> [row]]: a one-commit lane adding <file>; the trailer when an id is named, and its changes.tsv row when row.
decl_lane() {
  local id=$1 wt="$W/lanes/$1"
  lane "$id" "$3" "$2" "${4:+Change: $4}"
  [ "${5:-}" = row ] || return 0
  mkdir -p "$wt/core/machines"; printf '%s\tproj\t-\t-\t-\ta change behind a switch\n' "$4" > "$wt/core/machines/changes.tsv"
  git -C "$wt" add -f core/machines/changes.tsv
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -q --amend --no-edit
  prove "$id"
}

policy_refuse() { printf 'protected-landing=gate\nswitch-decl@proj=refuse\n' >> "$HOME_D/config/trunk-policy"; }

test_the_default_reports_a_flagged_commit_and_lands_it() {
  local out
  world report; printf 'protected-landing=gate\n' >> "$HOME_D/config/trunk-policy"
  decl_lane w1 core/x/wiring.sh 'echo wire'
  out=$(trunk land w1 2>&1) || fail "report must land the lane: $out"
  assert_contains "$out" "switch-decl (report)" "the landing says it was flagged"
  assert_contains "$out" "adds core/x/wiring.sh" "it names the fragment"
  assert_contains "$out" "does not list x" "it says the plan array was not edited, so the fragment never runs"
  git -C "$PROJ" cat-file -e "trunk:core/x/wiring.sh" || fail "the flagged lane must be on the tip"
  grep -q "w1" "$HOME_D/data/switch-decl.tsv" || fail "the finding is recorded: $(cat "$HOME_D/data/switch-decl.tsv" 2>&1)"
  # A fragment the plan lists is named without the plan warning.
  decl_lane w2 core/y/wiring.sh 'echo wire'
  git -C "$W/lanes/w2" reset -q --hard trunk
  mkdir -p "$W/lanes/w2/core/y" "$W/lanes/w2/bin"; echo 'echo wire' > "$W/lanes/w2/core/y/wiring.sh"
  printf 'plan=(\n  y:plain\n)\n' > "$W/lanes/w2/bin/jg-host-wiring.sh"
  git -C "$W/lanes/w2" add -A; git -C "$W/lanes/w2" -c user.name=t -c user.email=t@example.invalid commit -q -m "ticket w2"; prove w2
  out=$(trunk land w2 2>&1) || fail "report must land the listed fragment: $out"
  assert_contains "$out" "adds core/y/wiring.sh" "it names the listed fragment"
  assert_not_contains "$out" "never runs" "a fragment the plan lists gets no plan warning"
  pass 'the default reports a flagged commit, records it and lands it'
}

test_refuse_stops_each_of_the_four_additions_and_leaves_the_trunk() {
  world refuse; policy_refuse
  decl_lane r1 core/x/wiring.sh 'echo wire'; refused 'a wiring fragment with no declaration' r1 'adds core/x/wiring.sh'
  decl_lane r2 bin/jg-trunk-policy-lib.sh "      new-switch) val='' ;;"; refused 'an empty-default policy key' r2 'policy key new-switch'
  decl_lane r3 toolchain.versions 'newtool 1.2.3'; refused 'a toolchain row' r3 'toolchain.versions row newtool'
  decl_lane r4 core/machines/tables/m.tsv 'machine'; refused 'a machine table' r4 'machine table core/machines/tables/m.tsv'
  decl_lane r5 core/z/wiring.sh 'echo wire' z-change; refused 'a trailer with no row' r5 'Change: z-change has no row'
  assert_contains "$(trunk land r1 2>&1 || true)" "Change: trailer" "the refusal says how to declare"
  pass 'refuse stops a wiring fragment, an empty-default key, a toolchain row and a machine table with no declaration'
}

test_a_trailer_with_its_row_lands_and_an_unflagged_commit_is_left_alone() {
  local out
  world declared; policy_refuse
  decl_lane d1 core/x/wiring.sh 'echo wire' x-change row
  out=$(trunk land d1 2>&1) || fail "a declared change must land under refuse: $out"
  assert_not_contains "$out" "switch-decl" "a declared change raises no finding"
  decl_lane d2 notes.txt 'plain'
  out=$(trunk land d2 2>&1) || fail "a commit that adds none of the four must land under refuse: $out"
  printf 'switch-decl@proj=off\n' >> "$HOME_D/config/trunk-policy"
  decl_lane d3 core/q/wiring.sh 'echo wire'
  out=$(trunk land d3 2>&1) || fail "off must ask nothing: $out"
  assert_not_contains "$out" "switch-decl" "off says nothing"
  pass 'a trailer with its row lands, an unflagged commit lands and off asks nothing'
}

test_the_default_reports_a_flagged_commit_and_lands_it
test_refuse_stops_each_of_the_four_additions_and_leaves_the_trunk
test_a_trailer_with_its_row_lands_and_an_unflagged_commit_is_left_alone
printf 'jg-switch-decl: ok\n'
