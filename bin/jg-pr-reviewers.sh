#!/usr/bin/env bash
# Suggest GitHub reviewers from recent authorship of a pull request's files.
#
# This is a read-only advisory command. It reads the pull request's exact file
# list, then the most recent 100 commits on its base commit for each path. A
# commit is counted once even when it touched multiple changed paths. Candidates
# use GitHub's own commit author.login mapping; names and email addresses are
# never converted or guessed. The pull-request author and Bot accounts are
# excluded. One API read is issued per changed path, so a wide pull request
# costs proportionally more reads and time.
#
# Usage: jg-pr-reviewers.sh <pr-url>
#   Prints candidates in descending unique-commit count as:
#     <github-login><tab><count> recent commit[s]
#   When no mapped author other than the pull-request author appears, prints no
#   candidate and explains that result. Lookup or usage refusal exits non-zero.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'jg-pr-reviewers: %s\n' "$*" >&2
  exit 2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || die "usage: jg-pr-reviewers.sh <pr-url>"
command -v gh >/dev/null 2>&1 || die "gh is required"

URL=$1
if ! jg_pr_url_parse "$URL" || [ "$JG_PR_PROVIDER" != github ]; then
  die "expected a GitHub pull-request URL"
fi

PATH_PART=$JG_PR_PATH
NUMBER=$JG_PR_NUMBER
ENDPOINT="/repos/$PATH_PART/pulls/$NUMBER"
CORE=$(gh api "$ENDPOINT" --jq '"author=\(.user.login)", "base=\(.base.sha)"') \
  || die "could not read $URL"
AUTHOR=
BASE=
while IFS= read -r row; do
  case "$row" in
    author=*) AUTHOR=${row#author=} ;;
    base=*) BASE=${row#base=} ;;
  esac
done <<EOF
$CORE
EOF
[ -n "$AUTHOR" ] && [ -n "$BASE" ] \
  || die "GitHub returned incomplete pull-request state for $URL"

FILES=$(gh api "$ENDPOINT/files?per_page=100" --paginate --jq '.[].filename') \
  || die "could not read changed files for $URL"
[ -n "$FILES" ] || {
  printf 'NO CANDIDATES: pull request changes no files\n'
  exit 0
}

EVIDENCE=$(mktemp "${TMPDIR:-/tmp}/jg-pr-reviewers.XXXXXX") \
  || die "could not create temporary evidence file"
trap 'rm -f "$EVIDENCE"' EXIT INT TERM

while IFS= read -r file; do
  ROWS=$(gh api --method GET "/repos/$PATH_PART/commits" \
    -f sha="$BASE" \
    -f path="$file" \
    -F per_page=100 \
    --jq '.[] | select(.author.type != "Bot") | [.sha, (.author.login // "")] | @tsv') \
    || die "could not read recent commits for $file"
  [ -z "$ROWS" ] || printf '%s\n' "$ROWS" >> "$EVIDENCE"
done <<EOF
$FILES
EOF

CANDIDATES=$(awk -F '\t' -v author="$AUTHOR" '
  $2 != "" && $2 != author {
    key = $1 SUBSEP $2
    if (!seen[key]++) count[$2]++
  }
  END {
    for (login in count)
      printf "%s\t%d recent commit%s\n", login, count[login], (count[login] == 1 ? "" : "s")
  }
' "$EVIDENCE" | LC_ALL=C sort -t $'\t' -k2,2nr -k1,1)

if [ -z "$CANDIDATES" ]; then
  printf 'NO CANDIDATES: no mapped author other than the PR author\n'
else
  printf '%s\n' "$CANDIDATES"
fi
