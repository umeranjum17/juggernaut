#!/usr/bin/env bash
# Record one home-scoped supervision gap, or replay old cycle rows without guessing.
# Usage: JG_HOME=<home> jg-supervision-gap.sh detect|clear|replay
set -u
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/jg-wake-lib.sh
. "$BIN/jg-wake-lib.sh"
STATE=${JG_STATE_OVERRIDE:-${JG_HOME:?JG_HOME required}/state}
record=$STATE/.supervision-gap
case ${1:-} in
  replay)
    while IFS= read -r row; do
      case "$row" in *$'\t'beacon_age=*) printf '%s\tclass=unknown-historical\n' "$row" ;; esac
    done
    exit 0 ;;
  clear)
    [ -f "$record" ] || exit 0
    now=$(date +%s)
    IFS=$'\t' read -r _ episode _ < "$record" || exit 1
    episode=${episode#episode=}
    case "$episode" in ''|*[!0-9.]*) echo 'invalid supervision gap episode' >&2; exit 1 ;; esac
    mkdir -p "$STATE/.supervision-gaps" || exit 1
    printf '%s\tended_at=%s\n' "$(cat "$record")" "$now" > "$STATE/.supervision-gaps/$episode.tmp" || exit 1
    mv -f -- "$STATE/.supervision-gaps/$episode.tmp" "$STATE/.supervision-gaps/$episode" || exit 1
    rm -f -- "$record"
    exit ;;
  detect|observe) mode=$1 ;;
  *) echo 'usage: jg-supervision-gap.sh detect|clear|replay' >&2; exit 2 ;;
esac
now=$(date +%s)
pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
class='watcher-dead' progress=unknown child_deadline=none arm=none
holder_live=no
case "$pid" in ''|*[!0-9]*) pid=none ;; esac
if [ "$pid" != none ] && jg_pid_alive "$pid"; then
  if jg_watcher_lock_matches_pid "$STATE" "$BIN/jg-watch.sh" "$pid" "$JG_HOME"; then
    holder_live=yes
    class='watcher-hung'
    if [ -r "$STATE/.watch-progress" ]; then IFS=$'\t' read -r progress_pid progress_identity point < "$STATE/.watch-progress" || true; fi
    if [ "${progress_pid:-}" = "$pid" ] && [ "${progress_identity:-}" = "$JG_WATCHER_MATCHED_IDENTITY" ]; then progress=${point:-unknown}; fi
    if [ -r "$STATE/.watcher-child" ]; then read -r deadline owner < "$STATE/.watcher-child" || true; fi
    case "${deadline:-}" in ''|*[!0-9]*) ;; *)
      if [ "${owner:-}" = "$pid" ]; then
        child_deadline=$deadline
        [ "$now" -lt "$deadline" ] || class='child-overdue'
      fi ;;
    esac
  else
    class='unknown-current'
  fi
fi
if [ "$holder_live" = no ] && [ "$class" != unknown-current ]; then
  for file in "$STATE"/.watch-arms/*; do
    [ -f "$file" ] || continue
    IFS=$'\t' read -r arm_pid identity phase followed followed_identity < "$file" || continue
    case "$arm_pid" in ''|*[!0-9]*) continue ;; esac
    jg_pid_alive "$arm_pid" || continue
    [ "$(jg_pid_identity "$arm_pid" 2>/dev/null || true)" = "$identity" ] || continue
    arm=$arm_pid
    class='arm-idle'
    if [ "$phase" = waiting ] && [ "${followed:-none}" != none ] && \
      { ! jg_pid_alive "$followed" || [ "$(jg_pid_identity "$followed" 2>/dev/null || true)" != "${followed_identity:-none}" ]; }; then
      class='arm-wait-exited'
      break
    fi
  done
fi
if [ "$mode" = observe ]; then
  printf 'class=%s\twatcher=%s\tprogress=%s\tchild_deadline=%s\tarm=%s\n' "$class" "$pid" "$progress" "$child_deadline" "$arm"
  exit
fi
started=$now episode="$now.$$"
if [ -f "$record" ]; then
  IFS=$'\t' read -r first old_episode _ < "$record" || true
  case "${first:-}" in started_at=[0-9]*) started=${first#started_at=} ;; esac
  case "${old_episode:-}" in episode=*) episode=${old_episode#episode=} ;; esac
fi
printf 'started_at=%s\tepisode=%s\tclass=%s\twatcher=%s\tprogress=%s\tchild_deadline=%s\tarm=%s\n' \
  "$started" "$episode" "$class" "$pid" "$progress" "$child_deadline" "$arm" > "$record.tmp.$$" || exit 1
mv -f -- "$record.tmp.$$" "$record" || exit 1
printf '%s\n' "$class"
