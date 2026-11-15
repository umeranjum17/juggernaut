#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: the landing gate and the proof a lane lands with (tests/jg-trunk-fixture.sh).
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh, reads bin/jg-dod-lib.sh and stands in for bin/jg-captain-hold.sh,
# bin/jg-backlog.sh, bin/jg-send.sh, bin/jg-teardown.sh, bin/jg-fleet-ledger.sh and bin/jg-home-health.sh.
#
# T11 The landing gate charges a lane only for what it broke: a script red on the trunk tip in the same way does not block
#    (it is reported once per tip tree), while a script that fails only on the lane, passes on the
#    tip, or fails differently on the lane blocks it, with the tip's rerun done in the environment the gate ended with.
#    A failure gets one rerun on the lane before it is judged: one that passes on the rerun is flaky and not charged, and is
#    recorded and filed once as its own fix row. A lane is charged for a script only when its parent passes it 3 of 3: one that
#    fails by itself on the parent is flaky, lands, and is filed once.
# T12 A landing is one fast check: the lander rebases the lane's one commit onto the tip by itself (the lane follows it),
#    and a lane lands only with its whole proof at its head (receipt, sealed done-done run; no merge-card judge); the owner signature never blocks it.
# T13 The journey: four lanes ready at once, three land in order with no human or lead step, the red one is refused, no
#    landing moves the green pin, and no landing runs a whole suite or moves the pin (the tick's verify does), so a whole suite that would be red
#    (a shard over its time budget, as trunk-v3 at 9f5bbb3af0d1) stops no landing. A green pin left 6 hours behind 9 landings
#    moves to the next landing's head, and the landing's check judges that lane's changed scripts alone, however many landings
#    sit above the release base. A red a hand-run verify finds is reported and never reverted: it takes the green pin back below it, the lane
#    is told, one alert names its owner, and the next lane still lands.
# The done-done journey journeys/trunk-landing.sh runs this file and seals its output.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
# shellcheck source=tests/title-rule-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/title-rule-lib.sh"
JG_TRUNK_FIXTURE_CACHE=1

# shellcheck disable=SC2016 # the gate body is written out verbatim and expands when the gate runs it
# Two verifies of one head each get their own attempt: the second never truncates or reuses the first's log or phase history,
# and a log shows its output while the gate still runs (the line is there before the gate ends).
test_every_verify_attempt_keeps_its_own_log_and_phase_history() {
  local c first firstlog logs n
  world attempts; rig
  lane a1 'true' t/a.test.sh
  trunk land a1 >/dev/null 2>&1 || fail "a1 must land: $(trunk land a1 2>&1)"
  c=$(tip)
  printf 'gate-verify=echo attempt-output-$(date +%%s%%N)-$$; sleep 1\n' >> "$HOME_D/config/trunk-policy"
  trunk verify "$PROJ" "$c" >/dev/null 2>&1 || fail "the first verify must pass"
  firstlog=$(find "$HOME_D/data/trunk" -name "gate-proj-${c:0:12}-*-full.log"); first=$(cat "$firstlog")
  trunk verify "$PROJ" "$c" >/dev/null 2>&1 || fail "the second verify must pass"
  logs=$(find "$HOME_D/data/trunk" -name "gate-proj-${c:0:12}-*-full.log" | sort)
  [ "$(printf '%s\n' "$logs" | wc -l | tr -d ' ')" = 2 ] || fail "each verify attempt must keep its own full log: $logs"
  [ "$(cat "$firstlog")" = "$first" ] && [ "$(grep -c '^attempt-output-' <<< "$first")" = 1 ] || fail "the second attempt changed the first attempt's log: $(cat "$firstlog")"
  [ "$(printf '%s\n' "$logs" | xargs cat | grep -c '^attempt-output-')" = 2 ] || fail "the two attempts must hold two different runs"
  [ "$(find "$HOME_D/data/trunk" -name "gate-proj-${c:0:12}-*.phases" | wc -l | tr -d ' ')" = 2 ] || fail "each attempt must have its own phase history"
  while IFS= read -r n; do
    [ "$(cut -f2 "$n" | paste -sd' ')" = "start end" ] || fail "an attempt's history shows its own phases once: $(cat "$n")"
    [ "$(cut -f4 "$n" | tail -n 1)" = 0 ] || fail "the history records the exit status: $(cat "$n")"
  done < <(find "$HOME_D/data/trunk" -name "gate-proj-${c:0:12}-*.phases")
  pass 'every verify attempt keeps its own log and phase history, and a second run of the same head changes neither'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_changed_file_that_is_not_a_test_is_never_run_bare_on_the_tip() {
  local out
  world nontest; rig
  # The tip carries a library and a command that fail when bash runs them bare; the gate reports a changed path it has no test for
  # as a coverage note in its log, never as a failed script, so the lane lands.
  git -C "$PROJ" worktree add -q -b seed "$W/seed" trunk
  commit_in "$W/seed" t/lib.py 'echo "not ok - lib" >&2; exit 2' "seed lib"
  commit_in "$W/seed" t/needs-store.sh 'echo "not ok - store" >&2; exit 2' "seed store"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
  printf 'gate-full=export GATE_MARK=yes; bash %s/rig.sh $(git diff --name-only HEAD~1 | grep -E "^t/(lib.py|needs-store.sh)$")\n' "$W" >> "$HOME_D/config/trunk-policy"
  lane lib 'echo "not ok - lib" >&2; exit 2 # changed' t/lib.py
  out=$(trunk land lib 2>&1) || fail "a changed non-test path is a coverage note, never a failure of the lane: $out"
  [ ! -e "$HOME_D/data/trunk/flaky-proj.tsv" ] || ! grep -q 't/lib.py' "$HOME_D/data/trunk/flaky-proj.tsv" || fail "a mapping failure is never a flaky row"
  ! grep -qs 'flaky-proj-lib' "$W/backlog-calls" || fail "a mapping failure files no flaky ticket"
  [ ! -e "$HOME_D/data/trunk/tip-red-reported-proj.tsv" ] || [ ! -s "$HOME_D/data/trunk/tip-red-reported-proj.tsv" ] || fail "a non-test path is never reported as the tip's red: $(cat "$HOME_D/data/trunk/tip-red-reported-proj.tsv")"
  ! grep -qs 'alert-line-red' "$HOME_D/state/.wake-queue" || fail "a non-test path must raise no tip-red alert: $(cat "$HOME_D/state/.wake-queue")"
  ! grep -qs 't/lib.py' "$HOME_D/data/trunk/"tip-results-proj-*.tsv || fail "the tip is never asked for a non-test path's result"
  ! grep -rqsE 'JG_TEST_BEGIN .* t/(lib.py|needs-store.sh) ' --include='*-tip.log' "$HOME_D/data" || fail "no tip run may start a non-test path"
  pass 'a changed library or store-bound command is a coverage note, never run bare on the tip and never a red'
}

# One gate sees an unmapped path and a real failing journey together: the path is a coverage note that never runs, reruns or files a
# flake row, the journey still reruns once (it passes on the rerun and is filed flaky), and the flake intake closes a fake row an
# earlier gate filed for a non-test path.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_an_unmapped_path_is_a_coverage_note_and_a_real_failure_still_reruns_once() {
  local out
  world cover; rig
  printf 'gate-full=bash %s/rig.sh t/orphan.lib t/n.test.sh\n' "$W" >> "$HOME_D/config/trunk-policy"
  mkdir -p "$HOME_D/data/trunk"; printf '1\tabc\tbin/old-lib.sh\tflaky-proj-old-lib\n' > "$HOME_D/data/trunk/flaky-proj.tsv"
  lane cov "[ -e $W/seen-n ] || { : > $W/seen-n; echo 'not ok - first run' >&2; exit 1; }; exit 0" t/n.test.sh
  out=$(trunk land cov 2>&1) || fail "an unmapped path must not refuse the lane: $out"
  rerun=$(find "$HOME_D/data" -name 'gate-full-rerun.log' -exec cat {} +)
  phases=$(find "$HOME_D/data" -name 'gate.phases' -exec cat {} + | cut -f2,3 | tr '\t\n' ' ')
  assert_contains "$phases" "start gate-full.log end gate-full.log start gate-full-rerun.log end gate-full-rerun.log" "the attempt's phase history shows the full run, then its rerun"
  assert_contains "$rerun" "t/n.test.sh" "the real failing journey is rerun"
  assert_not_contains "$rerun" "t/orphan.lib" "the unmapped path is never rerun"
  assert_contains "$(cat "$HOME_D/data/trunk/flaky-proj.tsv")" "t/n.test.sh" "the journey that passed on its rerun is recorded flaky"
  ! grep -q 'flaky-proj-orphan' "$W/backlog-calls" || fail "the unmapped path files no flaky ticket: $(cat "$W/backlog-calls")"
  grep -q '^done flaky-proj-old-lib' "$W/backlog-calls" || fail "the flake intake closes the fake row an earlier gate filed: $(cat "$W/backlog-calls")"
  pass 'an unmapped path is a coverage note that never runs or files a flake, a real failure still reruns once, and a fake flake row is closed'
}

# The real runner, carried in the project's own tree as every project does, is the rerun command here. A failed result for a data file
# (the name gate's allow list, whose lines are commands to bash) must never start it: the allow list below writes a marker file when run.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_the_gate_rerun_never_runs_a_data_file_as_a_command() {
  local out marker
  world datafile; rig
  marker="$W/allow-list-was-run"
  git -C "$PROJ" worktree add -q -b seed "$W/seed" trunk
  mkdir -p "$W/seed/bin" "$W/seed/tests"
  cp -R "$ROOT/bin/." "$W/seed/bin/"; cp -R "$ROOT/defaults" "$W/seed/defaults"; cp "$ROOT/tests/git-config-helpers.sh" "$W/seed/tests/"
  git -C "$W/seed" add bin defaults tests
  git -C "$W/seed" -c user.name=t -c user.email=t@example.invalid commit -q -m "seed runner"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
  printf '#!/usr/bin/env bash\necho "JG_TEST_BEGIN 2026-01-01T00:00:00Z t/names.allow family=x expected_gate_skip=none"\necho "JG_TEST_END 2026-01-01T00:00:00Z t/names.allow exit=1 duration_ms=1 gate_skip=false type=test"\necho "JG_TEST_SUMMARY total=1 failed=1 skipped_gate=0 duration_ms=1"\nexit 1\n' > "$W/fail-allow.sh"
  # The rig's own gate commands come first in the policy file and are replaced here.
  sed -i '/^gate-full=/d;/^gate-rerun=/d' "$HOME_D/config/trunk-policy"
  printf 'gate-full=bash %s/fail-allow.sh\ngate-rerun=bash bin/jg-test-run.sh --jobs 1\n' "$W" >> "$HOME_D/config/trunk-policy"
  lane allow "touch $marker  # alias for bin/jg-new.sh" t/names.allow
  out=$(trunk land allow 2>&1) && fail "a data file the gate failed must stay the lane's failure: $out"
  assert_contains "$out" "t/names.allow" "the lane is charged for the path it changed"
  [ ! -e "$marker" ] || fail "the gate rerun ran the allow list as a command: $out"
  pass 'the gate rerun never runs a data file as a command'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_the_full_gate_charges_a_lane_only_for_what_it_broke() {
  local out tipc
  world base; rig; seed_red_tip; tipc=$(tip)
  # A lane that adds a failing script of its own: blocked by name, and the tip's red is reported.
  lane intro 'echo "not ok - lane case" >&2; exit 1' t/b.test.sh
  refused 'a failure only the lane has' intro 't/b.test.sh'
  assert_contains "$(trunk land intro 2>&1 || true)" "introduced or changed" "the refusal must say the lane caused it"
  # A lane that makes the tip's red worse (an added failing case in the same script): blocked.
  lane worse '[ "${GATE_MARK:-}" = yes ] && { echo "not ok - tip case" >&2; echo "not ok - new case" >&2; exit 1; }; exit 0' t/a.test.sh
  refused 'a different red in the same script' worse 't/a.test.sh'
  # A lane that breaks a script that passes on the tip: blocked.
  lane breaks 'echo "not ok - broke c" >&2; exit 1' t/c.test.sh
  refused 'a script that passes on the tip' breaks 't/c.test.sh'
  # Reported once for the tip tree: one wake and one note, however many lanes met it; and the tip was rerun once.
  [ "$(grep -c '^update ticket-red ' "$W/backlog-calls")" = 1 ] || fail "the tip's red must be noted once: $(cat "$W/backlog-calls")"
  [ "$(grep -c 'alert-line-red--proj-tip-' "$HOME_D/state/.wake-queue")" = 1 ] || fail "the tip's red must raise one alert: $(cat "$HOME_D/state/.wake-queue" 2>&1)"
  assert_contains "$(cat "$W/backlog-calls")" "update ticket-red --append-notes" "the note goes to the red ticket"
  assert_contains "$(cat "$W/backlog-calls")" "t/a.test.sh" "the note names the red script"
  [ "$(grep -c '^t/a.test.sh' "$HOME_D/data/trunk/"tip-results-proj-*.tsv)" = 1 ] || fail "the tip's result for a script is computed once"
  assert_contains "$(cat "$HOME_D/data/trunk/tip-red-reported-proj.tsv")" "t/a.test.sh" "the report is recorded by script and tip tree"
  [ "$(tip)" = "$tipc" ] || fail "no refused lane moves the trunk"
  # A lane that touches only what is unrelated lands; the tip's red is set aside, not charged, and its gate moves no pin.
  lane good 'exit 0' t/d.test.sh
  out=$(trunk land good 2>&1) || fail "a lane that adds no red must land on a red tip: $out"
  assert_contains "$out" "not charged to this lane" "the landing must say it set the tip's red aside"
  assert_contains "$out" "gate=full-tip-red" "the landing must record that the gate was set against the tip"
  assert_contains "$(tail -n 1 "$HOME_D/data/trunk-landing-proofs.tsv")" "$(printf 'good\tproj\t%s' "$(tip)")" "the landing's proofs row must be the last one"
  [[ $(tail -n 1 "$HOME_D/data/trunk-landing-proofs.tsv") =~ gate=ran:[1-9][0-9]*,failed:[1-9][0-9]*,secs:[0-9]+[[:space:]]done=[0-9]+$ ]] \
    || fail "the proofs row must keep the gate's scripts run, failed on the first run and seconds: $(tail -n 1 "$HOME_D/data/trunk-landing-proofs.tsv")"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" != "$(tip)" ] || fail "a landing that set only the tip's own red aside still does not move the green pin"
  [ "$(grep -c '^update ticket-red ' "$W/backlog-calls")" = 1 ] && [ "$(grep -c 'alert-line-red--proj-tip-' "$HOME_D/state/.wake-queue")" = 1 ] || fail "the same tip tree is not reported twice"
  pass 'the full gate blocks only what the lane broke: new, worse and broken-passing scripts block; the tip'"'"'s own red lands, reported once'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_flaky_failure_gets_one_rerun_before_it_is_judged() {
  local out
  world flaky; rig; seed_red_tip
  # Fails the first time the gate runs it and passes the second: judged flaky, so the lane lands beside the tip's own red.
  lane once "[ -e $W/seen ] || { : > $W/seen; echo 'not ok - flaky case' >&2; exit 1; }; exit 0" t/f.test.sh
  out=$(trunk land once 2>&1) || fail "a failure that passes on its one rerun must not block: $out"
  assert_contains "$out" "judged flaky" "the landing must say it set a flaky failure aside"
  assert_contains "$out" "gate=full-tip-red" "the tip's own red is still set aside and recorded"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" != "$(tip)" ] || fail "a landing whose gate passed on its one rerun does not move the green pin"
  flaky_call=$(grep '^add flaky-proj-f ' "$W/backlog-calls")
  assert_contains "$flaky_call" "add flaky-proj-f Fix a flaky test -l blocker" "the flaky test is filed as its own fix row with a short title and its label"
  assert_contains "$flaky_call" "t/f.test.sh failed and then passed" "the flaky test's name is in the body"
  title_rule_ok "$(printf '%s' "$flaky_call" | sed -E 's/^add [^ ]+ (.*) -l blocker .*/\1/')" || fail "the flaky-test title must pass the title rule: $flaky_call"
  assert_contains "$(cat "$HOME_D/data/trunk/flaky-proj.tsv")" "t/f.test.sh" "the flaky test is recorded"
  # The same script failing on both runs is the lane's own failure.
  lane twice 'echo "not ok - solid case" >&2; exit 1' t/g.test.sh
  refused 'a failure that repeats on the rerun' twice 't/g.test.sh'
  pass 'a failure gets one rerun before it is judged: a flaky one is set aside and filed as its own row, a repeated one blocks'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_lane_is_charged_only_for_a_script_the_parent_passes_three_times_of_three() {
  local out
  world rate; rig
  git -C "$PROJ" worktree add -q -b seed "$W/seed" trunk
  # The script fails with the lane's marker file; with no marker it fails on its 2nd and 5th run, by a counter outside the clone.
  commit_in "$W/seed" t/k.test.sh '[ -e t/mark ] && { echo "not ok - lane case" >&2; exit 1; }; n=$(cat '"$W"'/k-runs 2>/dev/null || echo 0); echo $((n + 1)) > '"$W"'/k-runs; case $((n + 1)) in 2|5) echo "not ok - flaky case" >&2; exit 1 ;; esac; exit 0' "seed k"
  commit_in "$W/seed" t/m.test.sh '[ -e t/mark2 ] && { echo "not ok - lane case" >&2; exit 1; }; exit 0' "seed m"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
  # The parent fails 2 of 6 runs: the script fails by itself, so the lane lands and the script is filed once as flaky.
  lane rated on t/mark
  out=$(trunk land rated 2>&1) || fail "a script that fails by itself on the parent must not be charged to the lane: $out"
  assert_contains "$out" "fails by itself on the parent" "the landing must say it set a flaky parent script aside"
  assert_contains "$(cat "$HOME_D/data/trunk/flaky-proj.tsv")" "t/k.test.sh" "the flaky script is recorded"
  [ "$(grep -c '^add flaky-proj-' "$W/backlog-calls")" = 1 ] || fail "one flaky row is filed: $(cat "$W/backlog-calls")"
  # The parent passes 3 of 3: the same failure on the lane is the lane's own and is charged.
  lane charged on t/mark2
  refused 'a script the parent passes three times of three' charged 't/m.test.sh'
  pass 'a lane is charged only for a script its parent passes 3 of 3: one that fails by itself there lands with one flaky row'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_tip_red_that_prints_its_elapsed_seconds_is_the_same_red_on_every_run() {
  local out
  world elapsed; rig
  git -C "$PROJ" worktree add -q -b seed "$W/seed" trunk
  # A Go test prints its run time on the last line, so the tip's red reads differently on every run.
  commit_in "$W/seed" t/h.test.sh '[ "${GATE_MARK:-}" = yes ] || exit 0; n=$(cat '"$W"'/runs 2>/dev/null || echo 0); echo $((n + 1)) > '"$W"'/runs; printf "FAIL\\tpkg/x\\t2%s.%s3s\\n" "$n" "$n" >&2; exit 1' "seed h"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
  lane good 'exit 0' t/d.test.sh
  out=$(trunk land good 2>&1) || fail "a lane must land beside a tip red that differs from its own run only by elapsed seconds: $out"
  assert_contains "$out" "not charged to this lane" "the tip's red is set aside"
  pass "a tip red that prints its elapsed seconds is the same red on every run, so no lane is charged for it"
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_the_gates_are_policy_keys_with_fast_defaults() {
  local key
  pol() { JG_CONFIG_OVERRIDE="$TMP_ROOT/no-config" bash -c ". '$ROOT/bin/jg-trunk-policy-lib.sh'; jg_trunk_policy $1"; }
  assert_contains "$(pol gate-lint)" "--changed-base HEAD^" "the landing lint must cover the changed files only"
  assert_contains "$(pol gate-full)" "--required-shards HEAD^" "the landing tests must be the changed files' tests, run as the parallel shards"
  case $(pol gate-full) in *"--all"*) fail "the landing must not run the whole suite" ;; esac
  assert_contains "$(pol gate-verify)" "bin/jg-test-run.sh --all" "verify must run the whole suite"
  for key in gate-mode gate-smoke owner-rules; do pol "$key" >/dev/null 2>&1 && fail "the retired policy key $key must be gone"; done
  pass 'the landing gates are policy keys: the lint and tests cover the changed files, the whole suite is verify'"'"'s, run by hand only'
}

# shellcheck disable=SC2016 # the policy lines are written out verbatim and expand when the gate runs them
test_a_project_that_is_not_juggernaut_never_runs_juggernauts_gates() {
  local out rc=0 sha lib="$ROOT/bin/jg-trunk-policy-lib.sh"
  world foreign
  printf 'landing-gate=tests\n' > "$HOME_D/config/trunk-policy"  # no gate override: the built-in defaults decide, and they are Juggernaut's own suite
  # The fixture tracks a file under data/, which Juggernaut's own invariant would reject silently (an empty log, a verify that never passes).
  lane f1 one data/notes.txt
  out=$(trunk land f1 2>&1) || fail "a project with no gates set must land with none run: $out"
  assert_contains "$out" "no landing gate" "the landing must say it ran no gate"
  assert_contains "$(cat "$HOME_D/data/trunk-landings.tsv")" "no-gate" "the landing must record that no gate ran"
  sha=$(tip)
  out=$(trunk verify "$PROJ" "$sha" 2>&1) || fail "verify with no gate must not fail: $out"
  assert_contains "$out" "no verify gate for proj" "verify must say it had no gate"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$sha" ] || fail "verify with no gate must leave the trunk green so the home can go on"
  # The project's own gate-full is its verify gate when it set no gate-verify; its own gate-verify wins over it; both fail for real.
  printf 'gate-full@proj=test ! -e BAD\nlanding-gate=tests\n' > "$HOME_D/config/trunk-policy"
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$HOME_D/config' jg_trunk_gate gate-verify proj '$PROJ' trunk")
  [ "$out" = 'test ! -e BAD' ] || fail "a project with only gate-full@proj must verify with it, got '$out'"
  printf 'gate-full@proj=true\ngate-verify@proj=false\nlanding-gate=tests\n' > "$HOME_D/config/trunk-policy"
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$HOME_D/config' jg_trunk_gate gate-verify proj '$PROJ' trunk")
  [ "$out" = false ] || fail "gate-verify@proj must win over gate-full@proj, got '$out'"
  rc=0; trunk verify "$PROJ" "$sha" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a project's own failing gate-verify must still fail verify"
  # A repository that carries Juggernaut's own suite keeps the built-in defaults.
  mkdir -p "$W/self/bin"; : > "$W/self/bin/jg-test-run.sh"; git init -q "$W/self"; git -C "$W/self" add -A
  git -C "$W/self" -c user.name=t -c user.email=t@example.invalid commit -q -m self
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$W/none' jg_trunk_gate gate-verify self '$W/self' HEAD")
  assert_contains "$out" "bin/jg-test-run.sh --all" "the Juggernaut repository must keep its built-in verify gate"
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$W/none' jg_trunk_gate gate-verify proj '$PROJ' trunk") && fail "another project must have no built-in gate, got '$out'"
  pass 'a project that is not Juggernaut runs only the gates its home set for it'
}

test_a_landing_rebases_the_lane_by_itself() {
  local out rows c1 c2 c3
  world rebase
  # The merge gate of this home refuses every merge for a missing signature: a landing no longer asks it.
  printf '#!/usr/bin/env bash\necho "merge refused: no valid local proof signature" >&2\nexit 1\n' > "$HOME_D/config/merge-gate"; chmod +x "$HOME_D/config/merge-gate"
  lane r1 one a.txt; lane r2 two b.txt; lane r3 three c.txt
  c1=$(git -C "$PROJ" rev-parse fm/r1)
  out=$(trunk land r1 2>&1) || fail "a lane with its whole proof must land: $out"
  [ "$(tip)" = "$c1" ] || fail "r1 must be on the trunk as it is"
  # r2 is based on the old tip: the lander rebases it (its proof is for the head it reported), the lane follows, its worktree stays clean.
  c2=$(git -C "$PROJ" rev-parse fm/r2)
  out=$(trunk land r2 2>&1) || fail "a lane on a moved tip must land by being rebased: $out"
  [ "$(tip)" != "$c2" ] && [ "$(git -C "$PROJ" rev-parse "$(tip)^")" = "$c1" ] || fail "the rebased commit must sit directly on the previous tip"
  [ "$(git -C "$PROJ" rev-parse fm/r2)" = "$(tip)" ] || fail "the lane must follow its rebased commit"
  [ -z "$(git -C "$W/lanes/r2" status --porcelain)" ] && [ "$(git -C "$W/lanes/r2" rev-parse HEAD)" = "$(tip)" ] || fail "the lane's worktree must follow the rebase and stay clean"
  [ "$(git -C "$PROJ" log -1 --format=%s "$(tip)")" = "ticket r2" ] || fail "the rebased commit must keep the lane's message"
  # A lane whose worktree has unsaved work lands, and the work is left alone.
  printf 'unsaved\n' > "$W/lanes/r3/scratch.txt"
  out=$(trunk land r3 2>&1) || fail "a lane with unsaved work in its copy must land: $out"
  c3=$(git -C "$PROJ" rev-parse fm/r3)
  [ "$(tip)" != "$c3" ] && [ -f "$W/lanes/r3/scratch.txt" ] || fail "unsaved work in the lane must be left exactly as it was"
  rows=$(cat "$HOME_D/data/trunk-landing-proofs.tsv")
  assert_contains "$rows" "$(printf 'r1\tproj\t%s' "$c1")" "the landing must be recorded with its facts"
  assert_contains "$rows" "receipt=PASS@" "the sealed receipt is recorded with the landing"
  assert_contains "$rows" "signature=absent" "a missing signature is recorded as absent and never blocks"
  assert_contains "$rows" "merge-card=present" "the merge-card is recorded"
  assert_contains "$rows" "gate=ran:-,failed:-,secs:" "a gate that prints no script summary is recorded with its seconds only"
  # A change that really conflicts is still refused, with its paths, and is never rebased dirty.
  lane x1 left; lane x2 right
  trunk land x1 >/dev/null 2>&1 || fail "x1 must land"
  refused 'a conflicting lane' x2 'conflicts with trunk'
  assert_contains "$(trunk land x2 2>&1)" 'in: work.txt' 'a conflict names its paths'
  pass 'the lander rebases a lane by itself; only the owner signature stays outside the landing'
}

# Every proof input is required at the lane's exact head, at the worker's done and again before a landing starts.
test_done_and_landing_both_refuse_before_starting_on_any_missing_proof_input() {
  local part out id=1 before head
  world proofgate
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  lane ok one a.txt
  out=$(done_gate ok) || fail "a done with complete matching-head proof must be accepted: $out"
  trunk proof ok >/dev/null 2>&1 || fail "the landing pre-check must accept complete matching-head proof"
  lane p1 v1 f1.txt
  # (broken <part>, how it is broken, what the refusal must name)
  for part in receipt-absent:'completion receipt' receipt-fail:'completion receipt' receipt-stale:'completion receipt' \
              seal-absent:'no sealed clean done-done run' seal-stale:'no sealed clean done-done run' seal-dirty:'no sealed clean done-done run'; do
    prove "p$id"
    case ${part%%:*} in
      receipt-absent) rm "$HOME_D/state/p$id.run-receipt.json" ;;
      receipt-fail) prove_part "p$id" receipt FAIL ;;
      receipt-stale) sed -i 's/"head":"[0-9a-f]*"/"head":"0000000000000000000000000000000000000000"/' "$HOME_D/state/p$id.run-receipt.json" ;;
      seal-absent) rm -f "$HOME_D/data/p$id/.done-done/runs/"*.json ;;
      seal-stale) sed -i 's/"commit":"[0-9a-f]*"/"commit":"0000000000000000000000000000000000000000"/;s/20261109T000000Z-[0-9a-f]*/20261109T000000Z-00000000/' "$HOME_D/data/p$id/.done-done/runs/"*.json ;;
      seal-dirty) sed -i 's/"dirty":false/"dirty":true/' "$HOME_D/data/p$id/.done-done/runs/"*.json ;;
    esac
    out=$(done_gate "p$id") && fail "the done must refuse with $part: $out"
    assert_contains "$out" "${part#*:}" "the done refusal for $part must name the missing input"
    before=$(tip); head=$(git -C "$PROJ" rev-parse "fm/p$id")
    trunk proof "p$id" >/dev/null 2>&1 && fail "the landing pre-check must refuse with $part"
    out=$(trunk land "p$id" 2>&1) && fail "the landing must refuse with $part: $out"
    assert_contains "$out" "proof inputs are incomplete" "the landing refusal for $part must say the proof is incomplete"
    assert_contains "$out" "${part#*:}" "the landing refusal for $part must name the missing input"
    [ "$(tip)" = "$before" ] || fail "a landing with $part moved the trunk"
    ! git -C "$PROJ" merge-base --is-ancestor "$head" "$(tip)" || fail "a landing with $part landed the lane"
  done
  # Everything missing is named at once, in one pass, not one input per round trip.
  rm -f "$HOME_D/state/p1.run-receipt.json" "$HOME_D/data/p1/.done-done/runs/"*.json
  out=$(done_gate p1) && fail "a lane with no proof must not be done"
  assert_contains "$out" "completion receipt" "all missing inputs are named together"; assert_contains "$out" "no sealed clean done-done run" "all missing inputs are named together"
  # A done at a new head needs the whole proof again; proving the new head makes both paths accept.
  commit_in "$W/lanes/ok" a.txt two "ticket ok again"
  out=$(done_gate ok) && fail "a commit after the proof voids it: $out"
  prove ok
  out=$(done_gate ok) || fail "proof at the new head must be accepted: $out"
  # The legacy local-only mode of a local-trunk project is held to the same proof; a PR mode is not subject to it.
  lane p2 v2 f2.txt; prove_part p2 receipt FAIL
  sed -i 's/^mode=local-trunk$/mode=local-only/' "$HOME_D/state/p2.meta"
  out=$(done_gate p2 local-only "done [at=1]: ready in branch fm/p2") && fail "a legacy local-only lane of a trunk project must be held to the proof: $out"
  pass 'the worker done and the landing both refuse, before starting, on any missing proof input, and accept only complete matching-head proof'
}

# When merge-card refuses a sealed run for a reason it names, the proof gap says that reason. It never says no run exists when a run
# does (the lane that cited a Designs capture was told "no sealed run" while its run was sealed and judged).
test_a_proof_gap_names_the_reason_merge_card_refused_not_a_missing_run() {
  local out card
  world gapreason
  lane r1 one
  trunk proof r1 >/dev/null 2>&1 || fail "the fixture lane must have complete proof before it is broken"
  card="$HOME_D/data/r1/merge-card.json"
  jq --arg home "$HOME_D/dd" '. + {context: {home: $home, account: "", project: "", config_hash: "0000000000000000000000000000000000000000"}}' "$card" > "$card.tmp" && mv "$card.tmp" "$card"
  out=$(trunk proof r1 2>&1) && fail "a refused sealed run must leave a proof gap: $out"
  assert_contains "$out" "was refused: proof configuration changed since the passed check" "the gap must name the reason merge-card gave"
  case $out in *"no sealed done-done run"*) fail "a refusal with a named reason must not be reported as a missing run: $out" ;; esac
  out=$(trunk land r1 2>&1) && fail "the landing must refuse the same lane: $out"
  assert_contains "$out" "was refused: proof configuration changed since the passed check" "the landing refusal must name the same reason"
  pass 'a refused sealed run is reported with merge-card'"'"'s own reason, not as a missing run'
}

# The model-judged merge-card is not a landing input: a lane whose card is absent, failed, stale, uncited or "not checked" (the judge
# errored or timed out) is done and lands on its receipt and its sealed run, while a missing seal or a failed receipt still refuses.
test_a_lane_lands_with_no_usable_merge_card_and_a_safety_refusal_still_blocks() {
  local variant out id=0
  world nojudge
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  for variant in absent failed stale uncited not-checked; do
    id=$((id + 1)); lane "n$id" "v$id" "n$id.txt"
    case $variant in
      absent) rm -f "$HOME_D/data/n$id/merge-card.json" ;;
      failed) sed -i 's/"verdict":"pass"/"verdict":"fail"/' "$HOME_D/data/n$id/merge-card.json" ;;
      stale) sed -i 's/"head":"[0-9a-f]*"/"head":"0000000000000000000000000000000000000000"/' "$HOME_D/data/n$id/merge-card.json" ;;
      uncited) sed -i 's/"evidence":\[[^]]*\]/"evidence":[]/' "$HOME_D/data/n$id/merge-card.json" ;;
      not-checked) printf '{"head":"%s","verdict":"not checked: the judge timed out"}\n' "$(git -C "$PROJ" rev-parse "fm/n$id")" > "$HOME_D/data/n$id/merge-card.json" ;;
    esac
    out=$(done_gate "n$id") || fail "a done with a $variant merge-card must be accepted: $out"
    trunk proof "n$id" >/dev/null 2>&1 || fail "the landing pre-check must accept a lane whose merge-card is $variant"
    out=$(trunk land "n$id" 2>&1) || fail "a lane whose merge-card is $variant must land: $out"
    git -C "$PROJ" cat-file -e "trunk:n$id.txt" || fail "the landed tip must hold the lane n$id (card $variant)"
  done
  # The safety refusals are untouched: no card does not stand in for a missing seal or a failed receipt.
  id=$((id + 1)); lane "n$id" "v$id" "n$id.txt"; rm -f "$HOME_D/data/n$id/merge-card.json" "$HOME_D/data/n$id/.done-done/runs/"*.json
  out=$(done_gate "n$id") && fail "a lane with no sealed run must not be done: $out"
  assert_contains "$out" "no sealed clean done-done run" "the missing seal is named"
  id=$((id + 1)); lane "n$id" "v$id" "n$id.txt"; prove_part "n$id" receipt FAIL
  out=$(done_gate "n$id") && fail "a lane with a failed receipt must not be done: $out"
  assert_contains "$out" "completion receipt" "the failed receipt is named"
  pass 'a lane lands with no usable merge-card, and a missing seal or a failed receipt still refuses'
}
test_a_lane_lands_with_no_usable_merge_card_and_a_safety_refusal_still_blocks

# The registered check starts no landing for an incomplete proof, says why once, and lands the same head once the proof is there.
test_the_check_starts_no_landing_until_the_whole_proof_is_there() {
  local out
  world gatecheck
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  lane g1 one; rm -f "$HOME_D/data/g1/.done-done/runs/"*.json
  out=$(sweep); assert_contains "$out" "g1 waits to land" "an incomplete proof must be reported by the check"
  assert_contains "$out" "no sealed clean done-done run" "the report names the missing input"
  [ -z "$(find "$HOME_D/data/jg-trunk-landing" -name 'g1.*.state' 2>/dev/null)" ] || fail "no landing may start for an incomplete proof"
  [ -z "$(sweep)" ] || fail "the wait must be reported once"
  [ "$(tip)" != "$(git -C "$PROJ" rev-parse fm/g1)" ] || fail "nothing may land without the proof"
  prove_part g1 seal
  sweep >/dev/null; out=$(sweep)
  [ "$(tip)" = "$(git -C "$PROJ" rev-parse fm/g1)" ] || fail "the same head must land once its proof is complete: $out"
  pass 'the landing check starts nothing until the whole proof is there, then lands the same head'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_three_lanes_land_in_order_a_red_one_is_refused_and_no_whole_suite_runs_per_landing() {
  local base rc out sha n
  world journey; rig; base=$(tip)
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  # The landing gate is the fast check (work.txt). The whole suite is red the way trunk-v3 was at 9f5bbb3af0d1: every script
  # passed and one shard ran over its wall-clock budget. A landing never runs it, so it never stops the next landing.
  printf '#!/usr/bin/env bash\necho run >> %s/suite-runs\necho "JG_TEST_AGGREGATE lanes=8 total=220 failed=0"\necho "jg-test-run: wall-clock budget exceeded: 606087ms > 600000ms" >&2\nexit 1\n' "$W" > "$W/suite-timeout.sh"
  printf 'gate-full=! grep -q BAD work.txt\ngate-verify=bash %s/suite-timeout.sh\n' "$W" >> "$HOME_D/config/trunk-policy"
  # Four lanes are ready at once, on the same old tip; the second one is red.
  lane j1 'exit 0' t/j1.test.sh; lane j2 BAD; lane j3 'exit 0' t/j3.test.sh; lane j4 'exit 0' t/j4.test.sh
  out=$(JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D") || fail "the check must not fail: $out"
  for _ in $(seq 1 150); do [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" -ge 3 ] && ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && break; sleep 0.2; done
  n=$(git -C "$PROJ" rev-list --count "$base..trunk")
  [ "$n" = 3 ] || fail "three lanes must land with no human step, got $n: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket j1,ticket j3,ticket j4" ] || fail "the lanes must land in the order they were done"
  for sha in $(git -C "$PROJ" rev-list "$base..trunk"); do [ "$(git -C "$PROJ" rev-list --parents -n 1 "$sha" | wc -w)" = 2 ] || fail "every landed commit must be one commit on the previous tip"; done
  [ "$(paste -sd, - < "$W/teardown-calls")" = "j1,j3,j4" ] || fail "each landed lane is cleaned up, unforced, in order, and the red one is kept: $(cat "$W/teardown-calls")"
  assert_contains "$(grep -c . "$HOME_D/data/trunk-landings.tsv")" 3 "three landings are logged"
  out=$(JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D")
  assert_contains "$out" "j2 not landed" "the red lane is refused and reported"
  assert_contains "$out" "gate 'full' failed" "the red lane's refusal names the failed check"
  [ -z "$(JG_HOME="$HOME_D" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D")" ] || fail "the refusal is reported once"
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 3 ] || fail "the red lane must not have moved the trunk"
  # A landing moves no pin and runs no suite: the tick's verify does, one at a time, and a suite over its time budget moves nothing.
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$base" ] || fail "a landing must not move the green pin"
  # So the next lane lands in minutes, on its changed files' tests alone, whatever the verify of the tip before it does.
  lane j5 'exit 0' t/j5.test.sh
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null
  for _ in $(seq 1 150); do git -C "$PROJ" log --format=%s trunk | grep -q "^ticket j5" && ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && break; sleep 0.2; done
  git -C "$PROJ" log --format=%s trunk | grep -q "^ticket j5" || fail "the next lane must land while the whole suite would be red: $(JG_HOME="$HOME_D" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D")"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$base" ] || fail "the next landing leaves the green pin too"
  [ ! -e "$W/live-moves" ] || fail "nothing here may go live"
  pass 'three lanes land in order with no human step, the red lane is refused, and a landing moves no pin and runs no suite, so a red suite stops no landing'
}

# A whole-suite run asked for by hand (verify) still finds the commit that broke the suite, and only reports it (pcp-s5): nothing is
# reverted, the green pin goes back below it, the lane's ticket and Overwatch are told, and the next lane still lands.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_red_verify_finds_by_hand_is_reported_and_takes_the_green_pin_back() {
  local rc out before c
  world handverify; rig
  printf 'gate-full=! grep -q BAD work.txt\ngate-verify=bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"
  lane j5 'echo "not ok - j5 breaks the suite" >&2; exit 1' t/j5.test.sh; before=$(tip)
  trunk land j5 >/dev/null 2>&1 || fail "j5 passes the fast check and lands"; c=$(tip)
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$before" ] || fail "the landing leaves the green pin"
  tip > "$HOME_D/state/trunk-green-proj"  # fixture: a verify that ran before j5 judged the trunk green at j5 (it is the red the next verify finds)
  rc=0; out=$(trunk verify "$PROJ" "$c" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify must fail on a commit that breaks the whole suite: $out"
  [ "$(tip)" = "$c" ] || fail "the verify reverts nothing: the trunk tip stays on the red commit: $out"
  git -C "$PROJ" log --format=%B trunk | grep -q '^reverts: ' && fail "no revert commit may exist"
  assert_contains "$out" "is red at ${c:0:12}" "the verify names the red commit"
  assert_contains "$out" "nothing was reverted and landings go on; live stays on the last green commit $(git -C "$PROJ" rev-parse --short=12 "$before")" "the verify says nothing was reverted and who owns the repair"
  assert_contains "$out" "j5 repairs it forward or reverts it on a lane of its own" "the repair owner is named"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$before" ] || fail "the red commit must take the green pin back below it, so no home goes live on it"
  assert_contains "$(cat "$W/backlog-calls" 2>/dev/null)" "update j5 --body-file" "the lane's ticket is told"
  assert_contains "$(cat "$HOME_D/state/.wake-queue")" "went red after it landed: " "Overwatch is told"
  assert_contains "$(cat "$HOME_D/data/trunk-ci.tsv")" "$c"$'\t' "the red stays recorded so no landing moves the pin over it"
  [ ! -e "$HOME_D/state/trunk-red-proj" ] || fail "a red never writes a red pin"
  lane k3 'exit 0' t/k3.test.sh; out=$(trunk land k3 2>&1) || fail "a reported red never stops the next landing: $out"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$before" ] || fail "a landing above a reported red leaves the green pin below it, so the red is never live"
  pass 'a red a hand-run verify finds is reported with its owner and not reverted, takes the green pin back, and stops no landing'
}

# The stall of 10 Nov: the green pin had not moved for 6 hours while 9 commits landed above it, because only the whole suite run
# after a landing moved it, and that run judged every change since the release base, so it grew with each landing. One more lane
# lands through the real landing check: its own gate is the trunk's green, so the pin is its head, and the check it ran judged its
# own changed scripts alone, the same count as the first landing after the release base.
# shellcheck disable=SC2016 # the gate bodies are written out verbatim and expand when the gate runs them
test_a_green_pin_left_behind_moves_to_the_next_landing_and_the_landing_check_does_not_grow() {
  local base i head row first ran old out
  world stalepin; rig; base=$(tip)
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  # The landing gate judges the changed scripts (as the fast required set does); verify judges every change since the release base.
  printf 'gate-full=bash %s/rig.sh $(git diff --name-only HEAD^ -- t)
gate-verify=echo run >> %s/suite-runs; bash %s/rig.sh $(git diff --name-only HEAD^ -- t)
' "$W" "$W" "$W" >> "$HOME_D/config/trunk-policy"
  [ "$(awk -F'\t' '$1 == "proj" { b = $4 } END { print b }' "$HOME_D/data/trunk-versions.tsv")" = "$base" ] || fail "the trunk version records its release base"
  lane s1 'exit 0' t/s1.test.sh; trunk land s1 >/dev/null 2>&1 || fail "s1 must land"
  rm -f -- "$HOME_D/state/s1.meta"
  first=$(grep -P '^s1\t' "$HOME_D/data/trunk-landing-proofs.tsv" | tail -n 1)
  [[ $first =~ gate=ran:1, ]] || fail "the first landing after the release base runs its one changed script: $first"
  # Build the eight intervening real landings in two stacks; only the first and next landing's gate counts are compared here.
  for i in 2 3 4 5; do lane "s$i" 'exit 0' "t/s$i.test.sh"; done
  trunk land-batch s2 s3 s4 s5 >/dev/null 2>&1 || fail "s2 through s5 must land"
  for i in 2 3 4 5; do rm -f -- "$HOME_D/state/s$i.meta"; done
  for i in 6 7 8 9; do lane "s$i" 'exit 0' "t/s$i.test.sh"; done
  trunk land-batch s6 s7 s8 s9 >/dev/null 2>&1 || fail "s6 through s9 must land"
  for i in 6 7 8 9; do rm -f -- "$HOME_D/state/s$i.meta"; done
  # As on 10 Nov: the pin is still at the release base, 6 hours old, with 9 landings above it.
  old=$(( $(date +%s) - 6 * 3600 ))
  printf '%s\n' "$base" > "$HOME_D/state/trunk-green-proj"; touch -d "@$old" "$HOME_D/state/trunk-green-proj"
  awk -F'\t' -v OFS='\t' -v t="$old" '{ $4 = t } 1' "$HOME_D/data/trunk-landings.tsv" > "$W/landings" && cat "$W/landings" > "$HOME_D/data/trunk-landings.tsv"
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 9 ] || fail "9 commits sit above the green pin"
  lane s10 'exit 0' t/s10.test.sh
  out=$(sweep)
  head=$(tip)
  [ "$(git -C "$PROJ" log -1 --format=%s "$head")" = "ticket s10" ] || fail "the next lane lands: $out $(cat "$HOME_D"/data/jg-trunk-landing/s10.*.log 2>&1)"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" != "$head" ] || fail "the landing itself must not move the green pin"
  # The tick's verify moves it, over every change since the pin, and the landing check does not grow with them.
  for _ in $(seq 1 150); do [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$head" ] && break; sweep >/dev/null; sleep 0.3; done
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$head" ] || fail "the tick's verify must move the green pin to the tip, not $(cut -c1-12 "$HOME_D/state/trunk-green-proj")"
  row=$(grep -P '^s10\t' "$HOME_D/data/trunk-landing-proofs.tsv" | tail -n 1)
  ran=${row##*gate=ran:}; ran=${ran%%,*}
  [ "$ran" = 1 ] || fail "the landing's check must judge its own changed script alone, not the $(( $(git -C "$PROJ" rev-list --count "$base..trunk") )) landings since the release base: $row"
  [ -e "$W/suite-runs" ] || fail "the verify, not the landing, ran the suite"
  ! compgen -G "$HOME_D/data/jg-trunk-landing/s10.*.verify.log" >/dev/null || fail "the landing writes no verify log"
  pass 'a green pin left 6 hours behind 9 landings moves to the next landing'"'"'s head, and the landing'"'"'s check does not grow with the landings since the release base'
}

# shellcheck disable=SC2016 # the policy line is written out verbatim and expands when the gate runs it
test_a_lane_proved_at_the_change_the_lander_lands_is_not_tested_again() {
  local out
  world once; local JG_TRUNK_SEALED_REUSE=1
  # The tests leave a mark each time the gate runs them; the lint still runs on every landing.
  printf 'gate-full=echo ran >> %s/gate-runs; ! grep -q BAD work.txt\ngate-lint=echo linted >> %s/lint-runs; ! grep -q UGLY work.txt\nlanding-gate=tests\n' "$W" "$W" > "$HOME_D/config/trunk-policy"
  lane s1 one a.txt; lane s2 two b.txt
  # The trunk has not moved since s1 was proved and sealed: its sealed run is for the tree the lander would test.
  out=$(trunk land s1 2>&1) || fail "a lane proved at the tip's tree must land: $out"
  [ ! -e "$W/gate-runs" ] || fail "the tests must not run again for a tree the sealed run already passed"
  [ "$(grep -c . "$W/lint-runs")" = 1 ] || fail "the lint must still run for the landing"
  assert_contains "$out" "gate=sealed-run" "the landing must say the sealed run stood for the tests"
  # The trunk moved under s2: the lander rebases it onto a tree its run never saw, but the rebase leaves the patch as it was, so the run stands.
  out=$(trunk land s2 2>&1) || fail "a lane on a moved trunk must land: $out"
  [ ! -e "$W/gate-runs" ] || fail "the tests must not run for a rebase with the same change"
  assert_contains "$out" "gate=sealed-run" "a rebase with the same change keeps the sealed run"
  pass 'a lane whose sealed run is for the change the lander lands lands on the lint alone, also after a rebase with no change'
}

# A landing records the lane's done epoch and writes no latency file: its timing is measured from the records for the ticket's land event.
test_every_landing_records_the_done_epoch_and_writes_no_latency_row() {
  local out done_at commit payload
  world latency
  lane lat1 one a.txt
  done_at=$(sed -n 's/^done \[at=\([0-9]*\)\].*/\1/p' "$HOME_D/state/lat1.status" | tail -n 1)
  out=$(trunk land lat1 2>&1) || fail "the lane must land: $out"
  rm -f "$HOME_D/state/lat1.status"   # cleanup removes the status file; no chat line exists in this home
  assert_contains "$(tail -n 1 "$HOME_D/data/trunk-landing-proofs.tsv")" "done=$done_at" "the landing must record the lane's done epoch"
  [ ! -e "$HOME_D/data/trunk-latency.tsv" ] || fail "a landing must write no data/trunk-latency.tsv: $(cat "$HOME_D/data/trunk-latency.tsv")"
  commit=$(awk -F'\t' '$1 == "lat1" { print $3 }' "$HOME_D/data/trunk-landings.tsv")
  payload=$(bash "$ROOT/core/trunk-latency/latency.sh" measure "$HOME_D" lat1 "$commit") || fail "the timing of the landing must be measurable: $payload"
  [ "$(jq -r .ready <<< "$payload")" = "$done_at" ] || fail "the timing must carry the recorded done epoch $done_at: $payload"
  pass 'a landing records the lane done epoch, measures its timing from it, and writes no latency file'
}

# The real landing check bounds lint and tests by one shared deadline, and a timeout is retried rather than blamed on the lane.
test_landing_deadline_spans_both_gates() {
  local head before state
  world deadline
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  printf 'gate-lint=sleep 2\ngate-full=sleep 2\nlanding-gate=tests\nflush-at-ready=1\n' > "$HOME_D/config/trunk-policy"
  lane limit one work.txt
  before=$(tip); head=$(git -C "$PROJ" rev-parse fm/limit)
  JG_TEST_SEAM=1 JG_TRUNK_TEST_GATE_SECONDS=3 JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" \
    bash "$ROOT/core/trunk-landing/trunk-landing.sh" run "$HOME_D" limit "$head" >/dev/null
  state=$(cat "$HOME_D/data/jg-trunk-landing/limit.$head.state")
  [ "$(tip)" = "$before" ] || fail "a landing that exceeds the shared deadline must not move the trunk"
  assert_contains "$state" 'deadline' "the check must report the deadline"
  [[ $state = "retry 1 "* ]] || fail "a timeout must retry rather than blame the lane: $state"
  pass 'the landing check bounds lint and tests by one shared deadline'
}

# pcp-s7: no generic design or owner proof gate. A routine lane, a design-call lane with no first-draft receipt line and a lane that adds a
# large UI change with no hand-roll approval all land with no design or model ceremony. The boundaries that stay refuse by their own reason:
# an open linked decision, and the owner-guard (private owner details in the added lines).
test_a_routine_lane_lands_with_no_design_or_owner_gate_and_a_decision_or_credential_still_refuses() {
  local out ui
  world nodesign
  lane rt1 routine r.txt
  out=$(trunk land rt1 2>&1) || fail "a routine lane must land with no design or model ceremony: $out"
  git -C "$PROJ" cat-file -e "trunk:r.txt" || fail "the routine lane's file must be on the tip"
  # A design-call lane whose receipt has no first-draft line lands: no receipt line is a condition of landing.
  lane dz1 design d.txt; printf 'design_call=yes\n' >> "$HOME_D/state/dz1.meta"
  out=$(trunk land dz1 2>&1) || fail "a design-call lane with no first-draft line must land: $out"
  git -C "$PROJ" cat-file -e "trunk:d.txt" || fail "the design-call lane's file must be on the tip"
  # A 60-line UI change with no hand-roll approval lands: there is no size rule.
  ui=$(seq 1 60 | sed 's/^/a { order: /; s/$/; }/')
  lane ui1 "$ui" page.css; printf 'design_call=no\nbase_branch=trunk\n' >> "$HOME_D/state/ui1.meta"
  out=$(trunk land ui1 2>&1) || fail "a large UI lane with no hand-roll approval must land: $out"
  assert_not_contains "$out" "first-draft" "a landing must not name a first-draft receipt"
  assert_not_contains "$out" "hand-roll" "a landing must not name a hand-roll approval"
  # An open linked decision still refuses, by its own reason.
  : > "$HOME_D/state/linked-open"
  lane od1 other o.txt
  refused 'a lane linked to an open decision' od1 'linked to a decision still open'
  rm -f "$HOME_D/state/linked-open"
  out=$(trunk land od1 2>&1) || fail "the lane must land once the decision is answered: $out"
  # A credential (the owner's private details) in the added lines still refuses, by its own reason, and the trunk stays put.
  printf '%s\n' 'testguard-fake-surname' > "$HOME_D/config/owner-details-patterns"
  lane cr1 'contact testguard-fake-surname here' c.txt
  refused 'a lane that adds the owner details' cr1 'owner-guard refused'
  pass 'a routine, design-call and large UI lane land with no design or owner gate; an open decision and an owner-details leak still refuse with their reasons'
}

# jg8-nav-gate-local-lane: a local lane has no PR body, so the nav gate reads its commit message, then its receipt evidence or done line.
test_a_ui_lane_states_its_nav_lines_in_the_commit_message_the_receipt_or_the_done_line() {
  local out id h
  world nav
  # No lines anywhere: refused, and the refusal names the commit message, never a PR body.
  lane nv1 ui a.txt; printf 'ui_change=yes\n' >> "$HOME_D/state/nv1.meta"
  refused 'a ui lane with no nav lines' nv1 "its commit message has no 'Nav before"
  assert_not_contains "$(trunk land nv1 2>&1 || true)" "PR body" "a local landing must not name a PR body"
  # The lines in the commit message: lands.
  lane nv2 ui b.txt $'Nav before: Home, Inbox\nNav after: Home, Inbox, Reports'; printf 'ui_change=yes\n' >> "$HOME_D/state/nv2.meta"
  out=$(trunk land nv2 2>&1) || fail "a ui lane with the lines in its commit message must land: $out"
  # The lines only in the completion receipt evidence: lands.
  lane nv3 ui c.txt; printf 'ui_change=yes\n' >> "$HOME_D/state/nv3.meta"
  h=$(git -C "$PROJ" rev-parse "fm/nv3")
  jq -n --arg t nv3 --arg h "$h" --arg e $'done-done run: ok\nNav before: Home\nNav after: Home, Reports' \
    '{schema:1,task:$t,mode:"local-trunk",spawn_gen:("g-"+$t),head:$h,pr:"",verdict:"PASS",at:1,evidence:$e}' > "$HOME_D/state/nv3.run-receipt.json"
  out=$(trunk land nv3 2>&1) || fail "a ui lane with the lines in its receipt must land: $out"
  # The lines only in the done line: lands.
  lane nv4 ui d.txt; printf 'ui_change=yes\n' >> "$HOME_D/state/nv4.meta"
  printf 'done [at=2000]: ready in branch fm/nv4 (local-trunk) Nav before: Home | Nav after: Home, Reports\n' >> "$HOME_D/state/nv4.status"
  out=$(trunk land nv4 2>&1) || fail "a ui lane with the lines in its done line must land: $out"
  # A dropped item is still refused on a local landing, from whichever place the lines come.
  lane nv5 ui e.txt $'Nav before: Home, Inbox\nNav after: Home'; printf 'ui_change=yes\n' >> "$HOME_D/state/nv5.meta"
  refused 'a ui lane that drops a nav item' nv5 "its commit message drops from Nav before (inbox)"
  pass 'a local ui lane names the commit message in the refusal and lands on its lines in the commit message, the receipt or the done line'
}

# A local lane lands with no tests at the landing (landing-gate=none, the default): the lint is the only check, the batch's verify is
# the one test run, and a red it finds is reported. landing-gate=tests is the rollback: the changed files' tests run at the landing again.
test_a_local_lane_lands_with_no_tests_and_the_verify_reports_a_red() {
  local rc out c before
  world nogate; rig
  printf 'gate-full=bash %s/rig.sh t/n1.test.sh\ngate-verify=bash %s/rig.sh --all\n' "$W" "$W" > "$HOME_D/config/trunk-policy"  # no landing-gate line: the default
  [ "$(pol landing-gate)" = none ] || fail "the landing runs no tests by default"
  lane n1 'echo "not ok - n1 breaks the suite" >&2; exit 1' t/n1.test.sh; before=$(tip)
  out=$(trunk land n1 2>&1) || fail "a lane whose test fails must land when no tests run at the landing: $out"
  assert_contains "$out" "gate=no-landing-gate" "the landing records that no test ran"
  [ "$(tip)" != "$before" ] || fail "the lane must be on the trunk"
  c=$(tip); printf '%s\n' "$before" > "$HOME_D/state/trunk-green-proj"
  rc=0; out=$(trunk verify "$PROJ" "$c" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the verify must find the red: $out"
  [ "$(tip)" = "$c" ] || fail "the verify reverts nothing: $out"
  assert_contains "$out" "is red at ${c:0:12}" "the verify names the commit that caused the red"
  # The rollback key puts the changed-tests gate back at the landing.
  printf 'landing-gate=tests\n' >> "$HOME_D/config/trunk-policy"
  lane n2 'echo "not ok - n2 breaks it another way" >&2; exit 1' t/n1.test.sh
  refused 'a landing with landing-gate=tests' n2 'gate'
  pass 'a local lane lands with no tests at the landing, the verify reports its red, and landing-gate=tests is the rollback'
}

# A required script that failed and then only skipped on its rerun was never shown to pass (verify-skip-not-pass): the verify stays
# incomplete, the green pin stays put, nothing is charged or reverted, and the report names the script. A script that really passes on
# its rerun still goes green.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_script_that_skips_on_its_rerun_is_incomplete_never_green() {
  local rc out before c
  world skiprerun; rig
  printf 'gate-full=! grep -q BAD work.txt\ngate-verify=bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"
  # Runs 1, 3, ... fail; runs 2, 4, ... (the rerun of each verify attempt) only skip, as the stuck run's capability-skipped scripts did.
  lane s1 'n=$(cat '"$W"'/s-runs 2>/dev/null || echo 0); n=$((n + 1)); echo $n > '"$W"'/s-runs; [ $((n % 2)) -eq 0 ] || { echo "not ok - needs the tool" >&2; exit 1; }; echo "skip: the tool is not installed"; exit 0' t/s.test.sh
  before=$(tip)
  trunk land s1 >/dev/null 2>&1 || fail "s1 passes the fast check and lands"; c=$(tip)
  printf '%s\n' "$before" > "$HOME_D/state/trunk-green-proj"
  rc=0; out=$(trunk verify "$PROJ" "$c" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a script that only skipped on its rerun must not make the verify green: $out"
  assert_contains "$out" "is incomplete: these required scripts failed, then skipped on their rerun" "the report says the verify is incomplete"
  assert_contains "$out" "t/s.test.sh" "the report names the skipped script"
  assert_not_contains "$out" "trunk green at" "a skipped script is never a pass"
  assert_not_contains "$out" "judged flaky" "a skipped script is not flaky"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$before" ] || fail "an incomplete verify leaves the green pin where it was"
  [ "$(tip)" = "$c" ] || fail "an incomplete verify reverts nothing"
  [ ! -e "$HOME_D/data/trunk/flaky-proj.tsv" ] || ! grep -q 't/s.test.sh' "$HOME_D/data/trunk/flaky-proj.tsv" || fail "a skipped script is never recorded as flaky"
  ! grep -q 'went red after it landed' "$HOME_D/state/.wake-queue" 2>/dev/null || fail "an incomplete verify charges nobody"
  # The control, in a world of its own: a script that really passes on its rerun is flaky, and the verify goes green and moves the pin.
  world passrerun; rig
  printf 'gate-full=! grep -q BAD work.txt\ngate-verify=bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"
  lane p1 'n=$(cat '"$W"'/p-runs 2>/dev/null || echo 0); n=$((n + 1)); echo $n > '"$W"'/p-runs; [ $((n % 2)) -eq 0 ] || { echo "not ok - flaky" >&2; exit 1; }; exit 0' t/p.test.sh
  before=$(tip)
  trunk land p1 >/dev/null 2>&1 || fail "p1 passes the fast check and lands"; c=$(tip)
  printf '%s\n' "$before" > "$HOME_D/state/trunk-green-proj"
  rc=0; out=$(trunk verify "$PROJ" "$c" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a script that passes on its rerun still goes green: $out"
  assert_contains "$out" "judged flaky" "the real pass is set aside as flaky"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c" ] || fail "a real pass moves the green pin"
  pass 'a required script that failed and then only skipped on its rerun leaves the verify incomplete and names it, while a real pass on the rerun still goes green'
}

test_landing_deadline_spans_both_gates
test_every_verify_attempt_keeps_its_own_log_and_phase_history
test_a_changed_file_that_is_not_a_test_is_never_run_bare_on_the_tip
test_an_unmapped_path_is_a_coverage_note_and_a_real_failure_still_reruns_once
test_the_gate_rerun_never_runs_a_data_file_as_a_command
test_the_full_gate_charges_a_lane_only_for_what_it_broke
test_every_landing_records_the_done_epoch_and_writes_no_latency_row
test_a_flaky_failure_gets_one_rerun_before_it_is_judged
test_a_lane_is_charged_only_for_a_script_the_parent_passes_three_times_of_three
test_a_tip_red_that_prints_its_elapsed_seconds_is_the_same_red_on_every_run
test_the_gates_are_policy_keys_with_fast_defaults
test_a_project_that_is_not_juggernaut_never_runs_juggernauts_gates
test_a_landing_rebases_the_lane_by_itself
test_done_and_landing_both_refuse_before_starting_on_any_missing_proof_input
test_a_proof_gap_names_the_reason_merge_card_refused_not_a_missing_run
test_the_check_starts_no_landing_until_the_whole_proof_is_there
test_three_lanes_land_in_order_a_red_one_is_refused_and_no_whole_suite_runs_per_landing
test_a_red_verify_finds_by_hand_is_reported_and_takes_the_green_pin_back
test_a_script_that_skips_on_its_rerun_is_incomplete_never_green
test_a_green_pin_left_behind_moves_to_the_next_landing_and_the_landing_check_does_not_grow
test_a_lane_proved_at_the_change_the_lander_lands_is_not_tested_again
test_a_routine_lane_lands_with_no_design_or_owner_gate_and_a_decision_or_credential_still_refuses
test_a_ui_lane_states_its_nav_lines_in_the_commit_message_the_receipt_or_the_done_line
test_a_local_lane_lands_with_no_tests_and_the_verify_reports_a_red
printf 'jg-trunk-gate: ok\n'
