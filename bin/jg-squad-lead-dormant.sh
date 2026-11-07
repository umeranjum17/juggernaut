#!/usr/bin/env bash
# jg-squad-lead-dormant.sh - stop a local Squad Lead with nothing to do, and
# relaunch it the moment work is routed to it.
#   sweep          one pass over this home's local leads
#   wake <id>      relaunch a dormant lead before delivery
#   stop-idle <id> stop one idle lead now, with no persist round and no quiet
#                  window, for a restart pass that has already asked it to persist
#
# Eligible: no open backlog item in its home (nothing unchecked under
# "In flight" or "Queued": every queued, in-flight, blocked, held and in-review
# item), no task record in its state/ (so no live worker and no unlanded work,
# since only the landed-work teardown removes one), no unread inbox message here,
# an empty wake queue, and no change in those records for
# config/squad-lead-dormant-secs (integer, default 1800; 0 disables the rule).
# Remote and parked leads are never touched, and a lead is never stopped to look
# busy. Record state/.squad-lead-dormant-<id>, one line per sweep: `asked <epoch>
# <corr>`, `answered <epoch>`, then `dormant <epoch>` once bin/jg-control.sh <id>
# exit stopped it; its home, backlog, lease and records all stay. An ineligible
# lead drops the record, and the stop re-checks eligibility under the liveness
# lock, so no sweep, tick or wake sees a half-stopped lead.
# A dormant lead (squad_lead_dormant, bin/jg-squad-lead-registry-lib.sh) is
# skipped by liveness, the session-start sweep and their alarms, reads DORMANT in
# bin/jg-fleet-heartbeat.sh, and is relaunched by bin/jg-send.sh before delivery;
# every routed path reaches a lead through jg-send, and a sweep wakes one that
# gained work by another route.
# stop-idle (bin/jg-squad-lead-restart.sh): a restart replaces every lead's agent,
# and a replacement that starts only to read its digest and idle costs a model
# session for nothing. For a local lead that the same busy test finds idle, and
# that has no open pending-reply request either, the restart pass stops the agent
# and writes the dormant record instead of relaunching it, so the first routed
# message starts it on the current code. Exit 0: stopped and marked dormant; 10:
# not stopped because it has work, an open request or the rule is off (stdout names
# why) and the caller relaunches it as before; 1: the stop itself failed.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
die() { printf 'jg-squad-lead-dormant: %s\n' "$1" >&2; exit "${2:-1}"; }
[ -n "${JG_HOME:-}" ] && [ -d "$JG_HOME" ] || die "JG_HOME must name this juggernaut home"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-lock-lib.sh
. "$SCRIPT_DIR/jg-lock-lib.sh"
# shellcheck source=bin/jg-pending-reply-lib.sh
. "$SCRIPT_DIR/jg-pending-reply-lib.sh"
# shellcheck source=bin/jg-parked-homes-lib.sh
. "$SCRIPT_DIR/jg-parked-homes-lib.sh"
# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"
# shellcheck source=bin/jg-backlog-lib.sh
. "$SCRIPT_DIR/jg-backlog-lib.sh"
NOW=$(date +%s)
PERSIST_WAIT=${JG_SQUAD_LEAD_DORMANT_PERSIST_WAIT:-900}
PERSIST_REQUEST='Your home has no open work, so your agent will be stopped to free its seat; routed work relaunches you, and every durable record stays. Before that, persist the open work you are holding only in this conversation, following the /intel skill'"'"'s "Open-record persistence" section and nothing else from that skill. Do not start new work to look busy. Then reply on your parent channel saying it is done.'

run() { JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$@"; }
lock_of() { printf '%s/.squad-lead-liveness-%s.lock\n' "$STATE" "$1"; }

idle_secs() {
  local v
  v=$(awk 'NF { print $1; exit }' "$CONFIG/squad-lead-dormant-secs" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) v=1800 ;; esac
  printf '%s\n' "$v"
}

busy_reason() {  # <id> <lead-home>: why it must stay awake, or nothing when it has no work
  local id=$1 home=$2 f text open
  if ! text=$(jg_backlog_text "$home/config" 2>/dev/null); then
    echo "its backlog is unreadable"
    return
  fi
  open=$(printf '%s\n' "$text" | awk '/^## /{ s = ($0 == "## In flight" || $0 == "## Queued") } s && /^- \[ \]/{ n++ } END { print n + 0 }')
  [ "$open" -eq 0 ] || { echo "$open open item(s)"; return; }
  for f in "$home"/state/*.meta "$STATE/$id.inbox"/*.msg; do
    [ -e "$f" ] && { echo "a worker or an unread message"; return; }
  done
  [ ! -s "$home/state/.wake-queue" ] || echo "a queued wake"
}

open_request() {  # <id>: whether a marked request to this lead still awaits its report
  local rec dir
  dir=$(jg_pending_reply_dir "$STATE")
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    [ "$(jg_pending_reply_get "$rec" task_id)" = "$1" ] || continue
    [ "$(jg_pending_reply_get "$rec" phase)" != resolved ] && return 0
  done
  return 1
}

quiet_secs() {  # <id> <lead-home>: seconds since its newest record changed
  local f m newest=0 store
  store=$(jg_backlog_beads_store "$2/config" 2>/dev/null) || store=
  for f in "$STATE/$1.status" "$STATE/$1.inbox" "$STATE/$1.inbox/handled" "$store" "$2/state/.wake-queue"; do
    [ -n "$f" ] || continue
    m=$(jg_lock_path_mtime "$f") || continue
    [ "${m:-0}" -le "$newest" ] || newest=$m
  done
  printf '%s\n' "$((NOW - newest))"
}

cmd_wake() {  # <id>
  local id=$1 lock out=''
  squad_lead_dormant "$STATE" "$id" || return 0
  lock=$(lock_of "$id")
  jg_lock_acquire_wait_bounded "$lock" "${JG_SQUAD_LEAD_DORMANT_LOCK_WAIT:-120}" \
    || die "squad lead $id is mid-stop or mid-relaunch; resend shortly"
  if squad_lead_dormant "$STATE" "$id"; then
    out=$(run "$JG_ROOT/bin/jg-control.sh" "$id" relaunch 2>&1) && out=
    printf 'woke: %s%s\n' "$id" "${out:+ - relaunch failed, so liveness recovery takes over: $(printf '%s' "$out" | tail -1)}"
    rm -f -- "$(squad_lead_dormant_record "$STATE" "$id")"
  fi
  jg_lock_release "$lock" || true
}

cmd_stop_idle() {  # <id>
  local id=$1 meta lock why out rc=0
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ] || ! jg_compat_meta_is_squad_lead "$meta"; then die "$id is not a squad lead of this home"; fi
  [ -z "$(jg_meta_get "$meta" remote_host)" ] || { echo "a remote lead is restarted on its host"; return 10; }
  [ "$(idle_secs)" -gt 0 ] || { echo "the dormant rule is off (config/squad-lead-dormant-secs is 0)"; return 10; }
  lock=$(lock_of "$id")
  jg_lock_acquire_wait_bounded "$lock" "${JG_SQUAD_LEAD_DORMANT_LOCK_WAIT:-120}" \
    || die "squad lead $id is mid-stop or mid-relaunch"
  why=$(busy_reason "$id" "$(jg_meta_get "$meta" home)")
  if [ -z "$why" ] && open_request "$id"; then why="a request still awaits its report"; fi
  if [ -n "$why" ]; then
    printf '%s\n' "$why"
    rc=10
  elif out=$(run "$JG_ROOT/bin/jg-control.sh" "$id" exit 2>&1); then
    printf 'dormant %s\n' "$NOW" > "$(squad_lead_dormant_record "$STATE" "$id")" || rc=1
  else
    printf '%s\n' "$out" | tail -1 >&2
    rc=1
  fi
  jg_lock_release "$lock" || true
  return "$rc"
}

sweep_one() {  # <meta> <id>: one lead's step through asked -> answered -> dormant
  local meta=$1 id=$2 home rec why out lock word='' epoch='' corr=''
  home=$(jg_meta_get "$meta" home)
  [ -d "$home" ] || return 0
  rec=$(squad_lead_dormant_record "$STATE" "$id")
  [ ! -f "$rec" ] || read -r word epoch corr < "$rec"
  why=$(busy_reason "$id" "$home")
  if [ "$word" = dormant ]; then
    [ -z "$why" ] || cmd_wake "$id"
    return 0
  fi
  if [ -n "$why" ]; then
    [ -z "$word" ] || { rm -f -- "$rec"; printf 'awake: %s - %s\n' "$id" "$why"; }
    return 0
  fi
  case "$word" in
    '')
      [ "$(quiet_secs "$id" "$home")" -ge "$IDLE" ] || return 0
      corr=$(jg_pending_reply_create "$JG_HOME" "$STATE" "$id" "$PERSIST_REQUEST") || return 0
      if JG_PENDING_REPLY_EXISTING_CORR=$corr run "$JG_ROOT/bin/jg-send.sh" "$id" "$PERSIST_REQUEST" >/dev/null 2>&1; then
        printf 'asked %s %s\n' "$NOW" "$corr" > "$rec" && printf 'asked: %s - persist first, then stop\n' "$id"
      else
        jg_pending_reply_discard_undelivered "$STATE" "$corr" >/dev/null 2>&1 || true
      fi ;;
    asked)
      if jg_pending_reply_try_resolve "$STATE" "$corr" >/dev/null 2>&1; then
        printf 'answered %s\n' "$NOW" > "$rec"
      elif [ $((NOW - epoch)) -ge "$PERSIST_WAIT" ]; then
        rm -f -- "$rec"
      fi ;;
    answered)
      lock=$(lock_of "$id")
      jg_lock_try_acquire "$lock" || return 0
      if [ -z "$(busy_reason "$id" "$home")" ] && out=$(run "$JG_ROOT/bin/jg-control.sh" "$id" exit 2>&1); then
        printf 'dormant %s\n' "$NOW" > "$rec" && printf 'dormant: %s - stopped, wakes on routed work\n' "$id"
      else
        printf 'awake: %s - stop refused: %s\n' "$id" "$(printf '%s' "${out:-work arrived}" | tail -1)"
        rm -f -- "$rec"
      fi
      jg_lock_release "$lock" || true ;;
  esac
}

cmd_sweep() {
  local meta id
  IDLE=$(idle_secs)
  [ "$IDLE" -gt 0 ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    jg_compat_meta_is_squad_lead "$meta" || continue
    [ -z "$(jg_meta_get "$meta" remote_host)" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    jg_parked_skip_meta "$meta" "$id" watch-liveness && continue
    sweep_one "$meta" "$id"
  done
}

valid_id() { case "${1:-}" in ''|*[!A-Za-z0-9._-]*) die "a squad lead id is required" 2 ;; esac; }
case "${1:-}" in
  sweep) cmd_sweep ;;
  wake) valid_id "${2:-}"; cmd_wake "$2" ;;
  stop-idle) valid_id "${2:-}"; cmd_stop_idle "$2" ;;
  *) die "usage: jg-squad-lead-dormant.sh sweep | wake <id> | stop-idle <id>" 2 ;;
esac
