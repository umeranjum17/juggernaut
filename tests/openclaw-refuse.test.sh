#!/usr/bin/env bash
# Owner rule owner-rule-286ed286: no NEW OpenClaw work. One test, both refusals.
#
#   1. bin/jg-tasks-axi.sh add refuses an item whose title or body is OpenClaw work.
#   2. bin/jg-pr-merge.sh refuses a GitHub pull request whose title or body is OpenClaw work,
#      before any merge call.
#   3. Work that removes OpenClaw, or moves a product to Pi, still passes both.
# Remove either call to bin/jg-openclaw-rule.sh and the matching refusal case fails.
set -u
export JG_TASK_PRIORITY_CHECK=/nonexistent

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_git_identity fmtest fmtest@example.invalid

RULE="$ROOT/bin/jg-openclaw-rule.sh"
WRAPPER="$ROOT/bin/jg-tasks-axi.sh"
PR_MERGE="$ROOT/bin/jg-pr-merge.sh"
TMP_ROOT=$(jg_test_tmproot openclaw-refuse)
unset TASKS_AXI_FILE TASKS_AXI_BACKEND JG_HOME JG_ROOT_OVERRIDE JG_DATA_OVERRIDE JG_STATE_OVERRIDE JG_CONFIG_OVERRIDE JG_PROJECTS_OVERRIDE

# --- the rule: new work is refused, removal and the move to Pi pass -------------------------
refused() {  # <title> <body>
  local out rc=0
  out=$("$RULE" check "$1" "$2" 2>&1) || rc=$?
  expect_code 1 "$rc" "rule did not refuse: $1"
  assert_contains "$out" "owner-rule-286ed286" "the refusal did not name the owner rule: $1"
}
allowed() {  # <title> <body>
  "$RULE" check "$1" "$2" >/dev/null 2>&1 || fail "rule refused work that is not new OpenClaw work: $1"
}
refused "[feature] Fix openclaw-migrate-flake" "why: flaky"
refused "[feature] Add an OpenClaw retry" ""
refused "[feature] Open-Claw bridge" ""
refused "[feature] Tidy the agent list" "touches the OpenClaw adapter"
refused "[feature] Add a Pi gateway" "keeps OpenClaw alive instead of removing it"
allowed "[feature] Remove OpenClaw from Crewhouse" "OpenClaw is dropped"
allowed "[feature] Move Crewhouse agents to Pi (off OpenClaw)" ""
allowed "[feature] Replace OpenClaw with Pi" ""
allowed "[feature] Retire the OpenClaw adapter" ""
allowed "[feature] Add a Pi gateway" "no other runtime needed"

# --- 1. task intake ------------------------------------------------------------------------
home="$TMP_ROOT/intake"
mkdir -p "$home/data" "$home/state" "$home/config"
jg_test_tasks_toml "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
: > "$home/config/backlog-intake-loose"
intake() { (cd "$home" && JG_HOME="$home" JG_ROOT_OVERRIDE="$home" "$WRAPPER" "$@"); }
rc=0
out=$(intake add oc-1 "[feature] Fix openclaw-migrate-flake" --body "why: flaky" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "intake: an OpenClaw item was added"
assert_contains "$out" "owner-rule-286ed286" "intake: the refusal did not name the owner rule"
rc=0
out=$(intake add oc-2 "[feature] Tidy the agent list" --body "touches the OpenClaw adapter" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "intake: an item with OpenClaw in its body was added"
! grep -q "oc-1\|oc-2" "$home/data/backlog.md" || fail "intake: a refused item reached the backlog"
if command -v tasks-axi >/dev/null 2>&1; then
  intake add oc-3 "[feature] Remove OpenClaw from Crewhouse" --kind ship --priority 1 --body "OpenClaw is dropped" >/dev/null 2>&1 \
    || fail "intake: removal work was refused"
  grep -q "oc-3" "$home/data/backlog.md" || fail "intake: removal work did not reach the backlog"
else
  echo "skip: tasks-axi not found; the intake pass-through case was not run"
fi
pass "task intake refuses new OpenClaw work and lets removal work through"

# --- 2. merge gate -------------------------------------------------------------------------
merge_case() {  # <name> <title> <body>; prints the case dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/home/data" "$d/home/config" "$d/fakebin"
  jg_git_init_commit "$d/wt"
  git -C "$d/wt" update-ref refs/remotes/origin/main "$(git -C "$d/wt" rev-parse HEAD)"
  jg_test_tasks_toml "$d/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$d/home/data/backlog.md"
  jg_write_meta "$d/state/task-x1.meta" "window=jg-task-x1" "worktree=$d/wt" "project=$d/project" "kind=ship" "mode=no-mistakes"
  : > "$d/gh.log"
  printf '%s' "$2" > "$d/title"
  printf '%s' "$3" > "$d/body"
  cat > "$d/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JG_TEST_GH_LOG"
case "$*" in
  "pr view "*" --json title -q .title") cat "$JG_TEST_PR_TITLE"; exit 0 ;;
  "pr view "*" --json body -q .body") cat "$JG_TEST_PR_BODY"; exit 0 ;;
  "pr merge"*) echo "MERGE CALLED" >> "$JG_TEST_GH_LOG"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$d/fakebin/gh"
  printf '%s\n' "$d"
}
run_merge() {  # <case-dir>
  local d=$1
  JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$d/home" JG_STATE_OVERRIDE="$d/state" \
    JG_TEST_GH_LOG="$d/gh.log" JG_TEST_PR_TITLE="$d/title" JG_TEST_PR_BODY="$d/body" \
    HOME="$d/user-home" PATH="$d/fakebin:$PATH" "$PR_MERGE" task-x1 https://github.com/example/repo/pull/5
}
for variant in title body; do
  if [ "$variant" = title ]; then t="Fix openclaw-migrate-flake"; b="flaky"; else t="Tidy the agent list"; b="touches the OpenClaw adapter"; fi
  d=$(merge_case "merge-$variant" "$t" "$b")
  rc=0
  run_merge "$d" > "$d/stdout" 2> "$d/stderr" || rc=$?
  expect_code 1 "$rc" "merge: OpenClaw $variant must refuse"
  assert_grep "owner rule owner-rule-286ed286" "$d/stderr" "merge: the refusal did not name the owner rule ($variant)"
  assert_no_grep "MERGE CALLED" "$d/gh.log" "merge: gh pr merge ran on an OpenClaw PR ($variant)"
done
d=$(merge_case merge-removal "Remove OpenClaw from Crewhouse" "OpenClaw is dropped")
run_merge "$d" > "$d/stdout" 2> "$d/stderr" || true
assert_no_grep "owner-rule-286ed286" "$d/stderr" "merge: removal work was refused by the OpenClaw rule"
pass "the merge gate refuses new OpenClaw work and does not stop removal work"
