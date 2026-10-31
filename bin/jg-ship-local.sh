#!/usr/bin/env bash
# Ship one task locally: push its lane branch, prove that exact head with the
# local suite, merge through the one guarded merge path, then sync every home.
#
# Usage: jg-ship-local.sh <task-id> <PR URL>
#        jg-ship-local.sh --help
#
# This is the one command that turns a task's finished lane into a landed merge
# without waiting for the cloud queue, and it prints the wall clock of every
# stage so a reader sees real numbers rather than a promise.
#
# The stages run in this order, and a failed stage stops the rest:
#   push   Push the task's lane branch to origin, then read the pull request head
#          back from the forge and require it to be the lane's own HEAD. A push
#          that did not move the forge head means the suite would prove a commit
#          nobody merged, so the run refuses there.
#   suite  bin/jg-local-suite.sh runs the local suite at that exact head and
#          seals state/<task>.local-suite. That sealed receipt is what the merge
#          gate accepts in place of the cloud checks.
#   merge  bin/jg-pr-merge.sh, the one guarded merge path, merges on that receipt.
#          Its refusals are its own: this script prints them and stops rather
#          than merging around them.
#   sync   bin/jg-update.sh fast-forwards the main home and every lead home
#          through the guarded update path, never forcing and never stashing.
#          One synced-home line then names the commit each home ends on.
#
# Refusals before any side effect: a malformed request, a change that is not a
# GitHub pull request (the push and the head read are GitHub-shaped here), no
# recorded lane worktree for the task, a lane worktree with uncommitted changes,
# a detached lane, and a lane branch that is the repository default branch.
# Exit status is 0 only when every stage succeeded; otherwise it is the failing
# stage's own status, and the summary names the stage that stopped the run.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"

usage() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"

if [ "$#" -ne 2 ] || ! jg_pr_task_id_valid "$1" || ! jg_pr_url_parse "$2"; then
  echo "error: expected <task-id> <PR URL>; run --help" >&2
  exit 2
fi
ID=$1
URL=$JG_PR_URL
if [ "$JG_PR_PROVIDER" != github ]; then
  echo "error: this command pushes a git lane and reads a GitHub pull request head; $URL is a $JG_PR_PROVIDER change" >&2
  exit 2
fi

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no task record at $META" >&2; exit 1; }
WT=$(sed -n 's/^worktree=//p' "$META" | tail -n 1)
[ -n "$WT" ] && [ -d "$WT" ] || { echo "error: task $ID has no recorded lane worktree, so there is nothing to ship" >&2; exit 1; }
BRANCH=$(sed -n 's/^branch=//p' "$META" | tail -n 1)
if [ -z "$BRANCH" ]; then
  BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH=
fi
case $BRANCH in
  ''|HEAD)
    echo "error: the lane worktree at $WT is on no branch, so there is no lane branch to push" >&2
    exit 1 ;;
  main|master)
    echo "error: the lane branch reads '$BRANCH', the repository default branch; this command never pushes to it" >&2
    exit 1 ;;
esac
git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "error: $WT is not a git worktree" >&2; exit 1; }
[ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ] \
  || { echo "error: the lane worktree at $WT has uncommitted changes; commit them on the lane branch first, because the suite would otherwise prove work the merge never lands" >&2; exit 1; }
for stage_cmd in jg-local-suite.sh jg-pr-merge.sh jg-update.sh; do
  [ -x "$SCRIPT_DIR/$stage_cmd" ] || { echo "error: $SCRIPT_DIR/$stage_cmd is missing, so stage ${stage_cmd#jg-} cannot run" >&2; exit 1; }
done
command -v gh >/dev/null 2>&1 || { echo "error: gh is required to read the pull request head" >&2; exit 1; }

LOG_DIR="$DATA/jg-ship-local"
mkdir -p "$LOG_DIR" || exit 1
STARTED=$(date +%s)
stage_start=0
stage_wall=0
stage_begin() { stage_start=$(date +%s); }
stage_end() { stage_wall=$(( $(date +%s) - stage_start )); }
elapsed() { printf '%s' "$(( $(date +%s) - STARTED ))"; }

# A stage refuses by printing its own reason, so run it and keep the status.
run_stage() {  # <log> <command...>
  local log=$1 rc=0
  shift
  stage_begin
  "$@" >"$log" 2>&1 || rc=$?
  stage_end
  return $rc
}

# --- stage: push ------------------------------------------------------------
PUSH_LOG="$LOG_DIR/$ID-push.log"
if ! run_stage "$PUSH_LOG" git -C "$WT" push --quiet origin "HEAD:refs/heads/$BRANCH"; then
  printf 'ship-local: stage=push failed wall=%ss branch=%s log=%s\n' "$stage_wall" "$BRANCH" "$PUSH_LOG"
  sed -n '1,20p' "$PUSH_LOG" >&2 || true
  exit 1
fi
LOCAL_HEAD=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || LOCAL_HEAD=
LIVE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) || LIVE_HEAD=
if [ -z "$LIVE_HEAD" ]; then
  printf 'ship-local: stage=push failed wall=%ss: could not read the pull request head from the forge\n' "$stage_wall"
  exit 1
fi
if [ "$LIVE_HEAD" != "$LOCAL_HEAD" ]; then
  printf 'ship-local: stage=push failed wall=%ss: the pull request head is %s and the lane HEAD is %s, so the suite would prove a commit this pull request does not hold\n' \
    "$stage_wall" "${LIVE_HEAD:-nothing}" "${LOCAL_HEAD:-nothing}"
  exit 1
fi
PUSH_WALL=$stage_wall
printf 'ship-local: stage=push wall=%ss branch=%s head=%s\n' "$PUSH_WALL" "$BRANCH" "$LOCAL_HEAD"

# --- stage: suite -----------------------------------------------------------
SUITE_LOG="$LOG_DIR/$ID-suite.log"
if ! run_stage "$SUITE_LOG" "$SCRIPT_DIR/jg-local-suite.sh" "$ID" "$URL"; then
  printf 'ship-local: stage=suite failed wall=%ss head=%s log=%s\n' "$stage_wall" "$LOCAL_HEAD" "$SUITE_LOG"
  tail -n 20 "$SUITE_LOG" >&2 || true
  exit 1
fi
SUITE_WALL=$stage_wall
printf 'ship-local: stage=suite wall=%ss head=%s seal=%s\n' \
  "$SUITE_WALL" "$LOCAL_HEAD" "$(sed -n 's/^seal=//p' "$STATE/$ID.local-suite" 2>/dev/null | tail -n 1)"

# --- stage: merge -----------------------------------------------------------
MERGE_LOG="$LOG_DIR/$ID-merge.log"
MERGE_RC=0
run_stage "$MERGE_LOG" "$SCRIPT_DIR/jg-pr-merge.sh" "$ID" "$URL" || MERGE_RC=$?
if [ "$MERGE_RC" -ne 0 ]; then
  printf 'ship-local: stage=merge failed wall=%ss rc=%s head=%s log=%s\n' \
    "$stage_wall" "$MERGE_RC" "$LOCAL_HEAD" "$MERGE_LOG"
  tail -n 20 "$MERGE_LOG" >&2 || true
  printf 'ship-local: stopped at merge after %ss; nothing was synced\n' "$(elapsed)"
  exit "$MERGE_RC"
fi
MERGED_HEAD=$(sed -n 's/^pr_head=//p' "$META" 2>/dev/null | tail -n 1)
[ -n "$MERGED_HEAD" ] || MERGED_HEAD=$LOCAL_HEAD
MERGE_WALL=$stage_wall
printf 'ship-local: stage=merge wall=%ss head=%s\n' "$MERGE_WALL" "$MERGED_HEAD"

# --- stage: sync ------------------------------------------------------------
# One synced-home line per home the guarded update path leaves in place: this
# home's own checkout, then every lead home recorded here with a local path.
# A remote lead home is named with no commit, because its checkout is on another
# host and the update output above is the only honest record of it.
SYNC_LOG="$LOG_DIR/$ID-sync.log"
SYNC_RC=0
run_stage "$SYNC_LOG" "$SCRIPT_DIR/jg-update.sh" || SYNC_RC=$?
SYNC_WALL=$stage_wall
printf 'ship-local: stage=sync wall=%ss rc=%s log=%s\n' "$SYNC_WALL" "$SYNC_RC" "$SYNC_LOG"
sed -n '1,40p' "$SYNC_LOG" || true
printf 'synced-home: juggernaut %s\n' "$(git -C "$JG_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
for lead_meta in "$STATE"/*.meta; do
  [ -f "$lead_meta" ] || continue
  grep -qx 'kind=squad_lead' "$lead_meta" 2>/dev/null || continue
  lead_id=$(basename "$lead_meta" .meta)
  lead_home=$(sed -n 's/^home=//p' "$lead_meta" | tail -n 1)
  [ -n "$lead_home" ] || { printf 'synced-home: %s recorded-without-home\n' "$lead_id"; continue; }
  if git -C "$lead_home" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'synced-home: %s %s\n' "$lead_id" "$(git -C "$lead_home" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  else
    printf 'synced-home: %s remote (see the update output above)\n' "$lead_id"
  fi
done

if [ "$SYNC_RC" -ne 0 ]; then
  printf 'ship-local: merged %s but the sync reported errors (rc=%s); the merge stands and the homes need a run of bin/jg-update.sh\n' \
    "$MERGED_HEAD" "$SYNC_RC"
  exit "$SYNC_RC"
fi
printf 'ship-local: merged %s; push %ss + suite %ss + merge %ss + sync %ss = %ss total\n' \
  "$MERGED_HEAD" "$PUSH_WALL" "$SUITE_WALL" "$MERGE_WALL" "$SYNC_WALL" "$(elapsed)"
