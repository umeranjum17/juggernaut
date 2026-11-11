#!/usr/bin/env bash
# Run the full local suite in a task's own lane worktree at its pull request's
# exact head, seal the run, and write the receipt the merge gate accepts.
#
# Usage: jg-local-suite.sh <task-id> <PR URL>
#        jg-local-suite.sh <task-id> --lane
#        jg-local-suite.sh verify <state-dir> <task-id> <head> [<owner> <repo>]
#        jg-local-suite.sh --help
#
# This is slice 1 of the captain's local-proof merge: a merge stops waiting for a
# GitHub queue when the work itself is proven here. The suite is the one CI runs,
# bin/jg-test-run.sh --all --gate followed by bin/jg-lint.sh, in the task's lane
# worktree at the commit the pull request holds. The runner's --gate contract
# bounds it: a test over its per-test speed limit is reported, and the whole gate
# is held to the configured budget from defaults/test-speed-limits.
#
# The receipt is state/<task>.local-suite, a plain key=value record like every
# other durable record in a home, so it needs no JSON reader. It names the tree
# it proved as well as the head it ran at, the suite's exit code, its start and
# end epoch, its wall clock and shard count, and its log path. Its last line is a
# sha256 over the lines above it, so a receipt edited after the run no longer
# verifies: an accident detector, not a security boundary, because one user can
# write both the record and its seal.
#
# The proof is keyed to the TREE, not the head. A run at one commit proves a
# second commit whenever both carry the same tree, so a body edit, a re-push of
# identical content, a squash of the same change, or a base merge that does not
# change the files the suite read never forces a re-seal: the receipt already
# names that tree. The head stays in the record as the run's own address.
#
# `verify` is the check bin/jg-pr-merge.sh runs against the live pull request
# head, and its exit status is its whole answer: 0 with one evidence line on
# stdout when the receipt proves that exact tree with exit 0, 1 with the reason
# on stderr when a receipt exists but does not prove it, and 3 when no receipt
# exists at all, which leaves the ordinary forge-check gate in charge. A receipt
# that exists is never ignored, so a stale one refuses by name instead of
# quietly turning back into a CI wait. The candidate tree comes from the local
# object store when this copy has the commit, and from the forge
# (`gh api .../commits/<head>`) when it does not; with neither readable it
# refuses rather than guessing. The optional owner and repo arguments name the
# forge repository for that read when the caller already parsed them out of the
# pull request URL.
#
# Run refusals, all before anything executes: no recorded lane worktree, a
# non-GitHub change, an unreadable forge head, a worktree HEAD that is not that
# head, and a worktree with uncommitted changes the merge would never land. A
# failing run still writes its receipt with the nonzero exit, so the gate refuses
# it by name. The last line printed carries the wall clock, the shard count and
# the head proved, and on success the same facts are appended to the pull
# request body so a reviewer reads the proof on the pull request itself.
# Sharding and caching are slice 2; this slice always records one shard.
#
# `--lane` is the same run for a local-trunk lane, which has no pull request: the lane's one commit sits on the trunk tip, so
# its base is HEAD^ (a merge commit has no single base, so nothing is set aside), and no pull request body is read or written.
# Run it as the sealed command (`done-done run -- bin/jg-local-suite.sh <task-id> --lane`); the set-aside scripts are printed
# on its output and recorded in the receipt.
#
# A test that is red without the change never blocks the proof. When the runner fails and lint is clean, each red script is
# run again on the pull request's base (origin/<base branch>, or HEAD^ for a lane, exported with git archive, never checked out) and compared by
# jg_dod_baseline_split in bin/jg-dod-lib.sh: a red is set aside only when the base fails the same script with the same exit
# and the same case names. A new case, a different exit, a script the base passes, a failure no script accounts for, an unreadable
# base or a lint finding is still the lane's red and the receipt keeps the failing exit. A receipt that set a red aside records
# tip_red=<scripts>, inside the seal, and `verify` names those scripts on its evidence line.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
# shellcheck source=bin/jg-dod-lib.sh
. "$SCRIPT_DIR/jg-dod-lib.sh"

usage() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d'
}

# One receipt field, last occurrence, empty when absent.
receipt_field() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

receipt_seal_of() {  # <file-without-its-seal-line>
  if command -v shasum >/dev/null 2>&1; then
    sed '/^seal=/d' "$1" | shasum -a 256 | awk '{print $1}'
  else
    sed '/^seal=/d' "$1" | sha256sum | awk '{print $1}'
  fi
}

# Republish the receipt with a fresh seal over exactly the given facts; <tip_red> is empty unless a red was set aside.
receipt_seal() {  # <file> <task> <head> <tree> <exit> <started> <ended> <wall> <shards> <log> [<tip_red>]
  local file=$1 tmp="$1.$$"
  {
    printf 'schema=1\n'
    printf 'task=%s\n' "$2"
    printf 'head=%s\n' "$3"
    printf 'tree=%s\n' "$4"
    printf 'suite=jg-test-run --all + jg-lint\n'
    printf 'exit=%s\n' "$5"
    printf 'started_at=%s\n' "$6"
    printf 'ended_at=%s\n' "$7"
    printf 'wall_seconds=%s\n' "$8"
    printf 'shards=%s\n' "$9"
    printf 'log=%s\n' "${10}"
    [ -z "${11:-}" ] || printf 'tip_red=%s\n' "${11}"
  } > "$tmp" || return 1
  printf 'seal=sha256:%s\n' "$(receipt_seal_of "$tmp")" >> "$tmp" || return 1
  mv -f "$tmp" "$file"
}

# The tree a commit carries: from this copy's object store when it has the
# commit, else from the forge. Empty with a nonzero status when neither read
# works, which verify reports rather than comparing nothing.
tree_of_head() {  # <head> [<owner>] [<repo>]
  local head=$1 owner=${2:-} repo=${3:-} tree
  if tree=$(git rev-parse -q --verify "$head^{tree}" 2>/dev/null) && [ -n "$tree" ]; then
    printf '%s\n' "$tree"
    return 0
  fi
  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  tree=$(gh api "repos/$owner/$repo/commits/$head" --jq '.commit.tree.sha' 2>/dev/null) || return 1
  [ -n "$tree" ] || return 1
  printf '%s\n' "$tree"
}

verify_receipt() {  # <state-dir> <task-id> <candidate-head> [<owner> <repo>]
  local file head tree recorded candidate_tree rc wall shards log aside
  file="$1/$2.local-suite"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    echo "no local suite receipt for $2, so the forge check gate applies" >&2
    return 3
  fi
  if [ ! -f "$file" ] || [ -L "$file" ] || [ "$(receipt_field "$file" schema)" != 1 ]; then
    echo "the local suite receipt at $file is not a sealed schema 1 record" >&2
    return 1
  fi
  if [ "$(receipt_field "$file" task)" != "$2" ]; then
    echo "the local suite receipt at $file belongs to task $(receipt_field "$file" task), not $2" >&2
    return 1
  fi
  recorded=$(receipt_field "$file" seal)
  if [ "$recorded" != "sha256:$(receipt_seal_of "$file")" ]; then
    echo "the local suite receipt at $file was edited after its run, so its seal does not verify" >&2
    return 1
  fi
  head=$(receipt_field "$file" head)
  tree=$(receipt_field "$file" tree)
  if [ -n "$tree" ]; then
    # Tree-keyed: the receipt proves the files the suite read, so the same tree
    # under another commit is the same proof and never needs a re-seal.
    if ! candidate_tree=$(tree_of_head "$3" "${4:-}" "${5:-}"); then
      echo "could not read the tree of head $3 from this copy or the forge, so the local suite receipt for tree $tree cannot be checked against it" >&2
      return 1
    fi
    if [ "$candidate_tree" != "$tree" ]; then
      echo "the local suite receipt proves tree $tree, not the tree $candidate_tree of head $3" >&2
      return 1
    fi
  elif [ -z "$head" ] || [ "$head" != "$3" ]; then
    echo "the local suite receipt proves head ${head:-nothing}, not the pull request head $3" >&2
    return 1
  fi
  rc=$(receipt_field "$file" exit)
  if [ "$rc" != 0 ]; then
    echo "the local suite run at head ${head:-unknown} exited ${rc:-unrecorded}, not 0" >&2
    return 1
  fi
  wall=$(receipt_field "$file" wall_seconds)
  shards=$(receipt_field "$file" shards)
  log=$(receipt_field "$file" log)
  aside=$(receipt_field "$file" tip_red)
  printf 'local suite %ss, %s shard(s), tree %s, log %s%s\n' "$wall" "$shards" "${tree:-unrecorded}" "$log" \
    "${aside:+, red on the base the same way and set aside: $aside}"
}

# The commit a change's reds are compared against: the pull request's base branch, or a lane's parent commit.
base_commit_of() {  # <worktree> <PR URL, or empty for a lane>
  local base
  if [ -z "$2" ]; then
    git -C "$1" rev-parse -q --verify "HEAD^{commit}" >/dev/null 2>&1 && ! git -C "$1" rev-parse -q --verify "HEAD^2" >/dev/null 2>&1 \
      && git -C "$1" rev-parse -q --verify "HEAD^1^{commit}" 2>/dev/null
    return
  fi
  base=$(gh pr view "$2" --json baseRefName -q .baseRefName 2>/dev/null) && [ -n "$base" ] || return 1
  git -C "$1" rev-parse -q --verify "origin/$base^{commit}" 2>/dev/null
}

# The red scripts of a failed run that the base fails the same way: runs only those scripts on the base's
# exported tree and prints the set-aside ones, space-separated. Prints nothing (and returns 1) when any red is the lane's own.
base_red_set_aside() {  # <worktree> <run log> <PR URL, or empty for a lane> <failed-script-count-from-the-runner>
  local wt=$1 log=$2 commit dir blog mine reds base_res split charged aside n_red
  mine=$(jg_dod_test_results "$log" | awk -F'\t' '$2 != "0"')
  reds=$(printf '%s\n' "$mine" | cut -f1 | grep -c . || true)
  # A failure no script accounts for (a runner that died, a check before it) is never set aside.
  [ "$reds" -gt 0 ] && [ "$reds" = "$4" ] || return 1
  commit=$(base_commit_of "$wt" "$3") || return 1
  dir=$(mktemp -d "$DATA/jg-local-suite/.base.XXXXXX") || return 1
  blog="$dir.log"
  if git -C "$wt" archive "$commit" | tar -x -C "$dir" 2>/dev/null && [ -x "$dir/bin/jg-test-run.sh" ]; then
    # shellcheck disable=SC2046
    ( cd "$dir" && "$dir/bin/jg-test-run.sh" $(printf '%s\n' "$mine" | cut -f1) ) >"$blog" 2>&1 || :
  fi
  rm -rf -- "$dir"
  base_res=$(jg_dod_test_results "$blog" 2>/dev/null) || base_res=''
  rm -f -- "$blog"
  split=$(jg_dod_baseline_split "$mine" "$base_res")
  charged=$(printf '%s\n' "$split" | sed -n 's/^charged //p')
  aside=$(printf '%s\n' "$split" | sed -n 's/^aside //p' | paste -sd' ' -)
  n_red=$(printf '%s\n' "$split" | grep -c . || true)
  [ -z "$charged" ] && [ -n "$aside" ] && [ "$n_red" = "$reds" ] || return 1
  printf '%s\n' "$aside"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  verify)
    if [ "$#" -lt 4 ] || [ "$#" -gt 6 ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
      echo "error: verify needs <state-dir> <task-id> <head> [<owner> <repo>]" >&2
      exit 2
    fi
    verify_receipt "$2" "$3" "$4" "${5:-}" "${6:-}"
    exit $?
    ;;
esac

# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"

LANE=0
[ "${2:-}" != --lane ] || LANE=1
if [ "$#" -ne 2 ] || ! jg_pr_task_id_valid "$1" || { [ "$LANE" = 0 ] && ! jg_pr_url_parse "$2"; }; then
  echo "error: invalid local suite request: expected <task-id> <PR URL> or <task-id> --lane; run --help" >&2
  exit 2
fi
ID=$1
URL=''
[ "$LANE" = 1 ] || URL=$JG_PR_URL
if [ "$LANE" = 0 ] && [ "$JG_PR_PROVIDER" != github ]; then
  echo "error: this receipt proves a GitHub pull request head; $URL is a $JG_PR_PROVIDER change, whose merge already requires its own head status" >&2
  exit 2
fi

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no task record at $META" >&2; exit 1; }
WORKTREE=$(sed -n 's/^worktree=//p' "$META" | tail -n 1)
if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "error: task $ID has no recorded lane worktree to prove; run this in the task's own lane" >&2
  exit 1
fi
if ! LOCAL_HEAD=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null); then
  echo "error: $WORKTREE is not a git worktree" >&2
  exit 1
fi
if [ "$LANE" = 1 ]; then
  HEAD=$LOCAL_HEAD
elif ! HEAD=$(gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) || [ -z "$HEAD" ]; then
  echo "error: could not read the head commit of $URL" >&2
  exit 1
fi
if [ "$LOCAL_HEAD" != "$HEAD" ]; then
  echo "error: the lane worktree at $WORKTREE is at $LOCAL_HEAD, not the pull request head $HEAD; fetch and check out that commit first" >&2
  exit 1
fi
if [ -n "$(git -C "$WORKTREE" status --porcelain 2>/dev/null)" ]; then
  echo "error: the lane worktree at $WORKTREE has uncommitted changes; the suite would test work the merge never lands" >&2
  exit 1
fi
for runner in bin/jg-test-run.sh bin/jg-lint.sh; do
  [ -f "$WORKTREE/$runner" ] || { echo "error: the lane worktree has no $runner; nothing to run" >&2; exit 1; }
done

LOG_DIR="$DATA/jg-local-suite"
mkdir -p "$LOG_DIR"
SHORT=${HEAD%"${HEAD#????????????}"}
STARTED=$(date +%s)
LOG="$LOG_DIR/$ID-$SHORT-$STARTED.log"
JSON="$LOG_DIR/$ID-$SHORT-$STARTED.json"
SHARDS=1

RC=0
TEST_RC=0
LINT_RC=0
# --gate is the gate contract this receipt stands for: the per-test speed
# limits enforced, and the whole gate bounded by the configured budget, so a
# hung or overrunning test fails the receipt instead of holding the gate.
( cd "$WORKTREE" && "$WORKTREE/bin/jg-test-run.sh" --all --gate --json "$JSON" ) >"$LOG" 2>&1 || TEST_RC=$?
( cd "$WORKTREE" && "$WORKTREE/bin/jg-lint.sh" ) >>"$LOG" 2>&1 || LINT_RC=$?
TIP_RED=''
if [ "$LINT_RC" -ne 0 ]; then
  RC=$LINT_RC
elif [ "$TEST_RC" -ne 0 ]; then
  RC=$TEST_RC
  RUNNER_FAILED=$(sed -n 's/^JG_TEST_SUMMARY .* failed=\([0-9][0-9]*\) .*/\1/p' "$LOG" | awk '{ n += $1 } END { print n + 0 }')
  if TIP_RED=$(base_red_set_aside "$WORKTREE" "$LOG" "$URL" "$RUNNER_FAILED"); then
    RC=0
    echo "note: the base fails only what the pull request fails the same way, so set aside, not charged: $TIP_RED" >&2
  else
    TIP_RED=''
  fi
fi
ENDED=$(date +%s)
WALL=$((ENDED - STARTED))

RECEIPT="$STATE/$ID.local-suite"
TREE=$(git -C "$WORKTREE" rev-parse "$HEAD^{tree}" 2>/dev/null) \
  || { echo "error: could not read the tree of $HEAD in $WORKTREE" >&2; exit 1; }
receipt_seal "$RECEIPT" "$ID" "$HEAD" "$TREE" "$RC" "$STARTED" "$ENDED" "$WALL" "$SHARDS" "$LOG" "$TIP_RED"

[ "$RC" -ne 0 ] || [ -z "$TIP_RED" ] || [ "$LANE" = 0 ] || echo "local-suite: set aside, red on the base the same way: $TIP_RED"
if [ "$RC" -eq 0 ] && [ "$LANE" = 0 ]; then
  # Publish the proof where a reviewer reads it; a body update that fails is
  # reported and never changes the receipt, which is the gate's own evidence.
  BODY_TMP="$LOG_DIR/$ID-body.$$"
  if gh pr view "$URL" --json body -q .body 2>/dev/null | grep -v '^Local suite: ' > "$BODY_TMP" \
    && printf 'Local suite: %ss, %s shard(s), head %s, exit 0.\n' "$WALL" "$SHARDS" "$HEAD" >> "$BODY_TMP" \
    && gh pr edit "$URL" --body-file "$BODY_TMP" >/dev/null 2>&1; then
    :
  else
    echo "note: the local suite passed but its proof line could not be added to the pull request body" >&2
  fi
  rm -f "$BODY_TMP"
fi

printf 'local-suite: exit=%s wall=%ss shards=%s head=%s tree=%s receipt=%s log=%s\n' \
  "$RC" "$WALL" "$SHARDS" "$HEAD" "$TREE" "$RECEIPT" "$LOG"
[ "$RC" -eq 0 ] || exit "$RC"
