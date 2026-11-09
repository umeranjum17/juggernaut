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
# Sourced by bin/jg-brief.sh, bin/jg-spawn.sh, bin/jg-pr-check.sh,
# bin/jg-pr-merge.sh, bin/jg-release-readiness.sh and bin/jg-version-branch-sync.sh.
# No side effects on source.

# A local-trunk project's trunk branch (bin/jg-trunk-policy-lib.sh owns it) is the
# head of that project's release pull request (jg_is_release_head below).
_jg_vb_d=${BASH_SOURCE[0]%/*}
[ "$_jg_vb_d" != "${BASH_SOURCE[0]}" ] || _jg_vb_d=.
# shellcheck source=bin/jg-trunk-policy-lib.sh
. "$_jg_vb_d/jg-trunk-policy-lib.sh"
unset _jg_vb_d

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

# Whether <head-ref> is a release pull request's head: the project's current
# version branch, the release in flight (config/frozen-release) even when a
# newer release/c-<N> exists, or, for a project registered local-trunk, its
# current trunk branch (jg_project_trunk_branch), which `jg-trunk.sh release`
# opens as the one release pull request into the default branch. Any other head,
# an older trunk version included, is not one. The pull request guard
# (bin/jg-pr-check.sh) uses it to admit the one pull request allowed to target
# the default branch, and bin/jg-pr-merge.sh uses it to merge that pull request
# with a merge commit.
jg_is_release_head() {  # <config-dir> <repo-dir> <head-ref>
  local config=${1:-} dir=${2:-} head=${3:-} version in_flight trunk
  [ -n "$head" ] && [ -n "$dir" ] && [ -d "$dir" ] || return 1
  version=$(jg_current_version_branch "$dir" 2>/dev/null) || version=
  in_flight=$(jg_release_in_flight_branch "$config" "$dir" 2>/dev/null) || in_flight=
  trunk=$(JG_CONFIG_OVERRIDE=$config jg_project_trunk_branch "$dir" 2>/dev/null) || trunk=
  { [ -n "$version" ] && [ "$head" = "$version" ]; } \
    || { [ -n "$in_flight" ] && [ "$head" = "$in_flight" ]; } \
    || { [ -n "$trunk" ] && [ "$head" = "$trunk" ]; }
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

# A release branch the captain has closed by carrying its work onto a newer
# release takes no new work either: a merge into it never reaches the default
# branch, though no release pull request of its own ever merged.
# The record is one fact in one place, like the freeze: the optional local,
# gitignored config/version-branch-carried, one branch name per line (blank
# lines and # comments ignored).
jg_carried_branches() {  # <config-dir>
  local file=${1:-}/version-branch-carried
  [ -f "$file" ] || return 0
  awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (length($0)) print }' "$file"
}

# A release branch is SHIPPED when its release pull request into the default
# branch merged, or when it is recorded as carried (jg_carried_branches), and
# not before. A newer release/c-<N> existing says only that
# the next cycle was cut; the older branch still takes work (a red-fix, a late
# feature) until its own release lands, because a merge into it reaches the
# default branch with that release. This is the one definition: the merge guard
# (bin/jg-pr-merge.sh), the release pull request check (bin/jg-pr-check.sh), the
# sync pass (bin/jg-version-branch-sync.sh) and the readiness pass
# (bin/jg-release-readiness.sh) all ask it, directly or through
# jg_release_orphans_of below.
#
# <repo> is whatever `gh --repo` takes. Return 0 when <branch> names
# release/c-<digits> and `gh` lists a merged pull request whose head is <branch>
# and whose base is <default>; 1 when it does not (also for any name that is not
# a release/c-<digits> branch); 2 when it cannot be read (no repo or default, no
# gh, or the forge failed), so every caller picks its own safe answer for an
# unreadable read. The read is bounded where the host has `timeout`.
# A carried branch answers 0 from the local record before any forge read; the
# record lives in ${JG_CONFIG_OVERRIDE:-$JG_HOME/config}.
jg_release_shipped() {  # <repo> <branch> <default>
  local repo=${1:-} branch=${2:-} default=${3:-} n
  case "$branch" in release/c-[0-9]*) ;; *) return 1 ;; esac
  case "${branch#release/c-}" in *[!0-9]*) return 1 ;; esac
  jg_carried_branches "${JG_CONFIG_OVERRIDE:-${JG_HOME:+$JG_HOME/config}}" | grep -qxF -- "$branch" && return 0
  [ -n "$repo" ] && [ -n "$default" ] && command -v gh >/dev/null 2>&1 || return 2
  if command -v timeout >/dev/null 2>&1; then
    n=$(timeout 25 gh pr list --repo "$repo" --state merged --head "$branch" \
      --base "$default" --limit 1 --json number --jq 'length' 2>/dev/null) || return 2
  else
    n=$(gh pr list --repo "$repo" --state merged --head "$branch" \
      --base "$default" --limit 1 --json number --jq 'length' 2>/dev/null) || return 2
  fi
  case "$n" in ''|*[!0-9]*) return 2 ;; esac
  [ "$n" -gt 0 ]
}

# Return 0 when <old> and <version> are both release/c-<digits> and <old> is
# numbered below <version>, compared as numbers.
jg_release_older_than() {  # <old> <version>
  local o=${1#release/c-} n=${2#release/c-}
  case "$1" in release/c-*) ;; *) return 1 ;; esac
  case "$2" in release/c-*) ;; *) return 1 ;; esac
  case "$o" in ''|*[!0-9]*) return 1 ;; esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((10#$o))" -lt "$((10#$n))" ]
}

# An orphan is an open pull request whose base is a SHIPPED release/c-<M> older
# than the release <version> (release/c-<N>, M < N): that release already
# reached the default branch, so whatever the pull request merges into goes
# nowhere. An older base whose release pull request has not merged
# (jg_release_shipped) is not an orphan, because it still takes work.
# Filter stdin lines of `<number><TAB><url><TAB><base>` and print those that are
# orphans of <version>; a line that is not that shape, or a base that is not
# release/c-<digits>, is dropped. Returns 2 and prints nothing when a shipped
# read was unreadable, so each caller decides what an unreadable list means.
jg_release_orphans_of() {  # <version-branch> <repo> <default-branch>
  local version=${1:-} repo=${2:-} default=${3:-} lines bases base shipped='' rc
  case "${version#release/c-}" in ''|*[!0-9]*) return 0 ;; esac
  lines=$(awk -F '\t' 'NF == 3 && $3 ~ /^release\/c-[0-9]+$/')
  [ -n "$lines" ] || return 0
  bases=$(printf '%s\n' "$lines" | awk -F '\t' '{ print $3 }' | sort -u)
  for base in $bases; do
    jg_release_older_than "$base" "$version" || continue
    rc=0
    jg_release_shipped "$repo" "$base" "$default" || rc=$?
    case "$rc" in 0) shipped="$shipped $base" ;; 1) ;; *) return 2 ;; esac
  done
  [ -n "$shipped" ] || return 0
  printf '%s\n' "$lines" | awk -F '\t' -v s="$shipped" '
    BEGIN { n = split(s, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    $3 in ok'
}
