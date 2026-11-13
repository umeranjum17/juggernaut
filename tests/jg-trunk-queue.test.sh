#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: the merge queue (tests/jg-trunk-fixture.sh).
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh, reads bin/jg-dod-lib.sh and stands in for bin/jg-captain-hold.sh,
# bin/jg-backlog.sh, bin/jg-send.sh, bin/jg-teardown.sh, bin/jg-fleet-ledger.sh and bin/jg-home-health.sh.
#
# T14 The merge queue: 2 or more queued lanes land as ONE stack (auto-rebased in order, one gate over the union of their changed
#    files judged against the tip, one trunk move, one trunk-landings.tsv row per lane); a lane that conflicts drops out and is told; a red
#    stack is halved until only the guilty lane is returned and the green part lands; the stack's landing moves the green pin to its top; a
#    red a hand-run verify finds after a batch landing is traced to its one commit, reverted, and takes the pin back; a single queued lane keeps the single path.
# T15 The queue's threshold: the landing check holds ready lanes until flush-at-ready are ready or the oldest has waited
#    flush-after-minutes, then lands them all as one stack; `flush <project>` lands every ready lane at once; a lane marked
#    `land-next` lands at once, ahead of the queue, while the others keep waiting; a worker marks neither.
# The done-done journey journeys/trunk-landing.sh runs this file and seals its output.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# shellcheck disable=SC2016 # the gate bodies are written out verbatim and expand when the gate runs them
batch_world() {  # <name>: a world whose fast gate counts its runs and records the files it was asked to judge
  world "$1"
  printf 'gate-full=echo run >> "%s/gate-runs"; git diff --name-only HEAD^ >> "%s/gate-files"; ! git grep -q BAD\ngate-lint=! git grep -q UGLY\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
}

runs() { [ -f "$W/gate-runs" ] && grep -c . "$W/gate-runs" || echo 0; }

# fresh <id> <minutes>: the lane's done report is this many minutes old.
fresh() { printf 'done [at=%s]: ready in branch fm/%s (local-trunk)\n' "$(( $(date +%s) - $2 * 60 ))" "$1" >> "$HOME_D/state/$1.status"; }

qsweep() { JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" 2>&1; }

# settled <n>: the trunk holds <n> commits over <base> and no landing is running. A finished landing
# chains `next` (core/trunk-landing/trunk-landing.sh) from its own detached job after it records `landed`, and that sweep reads
# the queue as it is at that moment; the case must not build its next lanes under it, so settled also waits for every job the
# check started to end.
settled() {
  local _
  for _ in $(seq 1 150); do
    [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = "$1" ] && ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && [ -z "$(jg_test_detached_alive)" ] && return 0
    sleep 0.2
  done
  fail "the trunk must hold $1 landed lanes and a settled suite: $(git -C "$PROJ" log --format=%s "$base..trunk" | paste -sd, -)"
}

unlanded() { [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = "$1" ] || fail "$2: $(git -C "$PROJ" log --format=%s "$base..trunk" | paste -sd, -)"; }

test_queued_lanes_land_as_one_stack_and_a_red_stack_is_bisected() {
  local base out rc=0 i
  batch_world batch; rig; base=$(tip)
  printf 'gate-full=echo run >> "%s/gate-runs"; git diff --name-only HEAD^ >> "%s/gate-files"; ! git grep -q BAD\ngate-verify=bash %s/rig.sh --all\n' "$W" "$W" "$W" >> "$HOME_D/config/trunk-policy"
  # A clean stack: three lanes on the same old tip land in order, behind ONE gate over all their files, in ONE trunk move.
  lane b1 'exit 0' t/b1.test.sh; lane b2 'echo "not ok - b2 breaks the suite" >&2; exit 1' t/b2.test.sh; lane b3 'exit 0' t/b3.test.sh
  out=$(trunk land-batch b1 b2 b3 2>&1) || fail "a clean stack must land: $out"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket b1,ticket b2,ticket b3" ] || fail "the stack lands in the order given"
  [ "$(runs)" = 1 ] || fail "one gate must judge the whole stack, got $(runs) runs"
  [ "$(sort -u "$W/gate-files" | paste -sd, -)" = "t/b1.test.sh,t/b2.test.sh,t/b3.test.sh" ] || fail "the gate judges the union of the changed files: $(cat "$W/gate-files")"
  [ "$(grep -c '^landed b' <<<"$out")" = 3 ] || fail "every lane reports its landing: $out"
  [ "$(awk -F'\t' -v b="$base" '$6 == "batch-from=" b' "$HOME_D/data/trunk-landings.tsv" | wc -l | tr -d ' ')" = 3 ] || fail "one landings row per lane: $(cat "$HOME_D/data/trunk-landings.tsv")"
  [ "$(git -C "$PROJ" rev-parse fm/b3)" = "$(tip)" ] && [ -z "$(git -C "$W/lanes/b3" status --porcelain)" ] || fail "each lane follows its rebased commit"
  [ "$(grep -c '^merged' "$W/ledger-calls")" = 3 ] || fail "each lane records the same merged event: $(cat "$W/ledger-calls")"
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$(tip)" ] || fail "the tip record follows the one move"
  # The same stack also proves that a later whole-suite failure reverts only its guilty commit.
  local top; top=$(tip); rc=0
  out=$(trunk verify "$PROJ" "$top" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the whole suite is red after this stack: $out"
  git -C "$PROJ" log -1 --format=%s trunk | grep -q '^Revert "ticket b2"' || fail "the guilty lane is reverted"
  ! git -C "$PROJ" cat-file -e trunk:t/b2.test.sh 2>/dev/null || fail "the red lane is undone"
  git -C "$PROJ" cat-file -e trunk:t/b1.test.sh || fail "the first green lane stays on trunk"
  git -C "$PROJ" cat-file -e trunk:t/b3.test.sh || fail "the last green lane stays on trunk"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(git -C "$PROJ" log -1 --format=%H --grep='^ticket b1$' trunk)" ] || fail "the pin stands on the last commit before the guilty one (b1): a landing never moved it and the verify moves it only that far"
  assert_contains "$out" "b2" "the revert names the lane"
  # A lane that conflicts drops out and is told, with its paths; the rest still land as one stack.
  : > "$W/gate-runs"; base=$(tip)
  lane c1 left; lane c2 right; lane c3 three f4.txt
  out=$(trunk land-batch c1 c2 c3 2>&1) || fail "a stack with one conflicting lane must still land the others: $out"
  assert_contains "$out" "returned c2: REFUSED: fm/c2 conflicts with trunk" "the conflicting lane is returned"
  assert_contains "$out" "work.txt" "the conflict names its paths"
  assert_contains "$out" "refusal-class c2: final" "a conflict is final"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket c1,ticket c3" ] || fail "the others land in order"
  [ "$(runs)" = 1 ] || fail "the conflict costs no extra gate run, got $(runs)"
  # A red stack is halved: the guilty lane alone is returned, the green part lands, and only the needed runs are spent.
  : > "$W/gate-runs"; base=$(tip)
  lane d1 one g1.txt; lane d2 two g2.txt; lane d3 BAD g3.txt; lane d4 four g4.txt
  out=$(trunk land-batch d1 d2 d3 d4 2>&1) || fail "a red stack must still land its green part: $out"
  assert_contains "$out" "returned d3: REFUSED: this lane is the red in its batch" "only the guilty lane is returned"
  assert_contains "$out" "refusal-class d3: final" "a red the lane caused is final"
  case $out in *"returned d1"*|*"returned d2"*|*"returned d4"*) fail "a green lane must not be returned: $out" ;; esac
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket d1,ticket d2,ticket d4" ] || fail "the green part lands in order"
  [ "$(runs)" = 4 ] || fail "four lanes with one red take 4 gate runs (stack, first half, guilty, last lane), got $(runs)"
  [ "$(git -C "$PROJ" rev-parse fm/d3)" = "$(git -C "$W/lanes/d3" rev-parse HEAD)" ] || fail "the returned lane is left exactly as it was"
  ! git -C "$PROJ" cat-file -e trunk:g3.txt 2>/dev/null || fail "the red lane's change is not on the trunk"
  # The same red on a full temp directory is the machine's: the returned lane is classed retry, not final.
  printf 'gate-full=echo "cat: write error: Disk quota exceeded"; ! git grep -q BAD\n' >> "$HOME_D/config/trunk-policy"
  lane q1 one h1.txt
  out=$(trunk land-batch q1 d3 2>&1) || fail "a red stack must still land its green part: $out"
  assert_contains "$out" "refusal-class d3: retry" "a red the machine caused is classed retry"
  # One queued lane keeps the single path, and the batch refuses what a single landing refuses.
  rc=0; out=$(trunk land-batch lonely 2>&1) || rc=$?; [ "$rc" -ne 0 ] || fail "a batch of one is refused: $out"
  assert_contains "$out" "2 or more" "a lone lane is told to use land"
  for i in --force -f; do out=$(trunk land-batch d3 d4 "$i" 2>&1) && fail "a batch is never forced"; done
  pass 'queued lanes land as one stack: one gate, one move, a conflict drops out, a red stack is halved to the guilty lane'
}

# shellcheck disable=SC2016 # the gate bodies are written out verbatim and expand when the gate runs them
test_the_landing_check_stacks_ready_lanes_and_keeps_a_single_lane_on_its_own_path() {
  local base out n again
  batch_world watcherbatch; base=$(tip)
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane w1 one f1.txt; lane w2 left; lane w3 right; lane w4 four f4.txt
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null
  for _ in $(seq 1 150); do [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" -ge 3 ] && ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && break; sleep 0.2; done
  n=$(git -C "$PROJ" rev-list --count "$base..trunk")
  [ "$n" = 3 ] || fail "three of four ready lanes land, got $n: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket w1,ticket w2,ticket w4" ] || fail "they land in the order they were done"
  [ "$(runs)" = 1 ] || fail "the ready lanes were judged by one gate, got $(runs) runs"
  [ "$(paste -sd, - < "$W/teardown-calls")" = "w1,w2,w4" ] || fail "each landed lane is cleaned up, unforced, in order: $(cat "$W/teardown-calls")"
  out=$(JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D")
  assert_contains "$out" "w3 not landed" "the conflicting lane is reported"
  assert_contains "$out" "work.txt" "its report names the conflicting path"
  # A landing's own outbox line can still be in flight (its state is written first), so only a repeated refusal counts.
  again=$(JG_HOME="$HOME_D" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D")
  [ -z "$again" ] || ! grep -qv ': landed ' <<<"$again" || fail "the refusal is reported once: $again"
  for _ in $(seq 1 150); do [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] && break; sleep 0.2; done
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] || fail "the tick's verify moves the green pin to the stack's top"
  # A single ready lane keeps the single path: its own landing, no stack.
  : > "$W/gate-runs"; lane w5 five f5.txt
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null
  for _ in $(seq 1 150); do git -C "$PROJ" log --format=%s trunk | grep -q '^ticket w5' && break; sleep 0.2; done
  git -C "$PROJ" log --format=%s trunk | grep -q '^ticket w5' || fail "a single ready lane lands"
  ! grep -q 'batch-from' <(grep '^w5' "$HOME_D/data/trunk-landings.tsv") || fail "a single lane is not recorded as part of a stack"
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null  # the tick that follows the landing starts its verify
  for _ in $(seq 1 150); do [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] && break; sleep 0.2; done
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] || fail "the tick's verify moves the green pin after a single lane's landing"
  pass 'the landing check stacks the ready lanes into one landing and a single lane keeps its own path'
}

# shellcheck disable=SC2016 # the gate bodies are written out verbatim and expand when the gate runs them
test_the_queue_flushes_at_a_threshold_on_a_command_and_a_marked_lane_jumps_it() {
  local base out rc=0
  batch_world flushq; base=$(tip)
  printf 'flush-at-ready=3\nflush-after-minutes=20\n' >> "$HOME_D/config/trunk-policy"
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  # Below the threshold and young: two ready lanes wait; nothing lands one by one.
  lane q1 one f1.txt; lane q2 two f2.txt; fresh q1 5; fresh q2 4
  qsweep >/dev/null; unlanded 0 "two young lanes are below flush-at-ready and wait"
  # The third lane reaches the threshold: all three land in ONE stack behind ONE gate.
  lane q3 three f3.txt; fresh q3 3
  qsweep >/dev/null; settled 3
  [ "$(runs)" = 1 ] || fail "the flushed lanes were judged by one gate, got $(runs) runs"
  [ "$(awk -F'\t' '$6 ~ /^batch-from=/' "$HOME_D/data/trunk-landings.tsv" | wc -l | tr -d ' ')" = 3 ] || fail "the three landed as one stack"
  # One lane that has waited past flush-after-minutes lands by itself.
  base=$(tip); lane q4 four f4.txt; fresh q4 19
  qsweep >/dev/null; unlanded 0 "a lane that has waited 19 of 20 minutes still waits"
  fresh q4 21; qsweep >/dev/null; settled 1
  # `flush` lands every ready lane now, whatever the threshold says, and the request ends once the queue is empty.
  base=$(tip); lane q5 five f5.txt; lane q6 six f6.txt; fresh q5 2; fresh q6 1
  qsweep >/dev/null; unlanded 0 "two young lanes wait"
  out=$(JG_TASK_ID=q5 trunk flush "$PROJ" 2>&1) && fail "a worker never flushes the queue"; assert_contains "$out" "a worker never flushes" "the worker refusal says why"
  out=$(trunk flush "$PROJ" 2>&1) || fail "Overwatch can flush the queue: $out"; assert_contains "$out" "flush requested for proj" "flush says what it did"
  [ -e "$HOME_D/state/trunk-flush-proj" ] || fail "flush records its request"
  : > "$W/gate-runs"; qsweep >/dev/null; settled 2
  [ "$(runs)" = 1 ] || fail "flush lands the ready lanes as one stack, got $(runs) gate runs"
  qsweep >/dev/null; [ ! -e "$HOME_D/state/trunk-flush-proj" ] || fail "the flush request ends when no ready lane is left"
  # A lane marked land-next lands at once, ahead of the queue; the lanes below the threshold keep waiting.
  base=$(tip); lane q7 seven f7.txt; lane q9 nine f9.txt; fresh q7 3; fresh q9 1
  out=$(JG_TASK_ID=q9 trunk land-next q9 2>&1) && fail "a worker never marks a lane to land next"
  out=$(trunk land-next nosuch 2>&1) && fail "land-next needs a real task"; assert_contains "$out" "usage: jg-trunk.sh land-next" "land-next names its usage"
  trunk land-next q9 >/dev/null || fail "Overwatch can mark a lane to land next"
  qsweep >/dev/null; settled 1
  [ "$(git -C "$PROJ" log --format=%s "$base..trunk")" = "ticket q9" ] || fail "only the marked lane lands, the older lane waits"
  [ ! -e "$HOME_D/state/q9.land-next" ] || fail "the mark ends when the lane lands"
  # The marked lane leads the stack; a returned lane reporting last goes ahead of the other waiting lane.
  lane q10 ten f10.txt; lane q11 eleven f11.txt; fresh q10 2; fresh q11 1; fresh q7 0; trunk land-next q10 >/dev/null
  printf 'final fm/q7 conflicts with trunk (abc1234) in: f7.txt\n' > "$HOME_D/data/jg-trunk-landing/q7.0000000000000000000000000000000000000001.state"
  qsweep >/dev/null; settled 4
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | sed -n 2p)" = "ticket q10" ] || fail "the marked lane goes first: $(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket q9,ticket q10,ticket q7,ticket q11" ] || fail "the returned lane goes ahead of the earlier ready lane"
  pass 'the queue flushes and prioritizes marked and returned lanes'
}

# The landing check starts each landing with setsid, so the job leads its own process group and outlives the check that
# started it. Two such jobs kept polling a lock in their deleted fixture homes for 3 hours: a suite's cleanup must stop
# every job a check started (tests/lib.sh jg_test_reap_detached), even one still running when its fixture goes.
test_a_job_the_landing_check_starts_never_outlives_its_fixture() {
  local base job='' pid _
  world reap; base=$(tip)
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  sed -i.bak 's/^gate-full=.*/gate-full=sleep 300/' "$HOME_D/config/trunk-policy"  # the landing's own gate hangs
  lane r1 one f1.txt
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null
  for _ in $(seq 1 150); do
    for pid in $(jg_test_detached_alive); do
      ps -o args= -p "$pid" 2>/dev/null | grep -q 'trunk-landing.sh run ' && job=$pid
    done
    [ -z "$job" ] || break
    sleep 0.2
  done
  [ -n "$job" ] || fail "the landing check started a landing job that registered itself: $(cat "$JG_TEST_DETACHED_REGISTRY")"
  [ "$(ps -o pgid= -p "$job" | tr -d ' ')" = "$job" ] || fail "the landing job leads its own process group"
  jg_test_reap_detached
  [ -z "$(jg_test_detached_alive)" ] || fail "a job the landing check started outlived the cleanup: $(jg_test_detached_alive)"
  for _ in $(seq 1 50); do kill -0 "$job" 2>/dev/null || break; sleep 0.1; done  # the stop is a signal: the process may need a moment to go
  ! kill -0 "$job" 2>/dev/null || fail "the hung landing job $job is still running"
  ! pgrep -g "$job" >/dev/null 2>&1 || fail "a child in the landing job's group is still running: $(pgrep -g "$job" -a)"
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 0 ] || fail "a landing whose gate never finished moves nothing"
  pass 'a job the landing check starts is stopped with its process group when the suite cleans up'
}

test_queued_lanes_land_as_one_stack_and_a_red_stack_is_bisected
test_a_job_the_landing_check_starts_never_outlives_its_fixture
test_the_landing_check_stacks_ready_lanes_and_keeps_a_single_lane_on_its_own_path
test_the_queue_flushes_at_a_threshold_on_a_command_and_a_marked_lane_jumps_it
printf 'jg-trunk-queue: ok\n'
