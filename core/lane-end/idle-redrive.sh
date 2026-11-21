#!/usr/bin/env bash
# Usage: idle-redrive.sh (from jg-delivery-tick.sh, under its home lock).
# Recovery state        Observation                    Next state
# Fresh                 Unfinished, live and idle      Steered once
# Fresh or steered      Unfinished, agent exited       Relaunched once
# Steered/relaunched    Still idle or dead after 60s   Blocked, no more attempts
# Any                   Closing status, wait or busy  No action
# The retry records survive relaunch and ordinary lane cleanup retires them.
set -u
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd -P)
STATE=${JG_STATE_OVERRIDE:?}
# shellcheck source=bin/jg-task-inbox-lib.sh
. "$BIN/jg-task-inbox-lib.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$BIN/jg-classify-lib.sh"

STEER='Your turn ended without closing the task. Continue the assigned work from your current progress. Before ending your turn, report done, a blocker, a decision needed, or a declared wait in your task status.'

# The status ledger folds open decisions and pauses, including a pause with an
# unrelated resolution after it. An explicit stop or a landing also owns the lane.
unfinished() {  # <id> <kind> <spawn-gen>
  local status=$STATE/$1.status line stopped spawned=${3#s}
  [ ! -e "$STATE/$1.parked" ] || return 1
  if [ -e "$STATE/$1.exit" ]; then
    stopped=$(head -n 1 "$STATE/$1.exit") || return 1
    spawned=${spawned%%.*}
    case "$stopped:$spawned" in *[!0-9:]*|:*|*:) return 1 ;; esac
    [ "$spawned" -gt "$stopped" ] || return 1
  fi
  ! compgen -G "$STATE/.trunk-run-$1-*.lock" >/dev/null || return 1
  line=$(status_current_line "$status" "$2") || return 1
  case "$(status_line_verb "$line")" in
    done|blocked|needs-decision|failed|paused|captain-held) return 1 ;;
  esac
  ! status_is_paused_or_captain_held "$line"
}

attempt_old_enough() {  # <attempt file>
  local at
  at=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || return 1
  [ "$(( $(date +%s) - at ))" -ge 60 ]
}

redrive() {
  local meta=$1 id kind gen path backend target harness agent verdict action attempt msg why
  local -a detach=(nohup)
  id=${meta##*/}; id=${id%.meta}
  kind=$(jg_meta_get "$meta" kind)
  case "$kind" in ship|scout) ;; *) return 0 ;; esac
  [ -d "$(jg_meta_get "$meta" worktree)" ] || return 0
  gen=$(jg_meta_get "$meta" spawn_gen)
  [ -n "$gen" ] && unfinished "$id" "$kind" "$gen" || return 0
  jg_backend_validate_task_endpoint "$meta" "$id" 2>/dev/null || return 0
  backend=$JG_BACKEND_VALIDATED_BACKEND; target=$JG_BACKEND_VALIDATED_TARGET
  path=$STATE/$id.idle-redrive

  agent=$(jg_backend_agent_state "$backend" "$target" "$meta" "$id")
  case "$agent" in
    dead|missing)
      # Herdr can say dead when a live harness lacks an agent registration.
      if [ "$agent:$backend" = dead:herdr ]; then
        jg_backend_agent_exited "$backend" "$target" || return 0
      fi
      action=relaunch ;;
    alive|unverified)
      harness=$(jg_meta_get "$meta" harness)
      verdict=$(jg_busy_classify_semantic "$backend" "$target" "$harness" "$id" "$STATE")
      [ "${verdict%% *}" = idle ] || return 0
      [ "$(jg_backend_composer_state "$backend" "$target" "jg-$id")" = empty ] || return 0
      for msg in "$STATE/$id.inbox/"*.msg; do
        [ -f "$msg" ] || continue
        # Let the normal inbox ladder finish a steer from another source.
        [ "$(jg_task_inbox_body "$msg")" = "$STEER" ] || return 0
      done
      action=steer ;;
    *) return 0 ;;
  esac

  [ "$(jg_meta_get "$meta" spawn_gen)" = "$gen" ] && unfinished "$id" "$kind" "$gen" || return 0
  [ ! -d "$STATE/.control-$id.lock" ] && [ ! -d "$(jg_meta_lock_path "$meta")" ] || return 0
  attempt=$path.$action
  # A relaunched worker gets its next turn from the relaunch instructions.
  [ ! -f "$path.relaunch" ] || attempt=$path.relaunch
  if [ -f "$attempt" ]; then
    attempt_old_enough "$attempt" || return 0
    why=$(grep '^error:' "$attempt" | tail -n 1 | cut -c1-100)
    printf 'blocked [at=%s] [key=idle-redrive]: Worker is %s without a closing status after automatic recovery.%s\n' \
      "$(date +%s)" "$([ "$action" = steer ] && printf idle || printf stopped)" "${why:+ $why}" \
      | bash "$BIN/jg-lavish-guard.sh" --append "$STATE/$id.status"
    return
  fi

  # Reserve before sending so a cut-off tick cannot send the same recovery again.
  : > "$attempt" || return 1
  case "$action" in
    steer)
      JG_SEND_EXPECTED_SPAWN_GEN=$gen JG_SEND_IDEMPOTENT=1 \
        bash "$BIN/jg-send.sh" "$id" "$STEER" >> "$attempt" 2>&1 ;;
    relaunch)
      # The transaction can take time. Do not hold the home tick or make other
      # lanes wait for it, and let control prove the agent is still absent.
      command -v setsid >/dev/null && detach=(setsid nohup)
      JG_CONTROL_EXPECT_EXITED_GEN=$gen "${detach[@]}" bash "$JG_HOME/bin/jg-control.sh" "$id" relaunch \
        --note "$STEER" </dev/null >> "$attempt" 2>&1 & ;;
  esac
}

for meta in "$STATE/"*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  redrive "$meta" || printf 'idle-redrive: recovery failed for %s\n' "${meta##*/}" >&2
done
exit 0
