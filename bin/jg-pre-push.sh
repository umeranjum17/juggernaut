#!/usr/bin/env bash
# jg-pre-push.sh - the pre-push check: ShellCheck and the fast changed tests on
# the files this push changes, in seconds, so a red CI run is found before the
# push instead of after the wait.
#
#   git push                              (the hook bin/jg-install-pre-push.sh installs runs this)
#   jg-pre-push.sh --base <ref>           check HEAD against <ref> by hand, no push needed
#   jg-pre-push.sh --help
#
# It runs the same two commands the pull request's required lanes run, narrowed
# to what is quick:
#   1. bin/jg-lint.sh --changed-base <base>   the changed canonical shell roots and the
#                                             workflow definitions, full source-aware analysis.
#   2. bin/jg-test-run.sh --changed --base <base> --exclude-family real-herdr-gated
#        --max-weight-ms $JG_PREPUSH_MAX_TEST_MS
#                                             the tests the changed paths map to, minus any
#                                             script whose recorded duration hint is over the
#                                             cap (named on stderr; CI still runs it).
#
# Which commits count: when the push updates a branch the remote already has,
# the base is the commit the remote has, so only the new commits are checked.
# For a new branch the base is the nearest of origin/main and origin/release/*
# (the one with the fewest commits since the merge point), which is the branch
# the pull request will be based on. JG_PREPUSH_BASE names a base explicitly.
#
# Only HEAD is checked: the lint and the tests read the working tree, so a push
# of any other ref, or a branch deletion, is allowed with a note rather than
# checked against the wrong files.
#
# It steps aside, naming why, and lets the push go when it cannot give an
# honest verdict: no base to compare against, a tool missing or at the wrong
# pinned version, or the wall budget spent. CI remains the authority; this is
# the early warning. `git push --no-verify` skips the hook entirely.
#
# Environment:
#   JG_PREPUSH=0                  skip the check (one push; prefer git push --no-verify)
#   JG_PREPUSH_BASE=<ref>         use this base instead of picking one
#   JG_PREPUSH_MAX_TEST_MS=<ms>   drop tests whose duration hint is over this (default 15000)
#   JG_PREPUSH_SECONDS=<n>        wall budget per step; a spent budget lets the push go (default 90)
#
# Exit 0 when the push may go, 1 when a check failed, 2 on bad usage.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SELF_DIR/.." && pwd -P)
ZERO=0000000000000000000000000000000000000000
MAX_TEST_MS=${JG_PREPUSH_MAX_TEST_MS:-15000}
BUDGET=${JG_PREPUSH_SECONDS:-90}

say() { printf 'jg-pre-push: %s\n' "$*" >&2; }
skip() { say "$*; not checking (CI will)."; exit 0; }

usage() { sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

BASE=${JG_PREPUSH_BASE:-}
MANUAL=0
case ${1:-} in
  -h|--help) usage; exit 0 ;;
  --base)
    [ "$#" -ge 2 ] || { say "--base requires a git ref"; exit 2; }
    BASE=$2
    MANUAL=1
    ;;
esac

[ "${JG_PREPUSH:-1}" != 0 ] || skip "JG_PREPUSH=0"
cd "$ROOT" || exit 2
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "not inside a work tree"

# nearest_base prints the remote-tracking base with the fewest commits between
# it and HEAD: the branch this work would be a pull request against.
nearest_base() {
  local ref count best='' best_count=''
  while IFS= read -r ref; do
    git rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1 || continue
    count=$(git rev-list --count "$ref..HEAD" 2>/dev/null) || continue
    if [ -z "$best" ] || [ "$count" -lt "$best_count" ]; then
      best=$ref
      best_count=$count
    fi
  done < <(printf '%s\n' origin/main; git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/release/' 2>/dev/null)
  printf '%s\n' "$best"
}

# A terminal on stdin means a hand run with no push to read.
if [ "$MANUAL" -eq 0 ] && [ -z "$BASE" ] && [ ! -t 0 ]; then
  # The hook's stdin: "<local ref> <local sha> <remote ref> <remote sha>" per ref.
  head_sha=$(git rev-parse HEAD 2>/dev/null) || skip "no HEAD"
  pushing_head=0
  remote_sha=$ZERO
  while read -r _lref lsha _rref rsha; do
    [ -n "${lsha:-}" ] || continue
    [ "$lsha" != "$ZERO" ] || continue
    if [ "$lsha" = "$head_sha" ]; then
      pushing_head=1
      remote_sha=$rsha
    fi
  done
  [ "$pushing_head" -eq 1 ] || skip "this push is not of the checked-out commit (or deletes a ref)"
  if [ "$remote_sha" != "$ZERO" ] && git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
    BASE=$remote_sha
  fi
fi
[ -n "$BASE" ] || BASE=$(nearest_base)
[ -n "$BASE" ] || skip "no origin/main or origin/release/* to compare against"
git rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1 || skip "base $BASE is not a commit here"

changed=$(git diff --name-only --diff-filter=ACMR "$BASE" HEAD 2>/dev/null) || skip "could not read the diff against $BASE"
[ -n "$changed" ] || { say "nothing changed against $BASE"; exit 0; }
count=$(printf '%s\n' "$changed" | wc -l | tr -d '[:space:]')
say "checking $count changed file(s) against $BASE"

# run_step <label> <command...>: run under the wall budget when a timeout tool
# exists. A spent budget is a note, not a verdict. A failure prints how to
# reproduce it and stops the push.
run_step() {
  local label=$1 start rc tool=''
  shift
  command -v timeout >/dev/null 2>&1 && tool=timeout
  [ -n "$tool" ] || { command -v gtimeout >/dev/null 2>&1 && tool=gtimeout; }
  start=$SECONDS
  if [ -n "$tool" ]; then
    "$tool" "$BUDGET" "$@"
  else
    "$@"
  fi
  rc=$?
  if [ "$rc" -eq 124 ] && [ -n "$tool" ]; then
    say "$label passed no verdict in ${BUDGET}s; letting the push go (CI will run it)"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    say "$label failed after $((SECONDS - start))s. Reproduce: $*"
    say "Fix it, or push anyway with: git push --no-verify (CI runs the same check)"
    return 1
  fi
  say "$label ok in $((SECONDS - start))s"
  return 0
}

# ShellCheck first: it is the cheaper and the more common failure. A missing or
# differently-pinned ShellCheck cannot give the verdict CI would, so step aside.
if [ -x "$ROOT/bin/jg-lint.sh" ]; then
  want=$("$ROOT/bin/jg-lint.sh" --required-version 2>/dev/null || true)
  have=$(shellcheck --version 2>/dev/null | sed -n 's/^version: //p' || true)
  if [ -z "$have" ]; then
    say "shellcheck is not installed (bin/jg-install-shellcheck.sh installs the pinned build); lint not checked"
  elif [ -n "$want" ] && [ "$have" != "$want" ]; then
    say "shellcheck $have is installed, the pin is $want (bin/jg-install-shellcheck.sh installs it); lint not checked"
  else
    run_step "lint" "$ROOT/bin/jg-lint.sh" --changed-base "$BASE" || exit 1
  fi
fi

if [ -x "$ROOT/bin/jg-test-run.sh" ]; then
  run_step "changed tests" "$ROOT/bin/jg-test-run.sh" --changed --base "$BASE" \
    --exclude-family real-herdr-gated --max-weight-ms "$MAX_TEST_MS" || exit 1
fi
exit 0
