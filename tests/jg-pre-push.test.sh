#!/usr/bin/env bash
# Tests for bin/jg-install-pre-push.sh and bin/jg-pre-push.sh: the pre-push hook
# that runs ShellCheck and the fast changed tests on the files a push changes.
#
# Every case is a real `git push` from a throwaway clone, through the hook the
# installer wrote, to a local bare remote. The clone carries this repository's
# real bin/ (so the real bin/jg-lint.sh judges the change); only bin/jg-test-run.sh
# is a recorder, because the changed-test suite it would run is proven by its
# own tests and the question here is whether the hook asks for it correctly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-pre-push)
jg_git_identity

want=$("$ROOT/bin/jg-lint.sh" --required-version 2>/dev/null || true)
have=$(shellcheck --version 2>/dev/null | sed -n 's/^version: //p' || true)
if [ -z "$want" ] || [ "$have" != "$want" ]; then
  echo "skip: pinned ShellCheck $want is not installed (have '${have:-none}'); bin/jg-install-shellcheck.sh installs it"
  exit 0
fi

# The shared template: a tiny repository with this repo's bin/ (copied once,
# it is megabytes), the recorder in place of bin/jg-test-run.sh, and one valid
# workflow because bin/jg-lint.sh refuses a tree with none. The recorder writes
# to the files named by PP_LOG and PP_RC, which each world sets.
TEMPLATE=$TMP_ROOT/template.git
build_template() {
  local seed=$TMP_ROOT/seed
  jg_git_init_commit "$seed"
  cp -R "$ROOT/bin" "$seed/bin"
  # bin/jg-lint.sh also runs the ports check, which reads its manifest from defaults/.
  mkdir -p "$seed/defaults"
  cp "$ROOT"/defaults/ports-adapters "$ROOT"/defaults/ports-adapters-legacy "$seed/defaults/"
  cat >"$seed/bin/jg-test-run.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PP_LOG"
exit "$(cat "$PP_RC" 2>/dev/null || echo 0)"
SH
  chmod +x "$seed/bin/jg-test-run.sh"
  mkdir -p "$seed/.github/workflows"
  printf '%s\n' 'name: x' 'on: push' 'jobs:' '  a:' '    runs-on: ubuntu-latest' '    steps:' '      - run: "true"' \
    >"$seed/.github/workflows/x.yml"
  git -C "$seed" add -A
  git -C "$seed" commit -qm 'base with bin'
  git clone -q --bare "$seed" "$TEMPLATE"
}
build_template

# make_world <name>: sets WORLD to a fresh directory holding a bare origin and
# a clone of it whose origin/main is the base commit.
make_world() {
  WORLD=$TMP_ROOT/$1
  mkdir -p "$WORLD"
  git clone -q --bare "$TEMPLATE" "$WORLD/origin.git"
  git clone -q "$WORLD/origin.git" "$WORLD/work"
  : >"$WORLD/test-run.log"
  export PP_LOG=$WORLD/test-run.log PP_RC=$WORLD/test-run.rc
}

commit_file() { # <work> <path> <content> <message>
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "$4"
}

test_install_is_safe_to_rerun_and_to_remove() {
  local dir work hook rc
  make_world install
  dir=$WORLD
  work=$dir/work
  hook=$(git -C "$work" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push

  "$work/bin/jg-install-pre-push.sh" 2>"$dir/err1" || fail "install: first install failed: $(cat "$dir/err1")"
  [ -x "$hook" ] || fail "install: the hook was not written executable"
  "$work/bin/jg-install-pre-push.sh" 2>"$dir/err2" || fail "install: a second install failed"
  assert_equals 1 "$(grep -c 'jg-pre-push-hook' "$hook")" "install: rerun duplicated the hook"

  printf '#!/bin/sh\necho mine\n' >"$hook"
  rc=0
  "$work/bin/jg-install-pre-push.sh" 2>"$dir/err3" || rc=$?
  assert_equals 1 "$rc" "install: a foreign hook was overwritten without --force"
  assert_grep 'echo mine' "$hook" "install: the foreign hook was changed"
  "$work/bin/jg-install-pre-push.sh" --force 2>"$dir/err4" || fail "install: --force failed"
  assert_grep 'echo mine' "$hook.pre-jg" "install: --force did not keep the old hook"

  "$work/bin/jg-install-pre-push.sh" --uninstall 2>"$dir/err5" || fail "install: uninstall failed"
  assert_grep 'echo mine' "$hook" "install: uninstall did not restore the old hook"
  pass "the installer is idempotent, never overwrites a foreign hook, and uninstalls cleanly"
}

test_clean_push_runs_both_checks_against_the_nearest_base() {
  local dir work
  make_world clean
  dir=$WORLD
  work=$dir/work
  "$work/bin/jg-install-pre-push.sh" 2>/dev/null || fail "clean: install failed"
  git -C "$work" checkout -q -b feature
  commit_file "$work" notes.txt 'a note' 'add a note'
  git -C "$work" push -q origin feature 2>"$dir/push.err" || fail "clean: a clean push was refused: $(cat "$dir/push.err")"
  assert_grep 'lint ok' "$dir/push.err" "clean: the lint did not run"
  assert_grep "--changed --base origin/main --exclude-family real-herdr-gated --max-weight-ms 15000" "$dir/test-run.log" \
    "clean: the changed tests were not asked for against the base commit"
  pass "a clean push runs the lint and the changed tests against the base it will be reviewed against"
}

test_a_shellcheck_error_stops_the_push_before_the_tests() {
  local dir work rc
  make_world lint
  dir=$WORLD
  work=$dir/work
  "$work/bin/jg-install-pre-push.sh" 2>/dev/null || fail "lint: install failed"
  git -C "$work" checkout -q -b feature
  commit_file "$work" bin/jg-bad.sh $'#!/usr/bin/env bash\necho $1' 'a script ShellCheck rejects'
  rc=0
  git -C "$work" push -q origin feature 2>"$dir/push.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "lint: a push with a ShellCheck error went through"
  assert_grep 'lint failed' "$dir/push.err" "lint: the failure was not named"
  assert_grep 'no-verify' "$dir/push.err" "lint: the way past the check was not named"
  [ ! -s "$dir/test-run.log" ] || fail "lint: the tests ran after the lint failed"
  git -C "$dir/origin.git" rev-parse -q --verify refs/heads/feature >/dev/null \
    && fail "lint: the rejected branch reached the remote"
  git -C "$work" push -q --no-verify origin feature 2>/dev/null || fail "lint: --no-verify did not skip the hook"
  pass "a ShellCheck error stops the push before the tests, and --no-verify still skips the hook"
}

test_a_failing_changed_test_stops_the_push() {
  local dir work rc
  make_world tests
  dir=$WORLD
  work=$dir/work
  "$work/bin/jg-install-pre-push.sh" 2>/dev/null || fail "tests: install failed"
  git -C "$work" checkout -q -b feature
  commit_file "$work" notes.txt 'a note' 'add a note'
  printf '1\n' >"$dir/test-run.rc"
  rc=0
  git -C "$work" push -q origin feature 2>"$dir/push.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "tests: a push with a failing changed test went through"
  assert_grep 'changed tests failed' "$dir/push.err" "tests: the failure was not named"
  pass "a failing changed test stops the push"
}

test_an_update_checks_only_the_new_commits() {
  local dir work first
  make_world update
  dir=$WORLD
  work=$dir/work
  "$work/bin/jg-install-pre-push.sh" 2>/dev/null || fail "update: install failed"
  git -C "$work" checkout -q -b feature
  commit_file "$work" one.txt one 'first'
  git -C "$work" push -q origin feature 2>/dev/null || fail "update: the first push failed"
  first=$(git -C "$work" rev-parse HEAD)
  : >"$dir/test-run.log"
  commit_file "$work" two.txt two 'second'
  git -C "$work" push -q origin feature 2>/dev/null || fail "update: the second push failed"
  assert_grep "--changed --base $first " "$dir/test-run.log" \
    "update: the second push was not checked against the commit the remote already had"
  pass "an update of a pushed branch is checked against what the remote already has"
}

test_a_push_that_is_not_head_or_deletes_is_let_through_with_a_note() {
  local dir work
  make_world other
  dir=$WORLD
  work=$dir/work
  "$work/bin/jg-install-pre-push.sh" 2>/dev/null || fail "other: install failed"
  git -C "$work" checkout -q -b feature
  commit_file "$work" notes.txt 'a note' 'add a note'
  git -C "$work" push -q origin feature 2>/dev/null || fail "other: the push failed"
  git -C "$work" branch other
  git -C "$work" checkout -q main
  : >"$dir/test-run.log"
  git -C "$work" push -q origin other 2>"$dir/push.err" || fail "other: a push of a non-HEAD ref was refused"
  assert_grep 'not of the checked-out commit' "$dir/push.err" "other: the skip was not explained"
  git -C "$work" push -q origin --delete feature 2>"$dir/del.err" || fail "other: deleting a remote branch was refused"
  [ ! -s "$dir/test-run.log" ] || fail "other: the tests ran for a push that was not checked"
  pass "a push of another ref, or a deletion, is let through with a note instead of checked against the wrong files"
}

test_a_checkout_without_the_script_is_unaffected() {
  local dir work
  make_world absent
  dir=$WORLD
  work=$dir/work
  "$work/bin/jg-install-pre-push.sh" 2>/dev/null || fail "absent: install failed"
  git -C "$work" checkout -q -b feature
  git -C "$work" rm -q bin/jg-pre-push.sh
  git -C "$work" commit -qm 'a checkout from before the check existed'
  git -C "$work" push -q origin feature 2>/dev/null || fail "absent: a tree with no check was blocked by the hook"
  pass "a work tree with no bin/jg-pre-push.sh pushes as before"
}

test_install_is_safe_to_rerun_and_to_remove
test_clean_push_runs_both_checks_against_the_nearest_base
test_a_shellcheck_error_stops_the_push_before_the_tests
test_a_failing_changed_test_stops_the_push
test_an_update_checks_only_the_new_commits
test_a_push_that_is_not_head_or_deletes_is_let_through_with_a_note
test_a_checkout_without_the_script_is_unaffected
