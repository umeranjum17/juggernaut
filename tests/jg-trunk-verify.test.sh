#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: the post-landing verify and the trunk lock (tests/jg-trunk-fixture.sh).
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh, reads bin/jg-dod-lib.sh and stands in for bin/jg-captain-hold.sh,
# bin/jg-backlog.sh, bin/jg-send.sh, bin/jg-teardown.sh, bin/jg-fleet-ledger.sh and bin/jg-home-health.sh.
#
# Queued verifies run one at a time and only the newest runs, and its green moves the pin over the rest; a verify whose
#    only failures its parent already had moves the pin, and one holding a red the commit added does not. A verify whose only
#    failures pass on their one rerun moves the pin too, and each flaky test is recorded and filed once as its own fix row.
# No landing or stack holds the trunk lock while its gate runs: a verify finishes and moves the pin, another lane lands,
#    and a lane or stack whose tip moved under its gate is judged again on the moved tip.
# Verify judges every change since the trunk's release base (data/trunk-versions.tsv), the set CI maps for the release
#    pull request, not only the last commit's.
# The done-done journey journeys/trunk-landing.sh runs this file and seals its output.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# tip_after_land <id>: lands the lane and prints the new trunk tip.
tip_after_land() { trunk land "$1" >/dev/null 2>&1 || fail "$1 must land"; tip; }

# A gate that records what it judged and stays open, until the test releases it, on a commit whose tree holds SLOW.
slow_gate() {
  printf '#!/usr/bin/%s bash\ngit log -1 --format=%%s >> %s/gate-seen\nif git grep -q SLOW; then while [ ! -e %s/release ]; do sleep 0.1; done; fi\n' env "$W" "$W" > "$W/slow-gate.sh"
  printf 'gate-full=bash %s/slow-gate.sh\n' "$W" >> "$HOME_D/config/trunk-policy"
}

seen() { local n; n=$(grep -c "^$1\$" "$W/gate-seen" 2>/dev/null || :); echo "${n:-0}"; }  # how often the gate judged the commit with this subject
await_gate() {  # <subject>: until the gate is judging it
  local n; for n in $(seq 1 150); do [ "$(seen "$1")" -ge 1 ] && return 0; sleep 0.1; done; fail "the gate must start on $1"
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_queued_verifies_run_one_at_a_time_and_only_the_newest_runs() {
  local c1 c2 c3 p1 p2 p3 n
  world coalesce
  lane q1 one; c1=$(tip_after_land q1); lane q2 two; c2=$(tip_after_land q2); lane q3 three; c3=$(tip_after_land q3)
  # A whole-suite run that records which commit it ran at and stays open until the test releases it.
  printf '#!/usr/bin/env bash\ngit rev-parse HEAD >> %s/verify-ran\nwhile [ ! -e %s/release ]; do sleep 0.1; done\n' "$W" "$W" > "$W/slow.sh"
  printf 'gate-verify=bash %s/slow.sh\n' "$W" >> "$HOME_D/config/trunk-policy"
  trunk verify "$PROJ" "$c1" > "$W/v1.out" 2>&1 & p1=$!
  for n in $(seq 1 100); do [ -s "$W/verify-ran" ] && break; sleep 0.1; done
  [ -s "$W/verify-ran" ] || fail "the first verify must be running"
  # Two more are queued behind it. The older one gives up at once; only the newest waits for the slot.
  trunk verify "$PROJ" "$c2" > "$W/v2.out" 2>&1 & p2=$!
  trunk verify "$PROJ" "$c3" > "$W/v3.out" 2>&1 & p3=$!
  wait "$p2" || fail "a superseded verify must end quietly: $(cat "$W/v2.out")"
  assert_contains "$(cat "$W/v2.out")" "superseded" "the older queued verify must say a newer one took its place"
  : > "$W/release"
  wait "$p1" || fail "the running verify must finish: $(cat "$W/v1.out")"
  wait "$p3" || fail "the newest verify must run and pass: $(cat "$W/v3.out")"
  [ "$(cat "$W/verify-ran")" = "$c1"$'\n'"$c3" ] || fail "the suite must run at the first and the newest commit only: $(cat "$W/verify-ran")"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c3" ] || fail "green at the newest commit moves the pin over the commit that never ran"
  [ ! -e "$HOME_D/state/trunk-verify-want-proj" ] || fail "a verify that ended must leave nothing queued"
  # A verify for a commit that is already under the pin does not run the suite again.
  assert_contains "$(trunk verify "$PROJ" "$c2" 2>&1)" "already under the green pin" "a covered commit is not verified again"
  [ "$(grep -c . "$W/verify-ran")" = 2 ] || fail "a covered commit must not run the suite"
  pass 'queued verifies run one at a time and only the newest runs; its green moves the pin over the rest'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_verify_moves_the_pin_over_a_red_its_parent_already_had() {
  local out good
  world parentred; rig; seed_red_tip
  printf 'gate-verify=export GATE_MARK=yes; bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"
  lane good 'exit 0' t/d.test.sh
  trunk land good >/dev/null 2>&1 || fail "a lane that adds no red must land on a red tip"
  good=$(tip)
  out=$(trunk verify "$PROJ" 2>&1) || fail "a verify whose only failure is its parent's own must pass: $out"
  assert_contains "$out" "already had set aside" "the verify must say it set the parent's red aside"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$good" ] || fail "the pin must move when every failure is one the parent already had"
  # A red the commit adds still holds the pin and is charged to the commit.
  lane bad 'echo "not ok - new red" >&2; exit 1' t/e.test.sh
  printf 'gate-full=true\n' >> "$HOME_D/config/trunk-policy"
  trunk land bad >/dev/null 2>&1 || fail "the lane lands by hand past a fast gate"
  trunk verify "$PROJ" >/dev/null 2>&1 && fail "a commit that adds a red must not pass verify"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$good" ] || fail "a red the commit added must not move the pin"
  pass 'the green pin moves over failures the parent already had, and holds on a red the commit added'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_verify_whose_only_failures_pass_on_rerun_moves_the_pin_and_files_one_row_per_flaky_test() {
  local out first top
  world flakyverify; rig; first=$(tip)
  printf 'gate-verify=bash %s/rig.sh --all\ngate-full=true\n' "$W" >> "$HOME_D/config/trunk-policy"
  # Two scripts that each fail the first time the suite runs them and pass on the rerun, as jg-tmp-reaper and jg-bus-gateway did.
  lane fr "[ -e $W/seen-r ] || { : > $W/seen-r; echo 'not ok - flaky r' >&2; exit 1; }; exit 0" t/r.test.sh
  trunk land fr >/dev/null 2>&1 || fail "fr must land"
  lane fs "[ -e $W/seen-s ] || { : > $W/seen-s; echo 'not ok - flaky s' >&2; exit 1; }; exit 0" t/s.test.sh
  trunk land fs >/dev/null 2>&1 || fail "fs must land"
  top=$(tip)
  # The trunk was pinned red below them, as trunk-v3 was at 9f5bbb3af0d1.
  printf '%s\n' "$first" > "$HOME_D/state/trunk-red-proj"
  out=$(trunk verify "$PROJ" 2>&1) || fail "a verify whose only failures pass on their rerun must pass: $out"
  assert_contains "$out" "judged flaky" "the verify must say it set the flaky failures aside"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$top" ] || fail "a pass on the rerun must move the green pin to $top, got $(cat "$HOME_D/state/trunk-green-proj")"
  [ ! -e "$HOME_D/state/trunk-red-proj" ] || fail "a green verify above the red pin must clear it"
  [ "$(grep -c '^add ' "$W/backlog-calls")" = 2 ] || fail "each flaky test must be filed as its own row: $(cat "$W/backlog-calls")"
  assert_contains "$(grep '^add flaky-proj-r ' "$W/backlog-calls")" "t/r.test.sh" "t/r.test.sh gets its own fix row"
  assert_contains "$(grep '^add flaky-proj-s ' "$W/backlog-calls")" "t/s.test.sh" "t/s.test.sh gets its own fix row"
  [ "$(grep -c "$top" "$HOME_D/data/trunk/flaky-proj.tsv")" = 2 ] || fail "each flaky test is recorded: $(cat "$HOME_D/data/trunk/flaky-proj.tsv")"
  # They flake again at a later commit: recorded again, filed once.
  lane ft 'exit 0' t/t.test.sh; trunk land ft >/dev/null 2>&1 || fail "ft must land"
  rm -f -- "$W/seen-r" "$W/seen-s"
  out=$(trunk verify "$PROJ" 2>&1) || fail "the second flaky verify must pass: $out"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] || fail "the second pass on the rerun must move the pin too"
  [ "$(grep -c '^add ' "$W/backlog-calls")" = 2 ] || fail "a flaky test already filed is not filed again: $(cat "$W/backlog-calls")"
  [ "$(grep -c . "$HOME_D/data/trunk/flaky-proj.tsv")" = 4 ] || fail "every flaky run is recorded: $(cat "$HOME_D/data/trunk/flaky-proj.tsv")"
  pass 'a verify whose only failures pass on their rerun moves the green pin, clears a red pin below it, and files one row per flaky test'
}

test_a_landing_does_not_hold_the_trunk_while_its_gate_runs() {
  local c0 p1 out
  world longland
  lane l0 one; c0=$(tip_after_land l0); slow_gate
  lane l1 SLOW slow.txt; lane l3 three other.txt
  trunk land l1 > "$W/l1.out" 2>&1 & p1=$!
  await_gate 'ticket l1'
  # While the long landing is in its gate, a verify reads the tip, runs and moves the pin, and another lane lands.
  out=$(timeout 60 env PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="$W/root" JG_STATE_OVERRIDE="$HOME_D/state" JG_DATA_OVERRIDE="$HOME_D/data" JG_CONFIG_OVERRIDE="$HOME_D/config" "$W/root/bin/jg-trunk.sh" verify "$PROJ" "$c0" 2>&1) || fail "a verify must finish while a landing's gate runs: $out"
  kill -0 "$p1" 2>/dev/null || fail "the long landing must still be gating when the verify ends: $(cat "$W/l1.out")"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c0" ] || fail "the verify must move the pin while the landing is gating"
  out=$(trunk land l3 2>&1) || fail "another lane must land while a landing is gating: $out"
  # The long landing's tip moved under it, so it is rebased onto the new tip and gated again; it lands once the gate is released.
  : > "$W/release"; wait "$p1" || fail "the long landing must land after its tip moved: $(cat "$W/l1.out")"
  assert_contains "$(cat "$W/l1.out")" "while l1 was gated" "the landing must say it gated again on the new tip"
  [ "$(seen 'ticket l1')" = 2 ] || fail "the lane must be gated again on the new tip, got $(seen 'ticket l1') runs"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$c0..trunk" | paste -sd, -)" = "ticket l3,ticket l1" ] || fail "both lanes land, in the order they were ready to move the trunk"
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$(tip)" ] || fail "the tip record follows the trunk"
  pass 'a landing holds no trunk lock while its gate runs: a verify finishes and moves the pin, another lane lands, and the first is re-gated on the new tip'
}

test_a_stack_holds_no_trunk_lock_while_its_gate_runs_and_is_judged_again_on_a_moved_tip() {
  local base p1 out
  world longstack; base=$(tip); slow_gate
  lane s1 SLOW slow.txt; lane s2 two f2.txt; lane s3 three other.txt
  trunk land-batch s1 s2 > "$W/b.out" 2>&1 & p1=$!
  await_gate 'ticket s2'
  out=$(trunk land s3 2>&1) || fail "a lane must land while a stack is gating: $out"
  : > "$W/release"; wait "$p1" || fail "the stack must land after its tip moved: $(cat "$W/b.out")"
  assert_contains "$(cat "$W/b.out")" "moved while the stack was gated" "the stack must say it judged again"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket s3,ticket s1,ticket s2" ] || fail "the stack lands on top of the lane that moved the trunk"
  [ "$(grep -c '^landed s' "$W/b.out")" = 2 ] || fail "both lanes of the stack land: $(cat "$W/b.out")"
  pass 'a stack holds no trunk lock while its gate runs and is judged again when the trunk moved under it'
}

# The release pull request is the trunk against the default-branch commit it was cut from, and CI maps every path changed since
# then; a verify that judged only the last commit's paths would pin green a trunk whose release CI then finds red.
test_verify_judges_every_change_since_the_release_base() {
  local c2 out
  world releasebase
  lane v1 one f1.txt; tip_after_land v1 >/dev/null; lane v2 two f2.txt; c2=$(tip_after_land v2)
  # A gate that records the paths it is asked to judge from the HEAD^ it is given, as the changed-tests gate maps them.
  printf 'gate-verify=git diff --name-only HEAD^ HEAD >> %s/judged\n' "$W" >> "$HOME_D/config/trunk-policy"
  out=$(trunk verify "$PROJ" "$c2" 2>&1) || fail "verify must pass: $out"
  assert_contains "$out" "since the release base" "verify must say it judges every change since the release base"
  { grep -qx f1.txt "$W/judged" && grep -qx f2.txt "$W/judged"; } \
    || fail "verify must judge every path landed since the release base, not only the last commit's: $(paste -sd, "$W/judged")"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c2" ] || fail "a green verify over the release's changes moves the pin"
  pass 'verify judges every change since the release base, the set CI maps for the release pull request'
}

test_queued_verifies_run_one_at_a_time_and_only_the_newest_runs
test_a_verify_moves_the_pin_over_a_red_its_parent_already_had
test_a_verify_whose_only_failures_pass_on_rerun_moves_the_pin_and_files_one_row_per_flaky_test
test_a_landing_does_not_hold_the_trunk_while_its_gate_runs
test_a_stack_holds_no_trunk_lock_while_its_gate_runs_and_is_judged_again_on_a_moved_tip
test_verify_judges_every_change_since_the_release_base
printf 'jg-trunk-verify: ok\n'
