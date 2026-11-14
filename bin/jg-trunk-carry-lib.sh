#!/usr/bin/env bash
# The one answer to "which commits of <head> are not carried into <upstream>" for the trunk's old-trunk checks: retire
# (bin/jg-trunk.sh) and the release proof (bin/jg-trunk-release-proof.sh). A commit is carried when <upstream> holds it by
# ancestry or by patch (git cherry, so a release merged by rebase or squash with new commit ids still counts), and an
# empty commit (its tree equals its parent's) changes nothing, so it has nothing to carry and is never a hotfix.
# Sourced, never run.

# jg_trunk_uncarried <git-dir> <upstream> <head>: one sha per line, oldest first; a failing compare prints nothing and returns 1.
jg_trunk_uncarried() {
  local dir=$1 up=$2 head=$3 mark sha marks
  marks=$(git -C "$dir" cherry "$up" "$head" 2>/dev/null) || return 1
  while read -r mark sha; do
    [ "$mark" = + ] || continue
    # A root commit has no parent to compare with, so it is never empty.
    if git -C "$dir" rev-parse -q --verify "$sha^" >/dev/null && [ "$(git -C "$dir" rev-parse "$sha^{tree}")" = "$(git -C "$dir" rev-parse "$sha^^{tree}")" ]; then continue; fi
    printf '%s\n' "$sha"
  done <<<"$marks"
}
