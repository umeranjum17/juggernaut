#!/usr/bin/env bash
# Tag a release and publish its GitHub release page the moment its pull request lands.
#
# bin/jg-merge-outcome-lib.sh runs this after it records any merge, so every
# project gets the mark and no agent has to remember it. It is silent for every
# merge that was not a release and says in one line why it did nothing otherwise.
#
# Usage: jg-release-tag.sh <merged-pr-url> [<repo-dir>]
#
#   A release is a pull request whose head is release/<name> and whose base is
#   the repository's default branch. <repo-dir> is the project's checkout; with
#   it, a missing clone or one with no release/* branch skips before any network
#   call. Backfill an old release by running it without <repo-dir>.
#
# With gh only it creates tag <name> (release/c-6 gives c-6) at the merge commit
# and a release page of that name titled with the release pull request's title,
# whose notes carry that pull request's title and URL and those of every pull
# request merged into the release branch.
#
# Each release is also written to this home's release record, one line
# `<tag> <date> repo=<owner/name> commit=<sha> prs=<numbers>` in
# `${JG_DATA_OVERRIDE:-$JG_HOME/data}/releases`, which bin/jg-live-claim.sh
# reads to say a change is live; it is its only writer, appends once per
# repository and tag, and is skipped when the script has no home to write to.
#
# Guards:
#   - idempotent: an existing release page for the tag ends the pass;
#   - never force, delete or move a tag: a tag that exists without a page gets a
#     page for the commit it already names (--verify-tag);
#   - a repository that holds any tag not of the c-<N> form this script writes
#     keeps its own scheme: no second tag, and the tag it saw is logged;
#   - no GitHub remote, an unmerged pull request, or a non-release merge skips
#     with one line and exit 0. Exit 1 only when a needed gh write failed.
set -u

_JG_RELEASE_TAG_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/jg-pr-lib.sh
. "$_JG_RELEASE_TAG_DIR/jg-pr-lib.sh"

say() { printf 'release tag: %s\n' "$*"; }

# Append the release to the home's record once; `prs` is the comma list of the pull requests it carries.
record_release() {  # <tag> <commit> <prs>
  local file=${JG_DATA_OVERRIDE:-${JG_HOME:+$JG_HOME/data}}
  [ -n "$file" ] || return 0
  file=$file/releases
  mkdir -p "${file%/*}" || { say "cannot write the release record $file"; return 1; }
  awk -v t="$1" -v r="repo=$repo" '$1 == t { for (i = 2; i <= NF; i++) if ($i == r) found = 1 } END { exit found ? 0 : 1 }' "$file" 2>/dev/null && return 0
  printf '%s %s repo=%s commit=%s%s\n' "$1" "$(date -u +%Y-%m-%d)" "$repo" "$2" "${3:+ prs=$3}" >> "$file" \
    || { say "cannot write the release record $file"; return 1; }
}

# Pull requests merged into the release branch: `number<TAB>- title (url)` per line.
release_carried() {  # <release-branch>
  gh pr list --repo "$repo" --base "$1" --state merged --limit 200 \
    --json number,title,url --jq 'sort_by(.number) | .[] | "\(.number)\t- \(.title) (\(.url))"' 2>/dev/null
}
carried_numbers() {  # <release pr url> <carried lines> -> comma list
  { printf '%s\n' "${1##*/}"; printf '%s\n' "$2" | cut -f1; } | grep -E '^[0-9]+$' | sort -un | paste -sd, -
}

url=${1:-}
dir=${2:-}
[ -n "$url" ] || { echo "usage: jg-release-tag.sh <merged-pr-url> [<repo-dir>]" >&2; exit 2; }

if ! jg_pr_url_parse "$url" || [ "$JG_PR_PROVIDER" != github ]; then
  say "skipped, $url is not a GitHub pull request (no GitHub remote)"
  exit 0
fi
repo=$JG_PR_PATH
command -v gh >/dev/null 2>&1 || { say "skipped, gh is not installed"; exit 0; }

if [ -n "$dir" ] && { [ ! -d "$dir" ] \
  || [ -z "$(git -C "$dir" for-each-ref --count=1 --format=x 'refs/remotes/*/release/*' 'refs/heads/release/*' 2>/dev/null)" ]; }; then
  exit 0
fi

info=$(gh pr view "$url" --repo "$repo" --json state,baseRefName,headRefName,title,mergeCommit \
  --jq '[.state, .baseRefName, .headRefName, .title, (.mergeCommit.oid // "")] | @tsv' 2>/dev/null) || {
  say "skipped, cannot read $url"
  exit 0
}
IFS=$'\t' read -r state base head title sha <<EOF
$info
EOF
[ "$state" = MERGED ] || exit 0
case "$head" in
  release/*) tag=${head#release/} ;;
  *) exit 0 ;;
esac
case "$tag" in
  '' | */* | .* | *[!A-Za-z0-9._-]*) say "skipped, $head does not name a plain release tag"; exit 0 ;;
esac
default=$(gh repo view "$repo" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null) || default=
[ -n "$default" ] && [ "$base" = "$default" ] || exit 0
case "$sha" in
  *[!0-9a-f]* | '') say "skipped, $url has no readable merge commit"; exit 0 ;;
esac

if page=$(gh release view "$tag" --repo "$repo" --json url --jq .url 2>/dev/null) && [ -n "$page" ]; then
  carried=$(release_carried "$head") || carried=
  record_release "$tag" "$sha" "$(carried_numbers "$url" "$carried")"
  say "$tag already released, nothing to do: $page"
  exit 0
fi

tags=$(gh api -X GET "repos/$repo/tags" -f per_page=100 --jq '.[].name' 2>/dev/null) || {
  say "skipped, cannot read the tags of $repo"
  exit 1
}
foreign=$(printf '%s\n' "$tags" | grep -v -E '^(c-[0-9]+)?$' | head -1)
if [ -n "$foreign" ]; then
  say "skipped, $repo already tags its releases with its own scheme (found $foreign), so $tag is not added"
  exit 0
fi

pinned=--target
printf '%s\n' "$tags" | grep -qxF -- "$tag" && pinned=--verify-tag
carried=$(release_carried "$head") || carried=
included=$(printf '%s\n' "$carried" | cut -f2-)
notes="Release pull request: $title ($url)"
[ -z "$included" ] || notes="$notes

Included pull requests:
$included"

if [ "$pinned" = --target ]; then
  out=$(gh release create "$tag" --repo "$repo" --title "$title" --notes "$notes" --target "$sha" 2>&1)
else
  out=$(gh release create "$tag" --repo "$repo" --title "$title" --notes "$notes" --verify-tag 2>&1)
fi || {
  say "failed to create $tag on $repo: $out"
  exit 1
}
say "created $tag at $sha: $(printf '%s\n' "$out" | tail -1)"
record_release "$tag" "$sha" "$(carried_numbers "$url" "$carried")" || exit 1
