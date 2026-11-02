#!/usr/bin/env bash
# Which branch new work on a project targets: the project's current version
# branch.
#
# A repository that ships releases keeps one long-lived release/c-<N> branch for
# the cycle in progress, and its feature pull requests target that branch while
# the default branch moves only when a release lands on it.
# The branch is a property of the repository, not of a home's config: every home
# that clones the project must resolve the same one with nothing to set, so the
# answer comes from the clone's own refs and a project with no release/c-<N>
# branch resolves to nothing, which leaves that project on its default branch
# exactly as before.
# The NEWEST release/c-<N> wins, because a release cycle only moves forward: the
# previous cycle's branch stays behind on origin, and a default that picked an
# older one would send new work to the branch a release already came from.
#
# Sourced by bin/jg-brief.sh, bin/jg-spawn.sh, bin/jg-pr-check.sh, and
# bin/jg-version-branch-sync.sh. No side effects on source.

# Print the project's current version branch, and exit 1 when it carries none.
# <repo-dir> is a checkout of the project; its remote-tracking and local refs are
# both read, so a clone that has not pruned an old cycle still resolves the
# newest one it knows.
jg_current_version_branch() {  # <repo-dir>
  local dir=$1
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 1
  git -C "$dir" for-each-ref --format='%(refname)' \
    refs/remotes refs/heads 2>/dev/null | awk '
      /refs\/(remotes\/[^/]+\/|heads\/)release\/c-[0-9]+$/ {
        n = $0
        sub(/.*\/release\/c-/, "", n)
        if (!seen || n + 0 > best) { best = n + 0; seen = 1; name = $0 }
      }
      END {
        if (!seen) exit 1
        sub(/.*refs\/(remotes\/[^/]+\/|heads\/)/, "", name)
        print name
      }'
}

# 0 when <branch> is the project's current version branch, so a caller can allow
# the one pull request that is expected to target the default branch - the
# release pull request, which has the version branch as its head.
jg_version_branch_is_current() {  # <repo-dir> <branch>
  local current
  [ -n "${2-}" ] || return 1
  current=$(jg_current_version_branch "$1") || return 1
  [ "$2" = "$current" ]
}
