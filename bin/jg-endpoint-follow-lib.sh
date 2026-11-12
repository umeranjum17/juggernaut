#!/usr/bin/env bash
# jg-endpoint-follow-lib.sh - the single owner of how a task record follows its
# worker when the worker's Herdr pane is replaced by a muxr account move.
#
# Why this exists. `muxr accounts move <agent> <account>` (and the same move
# from a phone) carries the worker's conversation onto another Claude account
# in a NEW pane of the same tab, then closes the old pane. Juggernaut kept
# tracking the closed pane, so crew-state read "backend target gone" for a
# worker that was running, and the fleet needed a hand edit of window= after
# every move. This library makes the record follow the worker.
#
# Design: follow an outside move, never own one. A move starts in muxr (Main's
# shell, the phone), which Juggernaut cannot intercept, so the only repair that
# covers every move is a reconcile that finds the worker again. A
# `jg-control move-account` verb would still leave those moves unfollowed, and
# would call this same reconcile afterwards.
#
# Identity. The recorded pane is the only thing a move changes, so the worker
# is found again by what a move does not change, both required together:
#   - the Herdr agent name pinned from the record's agent_name= (a record with
#     none: the name made from the task id) (bin/backends/herdr.sh,
#     jg_backend_herdr_moved_agent), and
#   - its working folder, which must be the task's worktree or a folder below.
# The worker is followed only when ALL of these hold; anything else is no move,
# and a worker that is really gone keeps reading gone:
#   1. the task is a local Herdr task with a valid record (the shared endpoint
#      validation, bin/jg-backend.sh);
#   2. Herdr answers pane_not_found for the RECORDED pane (a live pane is never
#      moved off, and an unreadable Herdr is not a move);
#   3. exactly one agent in that session has the task's name and works in the
#      task's worktree, in a different pane;
#   4. that pane's agent is positively live (the same classifier every other
#      reader uses);
#   5. no other task record in this state directory already names that pane.
#
# What changes, under the task's record lock, in one atomic publish: window=,
# herdr_workspace_id=, herdr_tab_id=, herdr_pane_id=, and account= when the
# record already names a pool account (see below). Every other line, the local
# copy, the branch, and every pin file are untouched. The record is validated
# again before it replaces the old one.
#
# account=. muxr says which account the moved agent runs on (`muxr pane
# account`). The record's account= is rewritten to that id only when the record
# already holds a pool account id. `ordinary` and an absolute path declare the
# home's worker pin, which only the captain changes, so they are kept as they
# are; an absent line stays absent, because adding one would enrol a worker in
# quota failover that never was. A muxr that is missing, slow or unsure never
# blocks the pane repair: the account line is simply left as it was.
#
# Usage (sourced): jg_endpoint_follow <meta-file> <task-id> <state-dir>
#   0  the record was rebound; one line goes to stderr naming the old and new
#      endpoint
#   1  nothing was changed (not a move, not provable, or the lock was busy);
#      callers re-read the record either way, because another reader may have
#      repaired it first.
# Environment: JG_ENDPOINT_FOLLOW_MUXR_SECONDS bounds the muxr read (default 10).

# The sourcing script loads bin/jg-backend.sh and bin/jg-timeout-lib.sh first;
# this library loads the Herdr adapter, the wake lib (locks) and the backlog
# transition lib (the atomic publish) itself, and only when a repair happens.

# jg_endpoint_follow_pool_account <pane>: the muxr account id the agent in
# <pane> runs on, or nothing (returns 1) when it cannot be read exactly.
jg_endpoint_follow_pool_account() {
  local pane=$1 out id
  command -v muxr >/dev/null 2>&1 || return 1
  out=$(jg_run_timed "${JG_ENDPOINT_FOLLOW_MUXR_SECONDS:-10}" muxr pane account --pane "$pane" --json 2>/dev/null) || return 1
  id=$(printf '%s' "$out" | jq -r --arg pane "$pane" 'select(.pane == $pane) | .account.id // empty' 2>/dev/null) || return 1
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s' "$id"
}

# jg_endpoint_follow_rewrite <meta> <tmp> <window> <workspace> <tab> <pane> [<account>]:
# write <tmp> as <meta> with the endpoint lines (and account=, when given)
# replaced in place. Every other line is copied byte for byte.
jg_endpoint_follow_rewrite() {
  LC_ALL=C awk -v window="$3" -v workspace="$4" -v tab="$5" -v pane="$6" -v account="${7-}" '
    /^window=/ { print "window=" window; next }
    /^herdr_workspace_id=/ { print "herdr_workspace_id=" workspace; next }
    /^herdr_tab_id=/ { print "herdr_tab_id=" tab; next }
    /^herdr_pane_id=/ { print "herdr_pane_id=" pane; next }
    account != "" && /^account=/ { print "account=" account; next }
    { print }
  ' "$1" > "$2"
}

jg_endpoint_follow() {  # <meta-file> <task-id> <state-dir>
  local meta=$1 id=$2 state=$3 session worktree old_pane old_window found new_pane new_tab new_workspace
  local other other_session other_pane account recorded_account new_window lock tmp agent_name rc=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(jg_backend_of_meta "$meta")" = herdr ] || return 1
  [ -z "$(jg_meta_get "$meta" remote_host)" ] || return 1
  jg_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || return 1
  jg_backend_source herdr >/dev/null 2>&1 || return 1
  session=$(jg_backend_meta_exact_value "$meta" herdr_session) || return 1
  worktree=$(jg_backend_meta_exact_value "$meta" worktree) || return 1
  old_pane=$(jg_backend_meta_exact_value "$meta" herdr_pane_id) || return 1
  old_window=$(jg_backend_meta_exact_value "$meta" window) || return 1

  # 2. Only a pane Herdr says is gone can have been moved off.
  [ "$(jg_backend_herdr_pane_presence_state "$session" "$old_pane")" = dead ] || return 1

  # 3. The one agent that is this task, working in its worktree, elsewhere.
  agent_name=$(jg_meta_get "$meta" agent_name)
  [ -n "$agent_name" ] || agent_name=$(jg_backend_herdr_agent_name_for "$id") || return 1
  found=$(jg_backend_herdr_moved_agent "$session" "$agent_name" "$worktree" "$old_pane") || return 1
  IFS=$'\t' read -r new_pane new_tab new_workspace <<<"$found"
  [ -n "$new_pane" ] && [ -n "$new_tab" ] && [ -n "$new_workspace" ] || return 1
  new_window="$session:$new_pane"

  # 4. Positively live there, by the classifier every other reader uses.
  [ "$(jg_backend_herdr_pane_agent_state "$session" "$new_pane")" = live ] || return 1

  # 5. Never take a pane another task record already owns.
  for other in "$state"/*.meta; do
    [ -f "$other" ] && [ ! -L "$other" ] && [ "$other" != "$meta" ] || continue
    other_session=$(jg_meta_get "$other" herdr_session)
    other_pane=$(jg_meta_get "$other" herdr_pane_id)
    if [ "$other_session" = "$session" ] && [ "$other_pane" = "$new_pane" ]; then
      return 1
    fi
  done

  # account=: only a pool account id is rewritten (see the header).
  account=
  recorded_account=$(jg_meta_get "$meta" account)
  case "$recorded_account" in
    ''|ordinary|/*) ;;
    *) account=$(jg_endpoint_follow_pool_account "$new_pane") || account= ;;
  esac

  # Loaded only now: a repair is rare, a state read is not.
  if ! declare -F jg_meta_lock_path >/dev/null 2>&1; then
    # shellcheck source=bin/jg-wake-lib.sh
    . "${JG_ENDPOINT_FOLLOW_BIN:-${BASH_SOURCE[0]%/*}}/jg-wake-lib.sh"
  fi
  lock=$(jg_meta_lock_path "$meta") || return 1
  jg_lock_try_acquire "$lock" || return 1
  # The decision above was made before the lock; the record must still be the
  # one it was made about.
  if [ "$(jg_backend_meta_exact_value "$meta" herdr_pane_id 2>/dev/null)" != "$old_pane" ]; then
    jg_lock_release "$lock"
    return 1
  fi
  tmp=$(mktemp "$state/.$id.meta.follow.XXXXXX") || { jg_lock_release "$lock"; return 1; }
  if ! jg_endpoint_follow_rewrite "$meta" "$tmp" "$new_window" "$new_workspace" "$new_tab" "$new_pane" "$account" \
    || ! jg_backend_validate_task_endpoint "$tmp" "$id" >/dev/null 2>&1 \
    || [ "$JG_BACKEND_VALIDATED_TARGET" != "$new_window" ]; then
    rm -f "$tmp"
    jg_lock_release "$lock"
    return 1
  fi
  if ! declare -F jg_backlog_atomic_transition >/dev/null 2>&1; then
    # shellcheck source=bin/jg-backlog-lib.sh
    . "${JG_ENDPOINT_FOLLOW_BIN:-${BASH_SOURCE[0]%/*}}/jg-backlog-lib.sh"
    # shellcheck source=bin/jg-backlog-transition-lib.sh
    . "${JG_ENDPOINT_FOLLOW_BIN:-${BASH_SOURCE[0]%/*}}/jg-backlog-transition-lib.sh"
  fi
  jg_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$state" || rc=1
  [ "$rc" -eq 0 ] || rm -f "$tmp"
  jg_lock_release "$lock"
  [ "$rc" -eq 0 ] || return 1
  printf 'jg-endpoint-follow: %s: %s -> %s%s\n' "$id" "$old_window" "$new_window" \
    "${account:+ (account $account)}" >&2
  return 0
}
