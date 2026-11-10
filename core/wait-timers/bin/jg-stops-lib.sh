#!/usr/bin/env bash
# Non-lane stops use the wait ladder's table, episode identity and ledger.
# Detector files are state/.stops/<subject>.<state>; removing one clears it.
# The delivery pass owns serialization. Rows with no handler are left untouched.

# shellcheck source=core/wait-timers/bin/jg-wait-timers-lib.sh
. "$SCRIPT_DIR/../core/wait-timers/bin/jg-wait-timers-lib.sh"

jg_stops_tick() {
  local now dir src name subject state row owner steps next timer repeat clear record since fired last key line step stop_event_key
  now=$(date +%s) || return 1
  if [ "${JG_TEST_SEAM:-0}" = 1 ] && [ -n "${JG_STOPS_TEST_NOW:-}" ]; then now=$JG_STOPS_TEST_NOW; fi
  dir=$STATE/.waiting-timers/.stops
  for src in "$STATE"/.stops/*; do
    [ -f "$src" ] && [ ! -L "$src" ] || continue
    name=${src##*/}; subject=${name%.*}; state=${name##*.}
    case "$subject:$state" in *[!A-Za-z0-9._:-]*|:*|*:) continue ;; esac
    row=$(printf '%s\n' "$JG_WAIT_OWNER_TABLE" | awk -F '\t' -v s="$state" '$1 == s && NF >= 7 {print; exit}')
    if [ "${JG_TEST_SEAM:-0}" = 1 ] && [ -n "${JG_STOPS_TEST_ROW:-}" ]; then row=$JG_STOPS_TEST_ROW; fi
    [ -n "$row" ] || continue
    IFS=$'\t' read -r _ owner steps next timer repeat clear <<< "$row"
    [ -n "$clear" ] || { echo "stops: missing clear-by for $state" >&2; continue; }
    case "$timer" in ''|*[!0-9]*) echo "stops: invalid timer for $state" >&2; continue ;; esac
    case "$repeat" in -) ;; ''|*[!0-9]*|0) echo "stops: invalid repeat for $state" >&2; continue ;; esac
    mkdir -p "$dir" || return 1
    record=$dir/$name
    if [ ! -f "$record" ]; then
      key=$(jg_wait_timer_key "$subject" "$now" "$state") || return 1
      jg_wait_timer_save "$record" "$state" "$now" 0 0 "$key" 0 || return 1
    fi
    IFS=$'\t' read -r _ since fired _ key last _ _ < "$record" || return 1
    stop_event_key=$key
    if [ "$fired" -eq 0 ] && [ $((now - since)) -ge "$timer" ]; then
      for step in ${steps//,/ }; do
        case "$step" in
          test-terminate) [ "${JG_TEST_SEAM:-0}" = 1 ] || return 1; kill -TERM "$BASHPID" ;;
          -) jg_wake_append check "$stop_event_key" "waiting-timer-overdue: $subject $state; owner=$owner next=$next; $(cat "$src")" || return 1 ;;
          notify) jg_wake_append check "$stop_event_key" "waiting-timer-step: $subject $state; owner=$owner; $(cat "$src")" || return 1 ;;
          *) echo "stops: unknown step $step for $state" >&2; return 1 ;;
        esac
      done
      fired=$now; last=$now
      jg_wait_timer_save "$record" "$state" "$since" "$fired" 0 "$key" "$last" || return 1
    fi
    if [ "$fired" -ne 0 ] && [ "$repeat" != - ] && [ $((now - last)) -ge "$repeat" ]; then
      line=$(cat "$src") || return 1
      jg_wake_append check "$stop_event_key" "waiting-timer-overdue: $subject $state; owner=$owner next=$next; $line" || return 1
      jg_wait_timer_save "$record" "$state" "$since" "$fired" 0 "$key" "$now" || return 1
    fi
  done
  for record in "$dir"/*; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    name=${record##*/}; [ ! -e "$STATE/.stops/$name" ] || continue
    IFS=$'\t' read -r _ since fired _ key _ _ _ < "$record" || return 1
    if [ "$fired" -ne 0 ]; then
      stop_event_key=$key
      jg_wake_append check "$stop_event_key" "waiting-timer-cleared: ${name%.*} ${name##*.}" || return 1
      jg_wait_timer_ledger "$record" "${name%.*}" "$now" "$fired" "$(jg_wait_timer_fired_minutes "$fired" "$now")" cleared
    fi
    rm -f -- "$record" || return 1
  done
}
