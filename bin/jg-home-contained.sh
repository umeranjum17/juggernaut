#!/usr/bin/env bash
# Prove a home's commits are already in the trunk by TREE CONTAINMENT, not by ancestry.
# Usage: jg-home-contained.sh <home-head> <trunk-tip> [<git-dir-or-worktree>]   (default: the current directory)
# Exit 0: every path the home changed since its merge-base with the trunk is byte-identical (mode and content) at the
#   trunk tip, or the trunk changed that path after the merge-base (a later trunk commit supersedes it); a head that is
#   already an ancestor of the tip is contained too. Exit 1: prints one `uncontained: <path>` line for each path whose
#   home change the trunk never took. Exit 2: bad arguments or an unknown commit.
# The caller also owns the other half of the move: a clean working tree. A contained home then moves to the trunk tip
# by `git reset --keep <tip>` (docs/trunk-flow.md), never a merge, stash or force.
set -eu
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 2; }
repo=${3:-.}
for c in "$1" "$2"; do
  git -C "$repo" cat-file -e "$c^{commit}" 2>/dev/null || { echo "jg-home-contained: unknown commit $c" >&2; exit 2; }
done
head=$(git -C "$repo" rev-parse "$1^{commit}") tip=$(git -C "$repo" rev-parse "$2^{commit}")
if git -C "$repo" merge-base --is-ancestor "$head" "$tip"; then exit 0; fi
base=$(git -C "$repo" merge-base "$head" "$tip") || { echo "uncontained: no common history with the trunk"; exit 1; }
entry() { git -C "$repo" ls-tree "$1" -- "$2" | cut -f1; }  # "<mode> <type> <sha>", empty when the path is absent
bad=0
while IFS= read -r -d '' path; do
  mine=$(entry "$head" "$path")
  [ "$mine" != "$(entry "$tip" "$path")" ] || continue
  [ "$(entry "$base" "$path")" = "$(entry "$tip" "$path")" ] || continue
  printf 'uncontained: %s\n' "$path"; bad=1
done < <(git -C "$repo" diff --name-only -z --no-renames "$base" "$head")
exit "$bad"
