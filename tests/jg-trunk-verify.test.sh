#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: verify (the whole suite, run by hand) and the trunk lock (tests/jg-trunk-fixture.sh).
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh, reads bin/jg-dod-lib.sh and stands in for bin/jg-captain-hold.sh,
# bin/jg-backlog.sh, bin/jg-send.sh, bin/jg-teardown.sh, bin/jg-fleet-ledger.sh and bin/jg-home-health.sh.
#
# Queued verifies run one at a time and only the newest runs, and its green moves the pin over the rest; a verify whose
#    only failures its parent already had leaves the pin where the landing put it, and one holding a red the commit added
#    takes the pin back below that commit. A verify whose only failures pass on their one rerun moves the pin too, and each
#    flaky test is recorded and filed once as its own fix row. A gate shard over its wall-clock budget with no failed test
#    is a warning and a machine-load row, never a red.
# A red with no failed test (the stall of 10 Nov) warns and runs once more, pins and reverts nothing, and a ready lane lands on it
#    through the real check with no hand step and no marker file. A trunk with no green for 15 minutes raises one alarm, not two.
# No landing or stack holds the trunk lock while its gate runs: a verify finishes and moves the pin, another lane lands,
#    and a lane or stack whose tip moved under its gate is judged again on the moved tip.
# Verify judges every change since the trunk's release base (data/trunk-versions.tsv), the set CI maps for the release
#    pull request, not only the last commit's.
# The nightly whole run (jg8-t5, `jg-trunk.sh nightly`, started by the tick): one report a day, a flaky script filed once, a red traced
#    to its commit and reverted by the verify's own code.
# The done-done journey journeys/trunk-landing.sh runs this file and seals its output.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# tip_after_land <id>: lands the lane and prints the new trunk tip.
tip_after_land() { trunk land "$1" >/dev/null 2>&1 || fail "$1 must land"; tip; }

# A gate that records what it judged and stays open, until the test releases it, on a commit whose tree holds SLOW.
# It also ends when this test script is gone: a case that fails before the release must not leave it looping, because
# the orphan holds the sealed run's output open until the script time bound.
# One gate slot: with two, a lane landed while this gate runs is gated on top of the SLOW commit and waits for the release
# that only comes after it lands, so the case would hang for ever. Gating two lanes at once is tests/jg-trunk-two-gates.test.sh.
slow_gate() {
  printf '#!/usr/bin/%s bash\ngit log -1 --format=%%s >> %s/gate-seen\nif git grep -q SLOW; then while [ ! -e %s/release ] && kill -0 %s 2>/dev/null; do sleep 0.1; done; fi\n' env "$W" "$W" "$$" > "$W/slow-gate.sh"
  printf 'gate-full=bash %s/slow-gate.sh\ngate-slots=1\n' "$W" >> "$HOME_D/config/trunk-policy"
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
  printf '%s\n' "$c1" > "$HOME_D/state/trunk-green-proj"  # a pin under the tip, as a red found after a landing leaves it
  # A whole-suite run that records which commit it ran at and stays open until the test releases it.
  printf '#!/usr/bin/env bash\ngit rev-parse HEAD >> %s/verify-ran\nwhile [ ! -e %s/release ] && kill -0 %s 2>/dev/null; do sleep 0.1; done\n' "$W" "$W" "$$" > "$W/slow.sh"
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
  pass 'queued verifies run one at a time and only the newest runs; its green moves the pin over the rest'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_verify_moves_the_pin_over_a_red_its_parent_already_had() {
  local out good
  world parentred; rig; seed_red_tip
  cp "$HOME_D/state/trunk-tip-proj" "$HOME_D/state/trunk-green-proj"  # the red tip is the trunk's accepted green: its red is the parent's own
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
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$good" ] || fail "a red the commit added must take the pin back below it"
  pass 'the green pin stands over failures the parent already had, and goes back below a red the commit added'
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
  top=$(tip); printf '%s\n' "$first" > "$HOME_D/state/trunk-green-proj"  # a pin under the tip, as a red found after a landing leaves it
  out=$(trunk verify "$PROJ" 2>&1) || fail "a verify whose only failures pass on their rerun must pass: $out"
  assert_contains "$out" "judged flaky" "the verify must say it set the flaky failures aside"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$top" ] || fail "a pass on the rerun must move the green pin from $first to $top, got $(cat "$HOME_D/state/trunk-green-proj")"
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
  pass 'a verify whose only failures pass on their rerun moves the green pin and files one row per flaky test'
}

# A parent that cannot run (its rerun runner dies at start and prints no summary) cannot show a lane added a red: the verify charges
# nothing to the child, reverts nothing and keeps the pin (jg8-red-verify-parent).
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_verify_never_charges_a_red_to_a_child_when_its_parent_cannot_run() {
  local out pin top
  world deadparent; rig
  printf 'gate-verify=bash %s/rig.sh --all\ngate-full=true\ngate-rerun=[ -e DEAD ] && exit 3; bash %s/rig.sh\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
  lane dead 'exit 0' DEAD; trunk land dead >/dev/null 2>&1 || fail "the lane that makes the parent unable to rerun must land"
  lane good 'exit 0' t/e.test.sh; trunk land good >/dev/null 2>&1 || fail "good must land"
  pin=$(tip); printf '%s\n' "$pin" > "$HOME_D/state/trunk-green-proj"
  lane bad 'echo "not ok - red" >&2; exit 1' t/e.test.sh; trunk land bad >/dev/null 2>&1 || fail "bad must land past the fast gate"
  top=$(tip)
  out=$(trunk verify "$PROJ" 2>&1) && fail "a red the verify cannot judge is not green: $out"
  assert_contains "$out" "gave no result for" "the verify must say the parent could not judge the red"
  [ "$(tip)" = "$top" ] || fail "no commit is reverted when the parent cannot run: $out"
  if git -C "$PROJ" log --format=%B trunk | grep -q '^reverts: '; then fail "a parent that cannot run reverts nothing"; fi
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$pin" ] || fail "the pin stays where it was"
  pass 'a red is never charged to a child, and nothing is reverted, when its parent cannot run'
}

# The rerun is judged as the first run: a rerun red that no failed script accounts for (its summary counts more failures than it
# lists) is not charged to the lane and reverts nothing (jg8-red-verify-parent).
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_verify_judges_its_rerun_as_it_judges_the_first_run() {
  local out pin top
  world oddrerun; rig
  printf '#!/usr/bin/env bash\nbash %s/rig.sh "$@"\necho "JG_TEST_SUMMARY total=5 failed=1 skipped_gate=0 duration_ms=1"\nexit 1\n' "$W" > "$W/rerun-odd.sh"
  printf 'gate-verify=bash %s/rig.sh --all\ngate-full=true\ngate-rerun=bash %s/rerun-odd.sh\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
  lane base 'exit 0' t/a.test.sh; trunk land base >/dev/null 2>&1 || fail "base must land"
  pin=$(tip); printf '%s\n' "$pin" > "$HOME_D/state/trunk-green-proj"
  lane bad 'echo "not ok - red" >&2; exit 1' t/e.test.sh; trunk land bad >/dev/null 2>&1 || fail "bad must land past the fast gate"
  top=$(tip)
  out=$(trunk verify "$PROJ" 2>&1) && fail "a red the rerun cannot account for is not green: $out"
  assert_contains "$out" "its rerun failed with no script accounting for it" "the verify must say the rerun is not charged"
  [ "$(tip)" = "$top" ] || fail "no commit is reverted for a rerun no script accounts for: $out"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$pin" ] || fail "the pin stays where it was"
  pass 'a rerun red that no failed script accounts for is not charged to the lane, as for the first run'
}

test_a_landing_does_not_hold_the_trunk_while_its_gate_runs() {
  local c0 p1 out
  world longland
  lane l0 one; c0=$(tip_after_land l0); slow_gate
  printf '%s\n' "$(git -C "$PROJ" rev-parse "$c0^")" > "$HOME_D/state/trunk-green-proj"  # a pin under the tip, for the verify to move
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
  rm -f "$HOME_D/state/trunk-green-proj"  # no pin below the commit to judge from: the release base is the base
  out=$(trunk verify "$PROJ" "$c2" 2>&1) || fail "verify must pass: $out"
  assert_contains "$out" "since the release base" "verify must say it judges every change since the release base"
  { grep -qx f1.txt "$W/judged" && grep -qx f2.txt "$W/judged"; } \
    || fail "verify must judge every path landed since the release base, not only the last commit's: $(paste -sd, "$W/judged")"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c2" ] || fail "a green verify over the release's changes moves the pin"
  pass 'verify judges every change since the release base, the set CI maps for the release pull request'
}

# The line's verify judges the changes since the green pin (D8 answer a): a release base, a pin above it, two commits above the pin.
test_verify_judges_only_the_changes_since_the_green_pin_and_prints_its_seconds() {
  local c1 c2 c3 out
  world greenpin
  lane g1 one f1.txt; c1=$(tip_after_land g1); lane g2 two f2.txt; c2=$(tip_after_land g2); lane g3 three f3.txt; c3=$(tip_after_land g3)
  printf '%s\n' "$c1" > "$HOME_D/state/trunk-green-proj"  # the pin sits on g1; g2 and g3 landed above it
  printf 'gate-verify=git diff --name-only HEAD^ HEAD | tee -a %s/judged\n' "$W" >> "$HOME_D/config/trunk-policy"
  out=$(trunk verify "$PROJ" "$c3" 2>&1) || fail "verify must pass: $out"
  assert_contains "$out" "since the green pin ${c1:0:12}" "verify must say it judges from the green pin"
  [ "$(sort "$W/judged" | paste -sd, -)" = "f2.txt,f3.txt" ] || fail "verify must select the two commits above the pin only: $(paste -sd, "$W/judged")"
  printf '%s\n' "$out" | grep -Eq 'verify: ran .*in [0-9]+s' || fail "verify must print its seconds: $out"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c3" ] || fail "a green run moves the pin to the verified commit"
  pass 'verify judges only the commits since the green pin and prints its seconds'
}

# The whole-suite gate of trunk-v3 at 20eb94ae6054: eight shards at 601 to 651 s of their 600 s budget, at host load 60, and no test
# failed (total=81 failed=0). The old runner ended that run with exit 1 and the verify pinned the trunk red. Its shards now run every
# script and print one JG_TEST_OVERRUN line each, and the verify moves the pin, warns, and keeps one machine-load row per shard.
# A failed test past the budget still holds the pin.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_verify_over_the_wall_clock_budget_with_no_failed_test_moves_the_pin_and_records_the_load() {
  local out top bad k=0 ms
  world overrun; rig
  lane o1 'exit 0' t/o.test.sh; trunk land o1 >/dev/null 2>&1 || fail "o1 must land"; top=$(tip)
  {
    printf '#!/usr/bin/env bash\nbash %s/rig.sh --all; rc=$?\n' "$W"
    for ms in 606547 601220 609490 601802 603834 608064 650849 650651; do
      k=$((k + 1))
      printf 'echo "jg-test-run: warning: ran %sms, over its 600000ms wall-clock budget, at host load 60.12 on 32 cpus" >&2\n' "$ms"
      printf 'echo "JG_TEST_OVERRUN budget_ms=600000 duration_ms=%s load=60.12 cpus=32 selection=changed:base=b96c903b0486;shard=%sof8;exclude-family=real-herdr-gated;jobs=4"\n' "$ms" "$k"
    done
    printf 'echo "JG_TEST_AGGREGATE lanes=8 total=81 failed=0 skipped_gate=1 critical_path_duration_ms=650849"\nexit "$rc"\n'
  } > "$W/overrun-gate.sh"
  printf 'gate-verify=bash %s/overrun-gate.sh\n' "$W" >> "$HOME_D/config/trunk-policy"
  out=$(trunk verify "$PROJ" 2>&1) || fail "a verify over its budget with no failed test must pass: $out"
  assert_contains "$out" "trunk green at ${top:0:12}" "the verify must report the trunk green"
  assert_contains "$out" "8 gate shard(s) ran past the wall-clock budget, a warning and never a red" "the overrun must be one warning line"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$top" ] || fail "the pin must move to $top"
  [ "$(grep -c . "$HOME_D/data/trunk/load-proj.tsv")" = 8 ] || fail "each shard over budget is one load row: $(cat "$HOME_D/data/trunk/load-proj.tsv")"
  [ "$(head -n 1 "$HOME_D/data/trunk/load-proj.tsv" | cut -f2-)" = "$top"$'\t1of8\t606547\t600000\t60.12\t32' ] ||
    fail "a load row names the commit, shard, time, budget, host load and cpus: $(head -n 1 "$HOME_D/data/trunk/load-proj.tsv")"
  # A failed test over the budget is still a red: the pin holds, and the overrun is still recorded.
  lane o2 'echo "not ok - Umer fixture failure" >&2; exit 1' t/p.test.sh
  printf 'gate-full=true\n' >> "$HOME_D/config/trunk-policy"
  trunk land o2 >/dev/null 2>&1 || fail "o2 lands past a fast gate"; bad=$(tip)
  trunk verify "$PROJ" "$bad" >/dev/null 2>&1 && fail "a failed test over the budget must not pass verify"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$top" ] || fail "a failed test over the budget must not move the pin"
  [ "$(grep -c "$bad" "$HOME_D/data/trunk/load-proj.tsv")" -ge 8 ] || fail "the red run's overruns are recorded too"
  pass 'a verify whose shards ran over the wall-clock budget with no failed test moves the pin, warns once and records the load; a failed test stays red'
}

# The stall of 10 Nov: trunk-v3's tip verify ended with failed=0, every shard over its wall-clock budget and exit 1. The old verify
# wrote a red pin, every landing but a fixes-red commit was refused for about 5 hours while 17 lanes waited, and Main cleared the pin
# by hand. Now that run warns and runs once more, moves the pin nowhere and reverts nothing, and a ready lane lands through the real
# landing check with no hand step, no marker file and no whole-suite run after it.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_red_with_no_failed_test_never_pins_and_a_ready_lane_lands_on_it() {
  local out top k pin
  world nostall; rig
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane s1 'exit 0' t/s1.test.sh; trunk land s1 >/dev/null 2>&1 || fail "s1 must land"; top=$(tip)
  [ "$(cat "$HOME_D/state/trunk-green-proj")" != "$top" ] || fail "a landing does not move the green pin"
  pin=$(cat "$HOME_D/state/trunk-green-proj")
  {
    printf '#!/usr/bin/env bash\necho run >> %s/verify-runs\nbash %s/rig.sh --all || exit\n' "$W" "$W"
    for k in 1 2 3 4 5 6 7 8; do
      printf 'echo "JG_TEST_OVERRUN budget_ms=600000 duration_ms=60%s000 load=60.12 cpus=32 selection=changed:base=b96c903b0486;shard=%sof8;jobs=4"\n' "$k" "$k"
    done
    printf 'echo "JG_TEST_AGGREGATE lanes=8 total=81 failed=0 skipped_gate=1"\nexit 1\n'
  } > "$W/stall-gate.sh"
  printf 'gate-verify=bash %s/stall-gate.sh\n' "$W" >> "$HOME_D/config/trunk-policy"
  out=$(trunk verify "$PROJ" 2>&1) && fail "a whole suite that ended with exit 1 is not green: $out"
  assert_contains "$out" "no failed test charged to a commit; it is not pinned or reverted, and it runs once more" "the verify must warn and run once more"
  [ "$(grep -c . "$W/verify-runs")" = 2 ] || fail "the suite runs once more, and only once: $(grep -c . "$W/verify-runs") runs"
  assert_contains "$out" "nothing is reverted and the green pin stays at ${pin:0:12}: landings go on" "the verify must say nothing moves"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$pin" ] || fail "a red with no failed test leaves the pin where it was"
  [ "$(tip)" = "$top" ] || fail "a red with no failed test moves nothing on the trunk"
  if git -C "$PROJ" log --format=%B trunk | grep -q '^reverts: '; then fail "a red with no failed test reverts nothing"; fi
  # A ready lane lands through the real check, with no hand step: no flush, no land-next, no marker to clear.
  lane s2 'exit 0' t/s2.test.sh
  out=$(sweep)
  for _ in $(seq 1 150); do git -C "$PROJ" log -1 --format=%s trunk | grep -qx 'ticket s2' && break; sleep 0.2; done
  sweep >/dev/null
  git -C "$PROJ" log -1 --format=%s trunk | grep -qx 'ticket s2' || fail "the ready lane must land on a trunk whose suite ended red with no failed test: $out $(cat "$HOME_D"/data/jg-trunk-landing/s2.*.log 2>&1)"
  [ "$(find "$HOME_D/state" -name 'trunk-red*' -o -name '*cleared*' -o -name '*.land-next' -o -name 'trunk-flush-*' | grep -c .)" = 0 ] \
    || fail "no marker file is written or needed: $(ls "$HOME_D/state")"
  # The tick's verify of s2's tip ends the same way: two runs, no pin, no revert; and a tip it ended on is not run again each minute.
  for _ in $(seq 1 150); do [ "$(grep -c . "$W/verify-runs")" = 4 ] && break; sleep 0.2; done
  [ "$(grep -c . "$W/verify-runs")" = 4 ] || fail "the tick must verify s2's tip, run twice: $(grep -c . "$W/verify-runs") runs"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$pin" ] || fail "a red with no failed test moves no pin, even after the next landing"
  sweep >/dev/null; sleep 2; [ "$(grep -c . "$W/verify-runs")" = 4 ] || fail "a tip a verify ended on is not verified again: $(grep -c . "$W/verify-runs") runs"
  pass 'a red with no failed test warns, runs once more, moves and reverts nothing, a ready lane lands on it with no hand step, and the tip is not verified again'
}

# The line's verify (jg8-l0d), started by the tick: two changes that each pass the landing gate alone and break together both land and
# move no pin; the tick's verify is red, traces the red to the second change and reverts it, raises line-red, and the pin and the
# go-live stay where they were; the next verify, on the reverted tip, is green and moves the pin to the tip.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_the_tick_verifies_a_landed_pair_that_breaks_together_and_the_pin_moves_only_on_green() {
  local base a b tipc q
  world linered; rig
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  q="$HOME_D/state/.wake-queue"
  # The landing gate is quick and per change (true); the verify runs the whole suite, whose one test fails when both files exist.
  printf 'gate-full=true\ngate-verify=bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"
  lane lp '[ ! -e a.txt ] || [ ! -e b.txt ] || { echo "not ok - pair" >&2; exit 1; }' t/pair.test.sh; tip_after_land lp >/dev/null
  tip > "$HOME_D/state/trunk-green-proj"; base=$(tip)  # the pair test is part of the accepted green
  lane la one a.txt; a=$(tip_after_land la); lane lb two b.txt; b=$(tip_after_land lb)
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$base" ] || fail "two landings must not move the green pin"
  sweep >/dev/null
  for _ in $(seq 1 150); do git -C "$PROJ" log --format=%B trunk | grep -q '^reverts: ' && break; sleep 0.2; done
  git -C "$PROJ" log -1 --format=%B trunk | grep -qx "reverts: $b" || fail "the tick's verify must revert the second change, the one the red is traced to: $(git -C "$PROJ" log -2 --format=%B trunk) log: $(cat "$HOME_D/data/jg-trunk-landing/verify-proj.log" 2>&1)"
  git -C "$PROJ" log --format=%B "$a^..$a" | grep -q '^reverts: ' && fail "the first change stays"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$a" ] || fail "a red verify moves the pin only to the last commit before the bad one ($a), not over it"
  for _ in $(seq 1 150); do grep -qs "alert-line-red--proj-${b:0:12}" "$q" && break; sleep 0.2; done
  grep -q "alert-line-red--proj-${b:0:12}" "$q" || fail "line-red must be raised for the traced commit: $(cat "$q" 2>&1)"
  assert_contains "$(grep 'line-red' "$q")" "alert line-red (P1) at rung 2 for lead" "the alert is named line-red"
  # No go-live takes the red head: the home goes live on the pin only, which no landing or red verify moved.
  trunk word live "$PROJ" "go" >/dev/null 2>&1
  trunk live "$PROJ" >/dev/null 2>&1 || :
  ! grep -qs "$b" "$W/live-moves" || fail "the red change must never go live: $(cat "$W/live-moves")"
  # The tick verifies the reverted tip: green, and the pin moves to the tip, one verify at a time.
  tipc=$(tip); sweep >/dev/null
  for _ in $(seq 1 150); do [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$tipc" ] && break; sleep 0.2; done
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$tipc" ] || fail "a green verify must move the pin to the tip ${tipc:0:12}: $(cat "$HOME_D/data/jg-trunk-landing/verify-proj.log" 2>&1)"
  sweep >/dev/null; sleep 1; [ "$(tip)" = "$tipc" ] || fail "a tip at the pin starts no verify and moves nothing"
  pass 'the tick verifies two landed changes that break together: the second is traced and reverted, line-red fires, the pin and live stay put, and a green verify of the reverted tip moves the pin'
}

# A trunk with no green commit for no-green-alarm-minutes (15) raises one alarm to Overwatch through the landing check, and a stall
# that goes on is not raised again; once the green pin moves, a new stall raises a new one. A landing never moves the pin, so a stall
# is a tip above the pin that no verify moved it to: here a verify ended on it without a green (state/trunk-verify-last-<project>).
test_no_green_for_15_minutes_raises_one_alarm_not_two() {
  local out green q held
  world nogreen
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  q="$HOME_D/state/.wake-queue"; green=$(cat "$HOME_D/state/trunk-green-proj")
  assert_contains "$(trunk green-alarm "$PROJ" 2>&1)" "is green at ${green:0:12}" "a trunk at its green pin raises nothing"
  lane a1 one; trunk land a1 >/dev/null 2>&1 || fail "a1 must land"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$green" ] || fail "a landing does not move the pin"
  tip > "$HOME_D/state/trunk-verify-last-proj"  # a verify ended on a1's tip without a green, so the tick does not run it again
  assert_contains "$(trunk green-alarm "$PROJ" 2>&1)" "for 0 of 15 minutes" "a fresh landing is not a stall"
  # The landing is 16 minutes old and the pin is still below it.
  awk -F'\t' -v OFS='\t' -v t=$(( $(date +%s) - 960 )) '{ $4 = t; print }' "$HOME_D/data/trunk-landings.tsv" > "$W/rows" && mv "$W/rows" "$HOME_D/data/trunk-landings.tsv"
  sweep >/dev/null; rm -f "$HOME_D"/data/jg-trunk-landing/.green-alarm-*; sweep >/dev/null
  [ "$(grep -c 'has had no green commit for 16 minutes' "$q")" = 1 ] || fail "the stall must raise one alarm through the landing check, not two: $(cat "$q" 2>&1)"
  grep 'has had no green commit' "$q" | grep -q "alert-line-red--proj-no-green-${green:0:12}" || fail "the stall raises line-red for the lead: $(cat "$q")"
  assert_contains "$(grep 'has had no green commit' "$q")" "live stays on ${green:0:12}" "the alarm says live stays on the last green commit"
  assert_contains "$(trunk green-alarm "$PROJ" 2>&1)" "already raised for the green pin ${green:0:12}" "a stall that goes on is not raised again"
  # The pin moves, and a later stall raises a new alarm.
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "the trunk must verify green"
  green=$(tip); assert_contains "$(trunk green-alarm "$PROJ" 2>&1)" "is green at ${green:0:12}" "a green tip raises nothing"
  lane a2 two; trunk land a2 >/dev/null 2>&1 || fail "a2 must land"
  awk -F'\t' -v OFS='\t' -v t=$(( $(date +%s) - 1200 )) '{ $4 = t; print }' "$HOME_D/data/trunk-landings.tsv" > "$W/rows" && mv "$W/rows" "$HOME_D/data/trunk-landings.tsv"
  # The alarm is quiet while a verify runs (its slot's lock is held), and speaks once it ends.
  bash -c '. "$1"; jg_lock_try_acquire "$2" && sleep 3 && jg_lock_release "$2"' _ "$ROOT/bin/jg-wake-lib.sh" "$HOME_D/state/.trunk-verify-proj.lock" & held=$!
  for _ in $(seq 1 50); do [ -e "$HOME_D/state/.trunk-verify-proj.lock" ] && break; sleep 0.1; done
  assert_contains "$(trunk green-alarm "$PROJ" 2>&1)" "a verify is running" "the alarm is quiet while a verify runs"
  wait "$held"
  out=$(trunk green-alarm "$PROJ" 2>&1); assert_contains "$out" "raised:" "a new stall above a moved pin is raised"
  [ "$(grep -c 'has had no green commit' "$q")" = 2 ] || fail "each stall is raised once: $(cat "$q")"
  pass 'a trunk with no green for 15 minutes raises one alarm through the landing check, never two, and a new stall after the pin moved raises one more'
}

# The nightly whole run (jg8-t5), started by the tick: every script on the tip through the same verify. Of three changes landed since the
# day's first commit, one carries a script that fails once and passes on its rerun, and two pass the landing gate alone and break
# together. The one run writes its day's report, files the flaky script as exactly one ticket, traces the red to the second of the pair
# and reverts it with line-red, and the same day starts no second run.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_the_nightly_run_writes_its_report_files_one_flake_ticket_and_traces_a_red_to_its_commit() {
  local base b day report q out runs
  world nightly; rig
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  q="$HOME_D/state/.wake-queue"; day=$(date -u +%F); report="$HOME_D/data/trunk/nightly-proj-$day.md"
  printf 'gate-full=true\ngate-verify=false\ngate-nightly=bash %s/rig.sh --all\nnightly-hour=0\n' "$W" >> "$HOME_D/config/trunk-policy"
  # The day's first commit is two days old; the landing gate is quick, and the verify gate (false) must not be the one the nightly runs.
  GIT_COMMITTER_DATE=$(date -u -d '2 days ago' +%FT%TZ) lane np '[ ! -e a.txt ] || [ ! -e b.txt ] || { echo "not ok - pair" >&2; exit 1; }' t/pair.test.sh; tip_after_land np >/dev/null
  base=$(tip); tip > "$HOME_D/state/trunk-green-proj"
  lane nf "[ -e $W/seen-f ] || { : > $W/seen-f; echo 'not ok - flaky f' >&2; exit 1; }; exit 0" t/f.test.sh; tip_after_land nf >/dev/null
  lane na one a.txt; tip_after_land na >/dev/null; lane nb two b.txt; b=$(tip_after_land nb)
  tip > "$HOME_D/state/trunk-verify-last-proj"  # the line's own verify has ended on this tip, so only the nightly run is due
  [ "$(trunk nightly-due "$PROJ" 2>&1)" = "$day" ] || fail "the nightly run must be due at its hour: $(trunk nightly-due "$PROJ" 2>&1)"
  sweep >/dev/null
  for _ in $(seq 1 300); do [ -s "$report" ] && break; sleep 0.2; done
  [ -s "$report" ] || fail "the nightly run must write its report: $(cat "$HOME_D/data/jg-trunk-landing/nightly-proj.log" 2>&1)"
  assert_contains "$(cat "$report")" "red, traced to its commit and reverted" "the report names the result"
  assert_contains "$(cat "$report")" "judged against: $base" "the report names the day's first commit it judged against"
  assert_contains "$(cat "$report")" "t/f.test.sh" "the report names the flaky script"
  git -C "$PROJ" log -1 --format=%B trunk | grep -qx "reverts: $b" || fail "the red must be traced to the second of the pair and reverted: $(git -C "$PROJ" log -2 --format=%B trunk)"
  for _ in $(seq 1 100); do grep -qs "alert-line-red--proj-${b:0:12}" "$q" && break; sleep 0.2; done
  grep -q "alert-line-red--proj-${b:0:12}" "$q" || fail "line-red must be raised for the traced commit: $(cat "$q" 2>&1)"
  [ "$(grep -c '^add ' "$W/backlog-calls")" = 1 ] || fail "the flaky script must be filed as exactly one ticket: $(cat "$W/backlog-calls")"
  assert_contains "$(grep '^add flaky-proj-f ' "$W/backlog-calls")" "t/f.test.sh" "the ticket names the script"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$base" ] || fail "a red nightly run must not move the green pin"
  # One run a day: the same day starts no second one.
  out=$(trunk nightly-due "$PROJ" 2>&1) && fail "a day with a finished nightly run is not due again: $out"
  runs=$(find "$HOME_D/data/trunk" -name 'nightly-proj-*.md' | grep -c .); sweep >/dev/null; sleep 1
  [ "$(find "$HOME_D/data/trunk" -name 'nightly-proj-*.md' | grep -c .)" = "$runs" ] || fail "a second tick the same day must write no second report"
  pass 'the nightly run writes its day report, files the flaky script as one ticket, traces a red to its commit and reverts it, and runs once a day'
}

test_queued_verifies_run_one_at_a_time_and_only_the_newest_runs
test_a_verify_moves_the_pin_over_a_red_its_parent_already_had
test_a_verify_over_the_wall_clock_budget_with_no_failed_test_moves_the_pin_and_records_the_load
test_a_verify_whose_only_failures_pass_on_rerun_moves_the_pin_and_files_one_row_per_flaky_test
test_a_verify_never_charges_a_red_to_a_child_when_its_parent_cannot_run
test_a_verify_judges_its_rerun_as_it_judges_the_first_run
test_a_landing_does_not_hold_the_trunk_while_its_gate_runs
test_a_stack_holds_no_trunk_lock_while_its_gate_runs_and_is_judged_again_on_a_moved_tip
test_verify_judges_every_change_since_the_release_base
test_verify_judges_only_the_changes_since_the_green_pin_and_prints_its_seconds
test_a_red_with_no_failed_test_never_pins_and_a_ready_lane_lands_on_it
test_the_tick_verifies_a_landed_pair_that_breaks_together_and_the_pin_moves_only_on_green
test_no_green_for_15_minutes_raises_one_alarm_not_two
test_the_nightly_run_writes_its_report_files_one_flake_ticket_and_traces_a_red_to_its_commit
printf 'jg-trunk-verify: ok\n'
