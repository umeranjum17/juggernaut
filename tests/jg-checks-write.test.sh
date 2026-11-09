#!/usr/bin/env bash
# bin/jg-checks-write.sh: a worker's `## Checks` block is written from its sealed proof run, and the real
# merge-gate lint (core/merge-on-green/checks-lint.sh) passes it. A run with no evidence file that holds up,
# no run at the head, or a run whose record is not in the task folder exits 1 with the cause.
# The lint is the Juggernaut feature lint (Rego policy, so OPA and Go are needed; the test skips without
# them), and done-done's own lint as well when a done-done with the pinned lint is installed.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=core/lib/policy-test-env.sh
. "$ROOT/core/lib/policy-test-env.sh"

REAL_DD=$(command -v done-done 2>/dev/null || true)
root=$(jg_test_tmproot checks-write) || fail "no fixture root"
home=$root/home repo=$root/repo
mkdir -p "$home/state" "$home/config" "$root/fakebin"
jg_git_init_commit "$repo"
mkdir -p "$repo/.agents/skills/done-done-verify-demo"
printf -- '---\nname: done-done-verify-demo\n---\n' > "$repo/.agents/skills/done-done-verify-demo/SKILL.md"
HEAD=$(git -C "$repo" rev-parse HEAD)
# merge-card's discovery asks done-done for its evidence root and receipt; this stand-in has neither, so
# the sealed run is found in the task folder only and nothing reaches the real ~/.done-done.
printf '#!/usr/bin/env bash\nexit 1\n' > "$root/fakebin/done-done"
chmod +x "$root/fakebin/done-done"
export JG_HOME=$home PATH="$root/fakebin:$PATH"
W=$ROOT/bin/jg-checks-write.sh
OUTCOME='a worker writes its proof block with one command'

seal() {  # <task> [<commit>]: a sealed clean run at <commit> (default HEAD) whose log and steps sit in the task folder
  local task=$1 commit=${2:-$HEAD} run dir
  run=20261109T120000Z-${commit:0:8}-abc123 dir=$home/data/$1
  rm -rf -- "$dir"; mkdir -p "$dir/$run" "$dir/.done-done/runs"
  jg_write_meta "$home/state/$task.meta" "worktree=$repo"
  printf 'ok - the writer journey passed at %s\n' "$commit" > "$dir/$run/suite.log"
  printf '{"steps":["write"]}\n' > "$dir/$run/steps.json"
  jq -n --arg run "$run" --arg c "$commit" --arg sha "$(sha256sum "$dir/$run/suite.log" | cut -d' ' -f1)" --arg sha2 "$(sha256sum "$dir/$run/steps.json" | cut -d' ' -f1)" '
    {schema: 1, run_id: $run, journey: null, command: "bash tests/demo.test.sh", commit: $c, dirty: false,
     started_at: "2026-11-09T12:00:00.000Z", exit: 0,
     files: [{path: "\($run)/suite.log", sha256: $sha, bytes: 10}, {path: "\($run)/steps.json", sha256: $sha2, bytes: 10}]}' \
    > "$dir/.done-done/runs/$run.json"
  RUN=$run
}
lint() {  # <task> [done-done binary]: the real merge-gate lint over the written block; sets lint_out and lint_rc
  lint_out=$(JG_DONE_DONE_BIN=${2:-$root/no-done-done} bash "$ROOT/core/merge-on-green/checks-lint.sh" "$home/data/$1/checks.md" "$home/data/$1" 2>&1)
  lint_rc=$?
}

# A sealed run at the head: the block names the run's recipe, its files, and the lint passes it.
seal t1
out=$(bash "$W" t1 --outcome "$OUTCOME" --screen none 2>&1); rc=$?
assert_equals 0 "$rc" "writer exits 0 from a sealed run ($out)"
block=$(cat "$home/data/t1/checks.md")
assert_contains "$block" "outcome: $OUTCOME" "the outcome is the worker's own line"
assert_contains "$block" "repro: n/a: no bug" "repro defaults to n/a: no bug"
assert_contains "$block" "proof: done-done-verify-demo: done-done run -- bash tests/demo.test.sh (run $RUN)" "proof names the verify skill, the run's own command and its id"
assert_contains "$block" "evidence: $RUN/steps.json, $RUN/suite.log" "evidence names the run's own files relative to the task folder"
assert_contains "$block" $'\nscreen: none' "--screen none declares no screen"
lint t1
assert_equals 0 "$lint_rc" "the feature lint passes the written block ($lint_out)"
assert_contains "$lint_out" "checks-lint: PASS" "the feature lint prints PASS"
pass "a sealed run at the head becomes a block the merge-gate lint passes"

if [ -n "$REAL_DD" ] && "$REAL_DD" lint --help 2>/dev/null | grep -q 'checks.generated_paths:'; then
  seal t1d
  bash "$W" t1d --outcome "$OUTCOME" --repro 'bash tests/demo.test.sh' --screen none >/dev/null 2>&1 || fail "writer failed for the done-done lint row"
  lint t1d "$REAL_DD"
  assert_equals 0 "$lint_rc" "done-done's own lint passes the written block ($lint_out)"
  assert_contains "$(cut -f2,4 "$home/data/done-done-lint/lint.log" 2>/dev/null)" "$home/data/t1d/checks.md"$'\t'"pass" "done-done itself judged the block (its lint.log row)"
  assert_contains "$(cat "$home/data/t1d/checks.md")" "repro: bash tests/demo.test.sh" "--repro is written as given"
  pass "done-done's own lint passes the written block"
else
  pass "skip: no done-done with the pinned lint on PATH; the feature lint row above is the proof"
fi

# One file edited after the seal is left out and named; the rest still make a block.
seal t2
printf 'edited\n' >> "$home/data/t2/$RUN/steps.json"
out=$(bash "$W" t2 --outcome "$OUTCOME" 2>&1); rc=$?
assert_equals 0 "$rc" "a run with one good file still writes ($out)"
assert_contains "$out" "skipped $RUN/steps.json: its bytes differ from the sealed run record" "the edited file is named with its cause"
assert_contains "$(cat "$home/data/t2/checks.md")" "evidence: $RUN/suite.log" "only the intact file is cited"
assert_not_contains "$(cat "$home/data/t2/checks.md")" "steps.json" "the edited file is not cited"
pass "a file whose bytes differ from the sealed record is never cited"

# No evidence file holds up: exit 1, and no block is written.
seal t3
rm -f -- "$home/data/t3/$RUN/suite.log"; : > "$home/data/t3/$RUN/steps.json"
out=$(bash "$W" t3 --outcome "$OUTCOME" 2>&1); rc=$?
assert_equals 1 "$rc" "no evidence file exits 1 ($out)"
assert_contains "$out" "has no evidence file that holds up" "the refusal says no evidence file holds up"
assert_contains "$out" "skipped $RUN/suite.log: missing or empty in the task folder" "the missing file is named"
assert_absent "$home/data/t3/checks.md" "no block is written without evidence"
pass "no evidence file exits 1 and writes nothing"

# A run sealed at another commit is not this head's proof.
seal t4 0123456789abcdef0123456789abcdef01234567
out=$(bash "$W" t4 --outcome "$OUTCOME" 2>&1); rc=$?
assert_equals 1 "$rc" "a run at another commit exits 1 ($out)"
assert_contains "$out" "no sealed clean done-done run at $HEAD" "the refusal names the head with no run"
pass "a run sealed at another commit is refused"

# The run record left in done-done's evidence root: the copy is named.
seal t5
mkdir -p "$root/ddroot/.done-done/runs"
mv -- "$home/data/t5/.done-done/runs/$RUN.json" "$root/ddroot/.done-done/runs/"
jq -n --arg h "$HEAD" --arg r "$root/ddroot" '{head: $h, verdict: "fail", context: {root: $r}}' > "$home/data/t5/merge-card.json"
out=$(bash "$W" t5 --outcome "$OUTCOME" 2>&1); rc=$?
assert_equals 1 "$rc" "a record outside the task folder exits 1 ($out)"
assert_contains "$out" "the sealed run $RUN is not in $home/data/t5" "the refusal says the run is not in the task folder"
assert_contains "$out" ".done-done/runs/$RUN.json" "the refusal names the record to copy"
pass "a run left in done-done's evidence root is named, not cited"

# Usage: the outcome is the worker's to write and stays one line.
out=$(bash "$W" t1 2>&1); rc=$?
assert_equals 2 "$rc" "no --outcome exits 2"
out=$(bash "$W" t1 --outcome $'two\nlines' 2>&1); rc=$?
assert_equals 2 "$rc" "a two-line outcome exits 2 ($out)"
out=$(bash "$W" t1 --outcome "$OUTCOME" --screen yes 2>&1); rc=$?
assert_equals 2 "$rc" "--screen takes only none ($out)"
pass "the outcome is required and one line"
