#!/usr/bin/env bash
# jg-sentinel-watch.sh - the sentinel's watch pass: it reads the home's supervision from outside the session.
#
# Usage: JG_HOME=<home> jg-sentinel-watch.sh run     one pass: what the timer unit runs (jg-sentinel.sh watch calls it)
# Reads, never writes: state/.last-watcher-beat (the tick's beat), state/.lock (the session), state/.wake-queue (the
# unacknowledged wakes) and state/alerts/*.rec (the age of each open alert). Machine 3 (core/machines/tables/supervision.tsv),
# edge `watching revive starting`: the beat is older than JG_SENTINEL_BEAT_SECS x JG_SENTINEL_BEAT_MISSES (60 s x 2) while
# work is under way, so this pass starts the watcher again (JG_SENTINEL_WATCHER_START, default bin/jg-watch-arm.sh, detached).
#   - A watcher still dead at the next run after JG_SENTINEL_REVIVE_TRIES (2) starts raises supervision-down--watcher-dead.
#   - A session that holds no lock, with a wake unacknowledged or an alert open for JG_SENTINEL_STUCK_SECS (1200) or more,
#     raises supervision-down--escalation-stuck: the escalation has no one to read it. The new alert names of the report
#     (section 8, slice H14) are rows of a later slice, so both raise through the row of the table today.
#   - A beat that is back, or a session with nothing stuck, resolves its alert.
# Every run appends one row to state/.sentinel-health.tsv (kept to 500 rows):
#   epoch  beat_age_s  needed  watcher(fresh|dead|idle)  session(live|stopped)  unacked_wakes  oldest_wake_s  open_alerts  oldest_alert_s  action
# Not read yet: Main's open decision records (they have no listing command; a follow-up of slice H16).
# Exit 0 after a pass, 2 for usage or a missing JG_HOME. The unit files beside this script run it every minute.
set -u
export LC_ALL=C

case "${1:-}" in
  run) ;;
  -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: JG_HOME=<home> jg-sentinel-watch.sh run" >&2; exit 2 ;;
esac
[ -n "${JG_HOME:-}" ] || { echo "jg-sentinel-watch: JG_HOME must be set explicitly" >&2; exit 2; }
JG_HOME=$(cd "$JG_HOME" 2>/dev/null && pwd -P) || { echo "jg-sentinel-watch: JG_HOME is not a directory" >&2; exit 2; }
export JG_HOME
BIN=${JG_BIN:-$JG_HOME/bin}
STATE=$JG_HOME/state
BEAT=${JG_SENTINEL_BEAT_SECS:-60}
MISSES=${JG_SENTINEL_BEAT_MISSES:-2}
TRIES=${JG_SENTINEL_REVIVE_TRIES:-2}
STUCK=${JG_SENTINEL_STUCK_SECS:-1200}
START=${JG_SENTINEL_WATCHER_START:-$BIN/jg-watch-arm.sh}
HEALTH=$STATE/.sentinel-health.tsv
MISS_FILE=$STATE/.sentinel-watch-miss
# shellcheck source=bin/jg-wake-lib.sh
. "$BIN/jg-wake-lib.sh"
# shellcheck source=bin/jg-supervision-lib.sh
. "$BIN/jg-supervision-lib.sh"
mkdir -p "$STATE"

alert() {  # <raise|resolve> <subject> [note]
  if [ "$1" = raise ]; then
    JG_STATE_OVERRIDE="$STATE" "$BIN/jg-alert.sh" raise supervision-down "$2" --home "$JG_HOME" --note "$3" >/dev/null 2>&1 || true
  else
    JG_STATE_OVERRIDE="$STATE" "$BIN/jg-alert.sh" resolve "supervision-down--$2" >/dev/null 2>&1 || true
  fi
}

# The session is live when the first line of state/.lock is a running process.
session_live() {
  local pid; pid=$(sed -n 1p "$STATE/.lock" 2>/dev/null)
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# <count> <oldest age> of the wakes in the queue: a row is `<seq> <epoch in ms> <type> <key> <reason>`, tab-separated.
wake_ages() {
  awk -F'\t' -v now="$1" 'NF >= 4 && $2 ~ /^[0-9]+$/ { t = ($2 > 100000000000) ? int($2 / 1000) : $2; n++; if (min == "" || t < min) min = t } END { printf "%d %d\n", n, n ? now - min : 0 }' "$STATE/.wake-queue" 2>/dev/null || echo "0 0"
}

# <count> <oldest age> of the alerts that are open (a state of the machine other than resolved or inhibited), our own two aside.
alert_ages() {
  local rec s key n=0 oldest=0 since
  for rec in "$STATE"/alerts/*.rec; do
    [ -r "$rec" ] || continue
    key=${rec##*/}; key=${key%.rec}
    case $key in supervision-down--watcher-dead|supervision-down--escalation-stuck) continue ;; esac
    s=$(sed -n 's/^state=//p' "$rec" | head -1)
    [ "$s" = open ] || continue
    since=$(sed -n 's/^since=//p' "$rec" | head -1)
    case $since in ''|*[!0-9]*) continue ;; esac
    n=$((n + 1))
    [ $(( $1 - since )) -le "$oldest" ] || oldest=$(( $1 - since ))
  done
  printf '%d %d\n' "$n" "$oldest"
}

# Start the watcher again, detached from this pass so it outlives the unit's run.
revive() {
  [ -x "$START" ] || return 1
  if command -v setsid >/dev/null 2>&1; then
    JG_HOME="$JG_HOME" setsid "$START" </dev/null >>"$STATE/.sentinel.log" 2>&1 &
  else
    JG_HOME="$JG_HOME" "$START" </dev/null >>"$STATE/.sentinel.log" 2>&1 &
  fi
}

pass() {
  local now beat beat_age watcher=idle session=stopped needed=no action=- misses
  local nwake wake_age nalert alert_age
  now=$(date +%s)
  jg_supervision_status "$STATE" $(( BEAT * MISSES ))
  beat=$(jg_path_mtime "$STATE/.last-watcher-beat" 2>/dev/null || true)
  case ${beat:-} in ''|*[!0-9]*) beat_age=-1 ;; *) beat_age=$(( now - beat )) ;; esac
  [ "$JG_SUP_NEEDED" = true ] && needed=yes
  session_live && session=live
  read -r nwake wake_age <<<"$(wake_ages "$now")"
  read -r nalert alert_age <<<"$(alert_ages "$now")"

  if [ "$needed" = yes ] && [ "$JG_SUP_WATCHER_FRESH" = false ]; then
    watcher=dead
    misses=$(( $(cat "$MISS_FILE" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$misses" >"$MISS_FILE"
    if [ "$misses" -gt "$TRIES" ]; then
      alert raise watcher-dead "The watcher beat is $JG_SUP_BEACON_DESC old and $TRIES starts from outside did not bring it back. Run bin/jg-session-start.sh, then end the turn so supervision re-arms."
      action=page
    elif revive; then
      action=revive
    else
      action=revive-failed
    fi
  else
    [ "$needed" = no ] || watcher=fresh
    rm -f "$MISS_FILE"
    alert resolve watcher-dead
  fi

  # With no live session nobody reads the queue or the alerts: an old one is an escalation with no reader.
  if [ "$needed" = yes ] && [ "$session" = stopped ] && { [ "$wake_age" -ge "$STUCK" ] || [ "$alert_age" -ge "$STUCK" ]; }; then
    alert raise escalation-stuck "No session holds the lock: $nwake wake(s) wait, the oldest for ${wake_age}s; $nalert alert(s) are open, the oldest for ${alert_age}s. Start the primary session with bin/jg-session-start.sh."
    action="$action+escalation-stuck"
  else
    alert resolve escalation-stuck
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$beat_age" "$needed" "$watcher" "$session" "$nwake" "$wake_age" "$nalert" "$alert_age" "$action" >>"$HEALTH"
  if [ "$(wc -l <"$HEALTH")" -gt 500 ]; then tail -n 250 "$HEALTH" >"$HEALTH.tmp" && mv -f "$HEALTH.tmp" "$HEALTH"; fi
}

lock=$STATE/.sentinel-watch.lock
jg_lock_try_acquire "$lock" || exit 0
pass
jg_lock_release "$lock"
exit 0
