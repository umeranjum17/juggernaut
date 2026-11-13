#!/usr/bin/env bash
# Integration test for parallel landing batches (slice H29, core/trunk-landing/batch.sh), through the real bin/jg-trunk.sh verify and
# the shared fixture tests/jg-trunk-fixture.sh: real git repositories and the real gate chain.
# Many lanes land past a quick gate and sit above the green pin. The line's verify then:
# B1 a green stack under N commits is one milestone run (core/trunk-verify/milestone.sh) and moves the pin to the tip.
# B2 on a red, splits the red milestone in two halves that run at once, reverts only the commit that added the red, keeps every other
#    lane, and moves the pin to the last commit before the red.
# B4 with one heavy slot (core/lane-scale/fleet.sh) the runs wait for it one by one: same result, never two at once.
# B5 a stack of 16 commits (milestones of 13 and 3) is traced to one commit in few runs, counted in runs, not seconds.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

tip_after_land() { trunk land "$1" >/dev/null 2>&1 || fail "$1 must land"; tip; }

# A gate that logs when each run starts and ends, takes a moment, and runs the stand-in test runner over the tree.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
par_gate() {
  cat > "$W/par.sh" <<SH
#!/usr/bin/env bash
echo "s \$\$" >> $W/par.log; sleep 0.5
bash $W/rig.sh --all; rc=\$?
echo "e \$\$" >> $W/par.log; exit \$rc
SH
  printf 'gate-full=true\ngate-verify=bash %s/par.sh\n' "$W" >> "$HOME_D/config/trunk-policy"
}
runs() { grep -c '^s ' "$W/par.log" 2>/dev/null || echo 0; }
maxat() { awk '$1 == "s" { n++; if (n > m) m = n } $1 == "e" { n-- } END { print m + 0 }' "$W/par.log" 2>/dev/null || echo 0; }

# stack <name> <lanes> <bad-index> [<width>]: a world with <lanes> landed lanes above the pin, lane <bad-index> adding a failing test.
stack() {
  local i body
  world "$1"; rig; par_gate
  [ -z "${4:-}" ] || printf 'verify-width=%s\n' "$4" >> "$HOME_D/config/trunk-policy"
  lane base 'exit 0' t/base.test.sh; tip_after_land base >/dev/null; tip > "$HOME_D/state/trunk-green-proj"
  BAD=
  for i in $(seq 1 "$2"); do
    body='exit 0'; [ "$i" != "${3:-0}" ] || body='echo "not ok - bad lane" >&2; exit 1'
    lane "l$i" "$body" "t/l$i.test.sh"; tip_after_land "l$i" >/dev/null
    [ "$i" != "${3:-0}" ] || BAD=$(tip)
  done
  : > "$W/par.log"
}

reverted() { git -C "$PROJ" log --format=%B trunk | grep -x "reverts: .*" | sed 's/^reverts: //'; }

test_batches_test_at_once_and_a_green_stack_moves_the_pin_to_the_tip() {
  local out
  stack green 8 0
  out=$(trunk verify "$PROJ" 2>&1) || fail "a green stack must verify: $out"
  assert_contains "$out" "milestone of 8 commits" "a stack under N commits is one milestone"
  [ "$(runs)" = 1 ] || fail "one milestone is one run: $(runs)"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] || fail "a green milestone must move the pin to the tip"
  pass 'a green stack of 8 is one milestone run and moves the pin to the tip'
}

test_a_red_batch_is_searched_in_parallel_and_only_its_commit_goes_back() {
  local out
  stack red 8 5
  out=$(trunk verify "$PROJ" 2>&1) && fail "a stack with a red must not verify green: $out"
  [ "$(reverted)" = "$BAD" ] || fail "only the bad commit ${BAD:0:12} may be reverted, got: $(reverted)"
  [ "$(reverted | wc -l)" = 1 ] || fail "exactly one commit goes back"
  assert_contains "$out" "its two halves" "the red milestone is split in two halves"
  [ "$(maxat)" -ge 2 ] || fail "the halves must run at once, at most $(maxat) overlapped"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(git -C "$PROJ" rev-parse "$BAD^")" ] || fail "a red verify moves the pin to the last commit before the bad one"
  git -C "$PROJ" ls-tree -r --name-only trunk | grep -q 't/l6.test.sh' || fail "the lanes after the bad one stay on the trunk"
  pass 'a red batch is searched with probes at once; only the commit that added the red is reverted, every other lane stays'
}

test_one_heavy_slot_keeps_the_runs_one_after_another() {
  local out
  stack slot 6 3; printf 'heavy_slots=1\n' >> "$HOME_D/config/lane-scale"
  out=$(trunk verify "$PROJ" 2>&1) && fail "must be red: $out"
  [ "$(reverted)" = "$BAD" ] || fail "the same commit is reverted with one slot, got: $(reverted)"
  [ "$(maxat)" = 1 ] || fail "one heavy slot lets one run at a time: $(maxat)"
  [ -z "$(ls "$HOME_D/state/heavy-slots" 2>/dev/null)" ] || fail "every slot is given back: $(ls "$HOME_D/state/heavy-slots")"
  pass 'with one heavy slot the batches wait their turn, give the slot back, and find the same commit'
}

test_a_stack_of_sixteen_commits_is_traced_in_few_rounds() {
  local out
  stack many 16 11
  out=$(trunk verify "$PROJ" 2>&1) && fail "must be red: $out"
  [ "$(reverted)" = "$BAD" ] || fail "the bad commit of 16 is found, got: $(reverted)"
  # milestones of 13 and 3: one run for the first, two halves a round (log2 13 rounds), one run for the second
  [ "$(runs)" -le 12 ] || fail "a stack of 16 must cost at most 12 gate runs, ran $(runs)"
  pass "a stack of 16 commits is traced to the one bad commit in $(runs) runs, two at once"
}

test_batches_test_at_once_and_a_green_stack_moves_the_pin_to_the_tip
test_a_red_batch_is_searched_in_parallel_and_only_its_commit_goes_back
test_one_heavy_slot_keeps_the_runs_one_after_another
test_a_stack_of_sixteen_commits_is_traced_in_few_rounds
if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
  cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<'JSON'
{
  "target": {"version": "bin/jg-trunk.sh verify"},
  "start": "a trunk with landed lanes above the green pin, one of them adding a failing test",
  "steps": [
    "the line's verify judges the stack by milestone",
    "a red milestone is split in two halves that run at once",
    "the commit that added the red is reverted and every other lane stays",
    "one heavy slot keeps the runs one after another and finds the same commit"
  ],
  "result": "all green moves the green pin to the tip; a red reverts only its bad commit and leaves the pin below it; a stack of 16 is traced in at most 12 gate runs"
}
JSON
fi
printf 'jg-trunk-parallel-batch: ok\n'
