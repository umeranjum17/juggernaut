#!/usr/bin/env bash
# Carry a merge that landed on the default branch to the active version branch.
#
# A long-lived version branch is what pull requests for the next release target,
# so it has to carry the default branch: a version branch that fell behind keeps
# running the gate it happens to hold, and every pull request into it fails on
# whatever the default branch already fixed. Nothing moves it when main moves,
# so bin/jg-merge-outcome-lib.sh runs this pass the moment it records a merge,
# and no home needs an editable hook for the carry to happen. The same pass
# covers a merge this home performed and a merge its poll detected, because both
# record through that one operation.
#
# The branch is a remote one, so the guards below are the push-path form of the
# ones bin/jg-ff-lib.sh applies to a checkout:
#   - never force: the push names the default branch's commit as the source of
#     the version ref, with no `+` and no --force, so the remote refuses anything
#     that is not a fast-forward and this script never rewrites history;
#   - never act from a dirty copy: a checkout carrying tracked or stray untracked
#     changes is skipped and every path is named, so an unexpected edit is never
#     read as the state to publish;
#   - never merge or rebase the version branch: a version branch the default
#     branch cannot fast-forward is reported and left exactly as it is. That
#     divergence needs a real merge toward the default branch, which is a human
#     decision, not something a post-merge pass may invent.
#
# Usage: jg-version-branch-sync.sh run
#        jg-version-branch-sync.sh features <merged-pr-url> [<repo-dir>]
#
#   run   One guarded pass: read config/version-branch, refresh origin, and move
#         the version branch forward to the default branch when it can be a
#         fast-forward. Silent when no version branch is configured, and one line
#         per outcome otherwise.
#
#   features  The other direction, once a release has landed. When the merge
#         this pass is handed was the release pull request - base the default
#         branch, head the project's current version branch - the version branch
#         is carried into every open pull request that targets it, so no feature
#         branch keeps running the gate the release replaced.
#         bin/jg-version-branch-lib.sh owns which branch is current, <repo-dir>
#         is the project's checkout (JG_ROOT by default), and every other merge
#         is silent, because this runs after every recorded merge.
#         A feature branch carries its own commits and can never fast-forward, so
#         the carry is a real merge commit built with git plumbing: merge-tree
#         computes the tree and commit-tree the commit, with the feature tip as
#         its first parent, so no working tree or index is touched and the push
#         is an ordinary fast-forward of that ref with no force.
#         A branch whose merge conflicts is reported and left exactly as it is,
#         and a fork pull request is skipped because its branch is not in this
#         repository.
#
# Environment: JG_HOME, JG_ROOT_OVERRIDE, JG_CONFIG_OVERRIDE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"

# shellcheck source=bin/jg-ff-lib.sh
. "$SCRIPT_DIR/jg-ff-lib.sh"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-version-branch-lib.sh
. "$SCRIPT_DIR/jg-version-branch-lib.sh"

usage() { echo "usage: jg-version-branch-sync.sh run | features <merged-pr-url> [<repo-dir>]" >&2; }

# features_pass <merged-pr-url> <repo-dir>: carry the version branch into the
# open feature pull requests that target it, once the release landed.
# Every unreadable input stays silent or names one reason and returns 0: this
# runs inside the merge record, which must never fail because a carry could not
# be attempted.
features_pass() {  # <merged-pr-url> <repo-dir>
  local url=$1 dir=$2 version default fields base head_ref tip prs number branch cross ref tree commit out
  jg_pr_url_parse "$url" || return 0
  [ "$JG_PR_PROVIDER" = github ] || \
    { echo "skipped: only GitHub release merges are carried"; return 0; }
  if [ ! -d "$dir" ] || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "skipped: $dir is not a git checkout"
    return 0
  fi
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || \
    { echo "skipped: no origin remote"; return 0; }
  version=$(jg_current_version_branch "$dir") || version=
  [ -n "$version" ] || { echo "skipped: $dir carries no release/c-<N> branch"; return 0; }
  default=$(default_branch "$dir") || \
    { echo "skipped: cannot determine the default branch"; return 0; }
  [ "$version" != "$default" ] || return 0
  command -v gh >/dev/null 2>&1 || { echo "skipped: gh is not on PATH"; return 0; }
  # Not the release pull request: every other merge is silent here.
  fields=$(gh pr view "$JG_PR_NUMBER" --repo "$JG_PR_PATH" --json baseRefName,headRefName \
    --jq '[.baseRefName, .headRefName] | @tsv' 2>/dev/null) || return 0
  case "$fields" in *$'\t'*) ;; *) return 0 ;; esac
  base=${fields%%$'\t'*}
  head_ref=${fields#*$'\t'}
  [ "$base" = "$default" ] && [ "$head_ref" = "$version" ] || return 0
  if ! git -C "$dir" merge-tree -h 2>&1 | grep -q -- '--write-tree'; then
    echo "skipped: this git cannot merge without a working tree (merge-tree --write-tree is missing)"
    return 0
  fi
  # A merge record can run from a pane with no terminal, so a credential prompt
  # would hang it instead of failing.
  GIT_TERMINAL_PROMPT=0
  export GIT_TERMINAL_PROMPT
  fetch_once "$dir" || { echo "skipped: fetch failed"; return 0; }
  tip=$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$version^{commit}") || tip=
  [ -n "$tip" ] || { echo "skipped: origin has no $version"; return 0; }
  prs=$(gh pr list --repo "$JG_PR_PATH" --state open --base "$version" --limit 100 \
    --json number,headRefName,isCrossRepository \
    --jq '.[] | [(.number | tostring), .headRefName, (.isCrossRepository | tostring)] | @tsv' 2>/dev/null) || \
    { echo "skipped: the open pull request list could not be read"; return 0; }
  while IFS=$'\t' read -r number branch cross; do
    [ -n "$branch" ] || continue
    if [ "$cross" = true ]; then
      echo "$branch: skipped: pull request $number comes from a fork"
      continue
    fi
    ref=$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}") || ref=
    [ -n "$ref" ] || { echo "$branch: skipped: origin has no such branch"; continue; }
    if git -C "$dir" merge-base --is-ancestor "$tip" "$ref" 2>/dev/null; then
      echo "$branch: already current"
      continue
    fi
    if ! tree=$(git -C "$dir" merge-tree --write-tree --no-messages "$ref" "$tip" 2>/dev/null); then
      echo "$branch: skipped: merging $version conflicts; it was left as it is"
      continue
    fi
    out=$(printf 'Merge %s into %s\n' "$version" "$branch" | \
      git -C "$dir" commit-tree "$tree" -p "$ref" -p "$tip" 2>&1) || out=
    commit=$out
    if [ -z "$commit" ] || ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
      echo "$branch: skipped: the merge commit could not be recorded: $(first_line "$out")"
      continue
    fi
    if out=$(git -C "$dir" push --quiet origin "$commit:refs/heads/$branch" 2>&1); then
      echo "$branch: updated $(git -C "$dir" rev-parse --short "$ref")..$(git -C "$dir" rev-parse --short "$commit")"
    else
      echo "$branch: skipped: push refused: $(first_line "$out")"
    fi
  done <<EOF
$prs
EOF
  return 0
}

case "${1:-}" in
  features)
    shift
    { [ "$#" -ge 1 ] && [ "$#" -le 2 ]; } || { usage; exit 2; }
    features_pass "$1" "${2:-$JG_ROOT}"
    exit 0 ;;
  run) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

# config/version-branch holds the branch name and nothing else. An absent or
# blank file means this home carries no version branch, which costs one test.
[ -f "$CONFIG/version-branch" ] || exit 0
branch=$(sed -n '1s/[[:space:]]*$//;1p' "$CONFIG/version-branch" 2>/dev/null)
[ -n "$branch" ] || exit 0
case "$branch" in
  -*|*[!A-Za-z0-9._/-]*)
    echo "config/version-branch does not name a branch: $branch"
    exit 0 ;;
esac

dir=$JG_ROOT
if [ ! -d "$dir" ] || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "$branch: skipped: $dir is not a git checkout"
  exit 0
fi
if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
  echo "$branch: skipped: no origin remote"
  exit 0
fi
if ! default=$(default_branch "$dir"); then
  echo "$branch: skipped: cannot determine the default branch"
  exit 0
fi
[ "$branch" != "$default" ] || { echo "$branch: skipped: it is the default branch"; exit 0; }

dirty=$(dirty_paths "$dir")
if [ -n "$dirty" ]; then
  echo "$branch: skipped: dirty working tree"
  printf '%s\n' "$dirty" | while IFS= read -r path; do
    echo "  dirty path: $path"
  done
  exit 0
fi

# A merge pass can run from a pane with no terminal, so a credential prompt would
# hang the merge record instead of failing. Refuse to prompt.
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT
if ! fetch_once "$dir"; then
  echo "$branch: skipped: fetch failed"
  exit 0
fi

version=$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}") || version=''
if [ -z "$version" ]; then
  echo "$branch: skipped: origin has no such branch"
  exit 0
fi
target=$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$default^{commit}") || target=''
if [ -z "$target" ]; then
  echo "$branch: skipped: cannot read origin/$default"
  exit 0
fi
if [ "$version" = "$target" ]; then
  echo "$branch: already current"
  exit 0
fi
if ! git -C "$dir" merge-base --is-ancestor "$version" "$target" 2>/dev/null; then
  echo "$branch: skipped: origin/$default cannot fast-forward it; it needs a merge toward $default and was left as it is"
  exit 0
fi

before=$(git -C "$dir" rev-parse --short "$version")
after=$(git -C "$dir" rev-parse --short "$target")
if out=$(git -C "$dir" push --quiet origin "$target:refs/heads/$branch" 2>&1); then
  echo "$branch: updated $before..$after"
else
  echo "$branch: skipped: push refused: $(first_line "$out")"
fi
exit 0
