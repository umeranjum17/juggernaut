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

# The release already in flight: the one branch config/frozen-release names while
# it ships. It is the release pull request's head even when a higher-numbered
# release/c-<N> has since been opened, so the guard that admits the one pull
# request allowed to target the default branch honours it (bin/jg-pr-check.sh).
# Prints the branch; exit 1 with nothing when the marker is absent, unreadable,
# not exactly one release/c-<N> name, or names a branch the project does not
# carry, so every doubtful marker falls back to the highest-numbered rule above.
jg_release_in_flight_branch() {  # <config-dir> <repo-dir>
  local file=${1:-}/frozen-release dir=${2:-} name n
  [ -f "$file" ] && [ -r "$file" ] || return 1
  name=$(awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (length($0)) print }' "$file" 2>/dev/null) || return 1
  [ -n "$name" ] && [ "$(printf '%s\n' "$name" | wc -l)" -eq 1 ] || return 1
  case "$name" in release/c-[0-9]*) ;; *) return 1 ;; esac
  n=${name#release/c-}
  case "$n" in *[!0-9]*) return 1 ;; esac
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  git -C "$dir" for-each-ref --format='%(refname)' refs/remotes refs/heads 2>/dev/null \
    | grep -Eq "^refs/(remotes/[^/]+/|heads/)$name\$" || return 1
  printf '%s\n' "$name"
}

# A release branch the captain has frozen takes no new work.
# The freeze is one fact in one place: the optional local, gitignored
# config/version-branch-frozen beside config/version-branch, one branch name per
# line (blank lines and # comments ignored). Every consumer reads that file
# through the two functions below, so the scaffold, the spawn and the pull
# request check can never disagree about what is frozen.
# The single exception is work declared as a fix to the frozen release's own red
# checks: --red-fix-of <branch> on bin/jg-brief.sh and bin/jg-spawn.sh, recorded
# as red_fix_of=<branch> in the task record. It frees only the branch it names.

# Print each frozen branch, one per line; nothing when the file is absent.
jg_frozen_branches() {  # <config-dir>
  local file=${1:-}/version-branch-frozen
  [ -f "$file" ] || return 0
  awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (length($0)) print }' "$file"
}

# Return 1 with one line on stderr when <base> is frozen and <red-fix-of> does
# not name it; return 0 otherwise. The line names the frozen branch and the
# allowed alternative: the project's current version branch when it differs from
# the frozen one, else the red-fix declaration.
jg_frozen_base_refusal() {  # <config-dir> <project-dir> <base> <red-fix-of> <caller>
  local config=$1 project=$2 base=$3 red=${4:-} caller=$5 alt
  [ -n "$base" ] || return 0
  jg_frozen_branches "$config" | grep -qxF -- "$base" || return 0
  [ "$red" != "$base" ] || return 0
  alt=$(jg_current_version_branch "$project" 2>/dev/null) || alt=
  if [ -n "$alt" ] && [ "$alt" != "$base" ]; then
    echo "error: $caller: $base is frozen and takes no new work; target $alt instead, or declare a fix to $base's own red checks with --red-fix-of $base" >&2
  else
    echo "error: $caller: $base is frozen and takes no new work; target the next release branch instead, or declare a fix to $base's own red checks with --red-fix-of $base" >&2
  fi
  return 1
}
