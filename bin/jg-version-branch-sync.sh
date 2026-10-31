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
#
#   run   One guarded pass: read config/version-branch, refresh origin, and move
#         the version branch forward to the default branch when it can be a
#         fast-forward. Silent when no version branch is configured, and one line
#         per outcome otherwise.
#
# Environment: JG_HOME, JG_ROOT_OVERRIDE, JG_CONFIG_OVERRIDE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"

# shellcheck source=bin/jg-ff-lib.sh
. "$SCRIPT_DIR/jg-ff-lib.sh"

usage() { echo "usage: jg-version-branch-sync.sh run" >&2; }

case "${1:-}" in
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
