#!/usr/bin/env bash
# Report the blockers this command can see on one GitHub pull request.
#
# This is a one-shot, read-only command. It reads the current pull request,
# reported checks, submitted reviews, and review decision from GitHub at
# invocation time. It never posts, requests, approves, or merges.
# It reports on checks that have reported. A required context that has never
# reported on this head is absent from what this command reads and cannot be
# enumerated here. Empty output therefore means that no reported required check
# is failing or pending; it does not mean the pull request is ready to merge.
# When nothing has reported, or nothing required has, that is printed rather
# than read as ready. Advisory checks do not block and are omitted.
# A pull request that only awaits an approval (reviewDecision REVIEW_REQUIRED)
# is not reported as blocked. GitHub's reviewDecision owns whether reviews
# block; review history is printed only to explain CHANGES_REQUESTED, naming
# each reviewer whose latest verdict still requests changes and marking it
# STALE when it was left at a superseded head.
# A closed or merged pull request reports that terminal state and nothing else.
# Unresolved review-thread state is out of this command's scope.
#
# Usage: jg-pr-state.sh [--all] [--waiting-for] <pr-url>
#   Prints one line per blocker it can see and nothing when it sees none.
#   Blockers do not change the successful exit status; lookup or usage refusal
#   exits non-zero.
# --waiting-for prints exactly one `juggernaut/waiting-for: <what>` line naming
#   what the change is waiting on, and nothing when it is merged and nothing is
#   waited on. It is the line a captain-facing report carries for a pull request
#   still in flight, so a reader can tell a draft from conflicts from a red check
#   from the one thing left, the merge call itself. The verdict comes from the
#   same live reads as the blockers, in this order: a draft must be marked ready,
#   conflicts must be reconciled, a required check must pass, a required check
#   that has not reported must land, and otherwise the change waits only on the
#   merge call, which the lead makes within one cycle by rule.
# --all widens the check read from the required contexts to every reported check
# and prints each non-green one as `CHECK: <name> (<state>)`. It is what
# bin/jg-dod-lib.sh reads to refuse a `done:` while the pull request still has a
# red or unfinished check, so a lane fixes it or waits instead of reporting done
# early; the default stays required-only, because that is what blocks a merge.
# Advisory checks an ordinary run does not need are still omitted from the
# default read, and a skipping or cancelled check is reported by neither.
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
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
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
  printf 'jg-pr-state: %s\n' "$*" >&2
  exit 2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -ge 1 ] || die "usage: jg-pr-state.sh [--all] [--waiting-for] <pr-url>"
ALL=0
WAITING=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --waiting-for) WAITING=1; shift ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done
[ "$#" -eq 1 ] || die "usage: jg-pr-state.sh [--all] [--waiting-for] <pr-url>"
command -v gh >/dev/null 2>&1 || die "gh is required"

URL=$1
if ! jg_pr_url_parse "$URL" || [ "$JG_PR_PROVIDER" != github ]; then
  die "expected a GitHub pull-request URL"
fi

PATH_PART=$JG_PR_PATH
NUMBER=$JG_PR_NUMBER
ENDPOINT="/repos/$PATH_PART/pulls/$NUMBER"

CORE=$(gh pr view "$URL" \
  --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision --jq '
  "state=\(.state | ascii_downcase)",
  "merged_at=\(.mergedAt // "")",
  "draft=\(.isDraft)",
  "head=\(.headRefOid)",
  "author=\(.author.login)",
  "mergeability=\(if .mergeable == null or .mergeable == "UNKNOWN" then "unknown" else (.mergeable | ascii_downcase) end)",
  "review_decision=\(.reviewDecision // "")"') || die "could not read $URL"

STATE=
MERGED_AT=
DRAFT=
MERGEABILITY=
HEAD=
AUTHOR=
REVIEW_DECISION=
while IFS= read -r row; do
  case "$row" in
    state=*) STATE=${row#state=} ;;
    merged_at=*) MERGED_AT=${row#merged_at=} ;;
    draft=*) DRAFT=${row#draft=} ;;
    head=*) HEAD=${row#head=} ;;
    author=*) AUTHOR=${row#author=} ;;
    mergeability=*) MERGEABILITY=${row#mergeability=} ;;
    review_decision=*) REVIEW_DECISION=${row#review_decision=} ;;
  esac
done <<EOF_CORE
$CORE
EOF_CORE
[ -n "$STATE" ] && [ -n "$DRAFT" ] && [ -n "$HEAD" ] && [ -n "$AUTHOR" ] \
  && [ -n "$MERGEABILITY" ] \
  || die "GitHub returned incomplete pull-request state for $URL"

WAIT_DRAFT=
WAIT_CONFLICT=
if [ -n "$MERGED_AT" ]; then
  [ "$WAITING" = 1 ] || printf 'STATE: merged at %s\n' "$MERGED_AT"
  exit 0
elif [ "$STATE" != open ]; then
  if [ "$WAITING" = 1 ]; then
    printf 'juggernaut/waiting-for: nothing; the change is %s\n' "$STATE"
  else
    printf 'STATE: %s\n' "$STATE"
  fi
  exit 0
fi
if [ "$DRAFT" != false ]; then
  [ "$WAITING" = 1 ] || printf 'DRAFT: pull request is not ready for review\n'
  WAIT_DRAFT='the pull request is a draft, so it needs to be marked ready for review'
fi
case "$MERGEABILITY" in
  mergeable) ;;
  unknown) [ "$WAITING" = 1 ] || printf 'MERGEABILITY: unknown\n' ;;
  conflicting)
    [ "$WAITING" = 1 ] || printf 'MERGEABILITY: conflicting\n'
    WAIT_CONFLICT='merge conflicts, which someone has to reconcile'
    ;;
  *) die "GitHub returned invalid mergeability for $URL" ;;
esac

GH_STDERR=$(mktemp "${TMPDIR:-/tmp}/jg-pr-state.XXXXXX") \
  || die "could not create temporary file"
trap 'rm -f "$GH_STDERR"' EXIT INT TERM
if [ "$ALL" = 1 ]; then
  CHECK_SCOPE=''
  CHECK_JQ='.[] | select(.bucket == "fail" or .bucket == "pending") | "CHECK: \(.name) (\(.state))"'
  CHECK_DIE="could not read checks for $URL"
else
  CHECK_SCOPE=--required
  CHECK_JQ='.[]
  | select(.bucket != "pass" and .bucket != "skipping")
  | "REQUIRED CHECK: \(.name) (\(.state))"'
  CHECK_DIE="could not read required checks for $URL"
fi
# shellcheck disable=SC2086  # CHECK_SCOPE is the flag or nothing, never one word.
if ! REQUIRED=$(gh pr checks "$URL" $CHECK_SCOPE --json name,state,bucket --jq "$CHECK_JQ" 2>"$GH_STDERR"); then
  # These two sentences are gh's own human-readable error text, verified against
  # gh 2.100.0 on 2026-09-12. gh reports "nothing reported" as an error rather
  # than as structured data, so matching its text is the only way to tell that
  # apart from a real lookup failure. An unrecognised message falls through to
  # the refusal below, so a reword degrades loudly rather than silently.
  if grep -q "^no checks reported on the '" "$GH_STDERR"; then
    REQUIRED="CHECKS: none reported yet"
  elif grep -q "^no required checks reported on the '" "$GH_STDERR"; then
    REQUIRED="CHECKS: no required check has reported; readiness unconfirmed"
  else
    cat "$GH_STDERR" >&2
    die "$CHECK_DIE"
  fi
fi
if [ "$WAITING" = 1 ]; then
  # One line, one named wait, highest priority first: the reasons the blockers
  # name, reduced to the single one a captain-facing report can carry.
  WAIT_REASON='the merge call: the required checks are green, and the lead merges within one cycle by rule'
  case "$REQUIRED" in
    *'REQUIRED CHECK:'*)
      WAIT_CHECKS=$(printf '%s\n' "$REQUIRED" | sed -n 's/^REQUIRED CHECK: //p' | head -n 1)
      WAIT_CHECKS=${WAIT_CHECKS%% (*}
      WAIT_REASON="a required check is not passing: $WAIT_CHECKS"
      ;;
    *'CHECKS: '*) WAIT_REASON='the required checks have not reported yet' ;;
  esac
  [ -z "$WAIT_DRAFT" ] || WAIT_REASON=$WAIT_DRAFT
  [ -z "$WAIT_CONFLICT" ] || WAIT_REASON=$WAIT_CONFLICT
  printf 'juggernaut/waiting-for: %s\n' "$WAIT_REASON"
  exit 0
fi
[ -z "$REQUIRED" ] || printf '%s\n' "$REQUIRED"

if [ "$REVIEW_DECISION" = CHANGES_REQUESTED ]; then
  printf 'REVIEW DECISION: CHANGES_REQUESTED\n'
  REVIEWS=$(gh api "$ENDPOINT/reviews?per_page=100" --paginate --jq '
    .[]
    | select(.user.login != null and .commit_id != null and .submitted_at != null)
    | [.user.login, .state, .commit_id, .submitted_at]
    | @tsv') || die "could not read reviews for $URL"
  printf '%s\n' "$REVIEWS" | awk -F '\t' -v author="$AUTHOR" -v head="$HEAD" '
    NF == 4 && $1 != author && $2 != "COMMENTED" && (!seen[$1] || $4 >= latest[$1]) {
      seen[$1] = 1
      latest[$1] = $4
      state[$1] = $2
      commit[$1] = $3
    }
    END {
      for (reviewer in state) {
        if (state[reviewer] != "CHANGES_REQUESTED") continue
        if (commit[reviewer] == head)
          printf "REVIEW: %s CHANGES_REQUESTED\n", reviewer
        else
          printf "STALE BLOCKING REVIEW: %s CHANGES_REQUESTED at %s\n", \
            reviewer, commit[reviewer]
      }
    }' | LC_ALL=C sort
fi
