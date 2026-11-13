#!/usr/bin/env bash
# relaunch.sh - rung 0 of `lost-worker`, after the ring: a worker that stays lost is relaunched on its own work copy, at most 3 times
# in 30 minutes; then the lead is told. stall-action.sh calls it for a worker whose beat verdict is silent, api-error, idle-no-reason
# or no-start, and for nothing else (a squad lead is Main's, a worker with no beat record keeps the pane rule).
# Usage: relaunch.sh act <jg-home> <task> <hash> <reason>
#        relaunch.sh clear <jg-home> <task>           the worker beats again: resolve its lost-worker alert
# act does at most one move, records it in data/stall-action/actions.jsonl (the ledger stall-action.sh writes) and prints nothing:
#   - the reason is an API error of a billing kind (billing_error, account_on_hold): a relaunch on the same account fails the same way,
#     so the lead is told at once, with the error type named, and the worker is never relaunched here;
#   - fewer than 3 relaunches of the task in the last 30 minutes (JG_STALL_ACTION_RELAUNCH_WINDOW) and the last move (the ring of this beat, or the
#     previous relaunch) is at least one wait old (JG_STALL_ACTION_RELAUNCH_WAIT, default 300 s: a new session gets that long to beat):
#     `bin/jg-control.sh <task> relaunch`; a refused relaunch counts as a try, so a refusal is not retried on every sweep;
#   - 3 relaunches in the window: the lead is told once per beat, with the three tries named (`jg-alert.sh raise lost-worker`).
# The alert key is lost-worker--<task>; clear resolves it. Seams: JG_STALL_ACTION_CONTROL, JG_STALL_ACTION_ALERT, JG_STALL_ACTION_NOW,
# JG_STALL_ACTION_RELAUNCH_WAIT, JG_STALL_ACTION_RELAUNCH_WINDOW.
set -u
verb=${1:-}
case "$verb:$#" in act:5|clear:3) ;; *) echo "usage: relaunch.sh act <jg-home> <task> <hash> <reason> | clear <jg-home> <task>" >&2; exit 2 ;; esac
FMH=$(cd "$2" && pwd -P) || exit 2
task=$3
export JG_HOME=$FMH
CONTROL=${JG_STALL_ACTION_CONTROL:-$FMH/bin/jg-control.sh}
ALERT=${JG_STALL_ACTION_ALERT:-$FMH/bin/jg-alert.sh}
NOW=${JG_STALL_ACTION_NOW:-$(date +%s)}
WAIT=${JG_STALL_ACTION_RELAUNCH_WAIT:-300}
WINDOW=${JG_STALL_ACTION_RELAUNCH_WINDOW:-1800}
LIMIT=3
LEDGER=$FMH/data/stall-action/actions.jsonl
BUDGET=$(( ( ${JG_CHECK_TIMEOUT:-30} - 5 ) / 3 )); [ "$BUDGET" -ge 3 ] || BUDGET=3
key=lost-worker--$task

if [ "$verb" = clear ]; then
  [ -e "$FMH/state/alerts/$key.rec" ] && "$ALERT" resolve "$key" >/dev/null 2>&1
  exit 0
fi
hash=$4 reason=$5
record() { printf '{"task":"%s","hash":"%s","step":"%s","ok":%s,"at":%s}\n' "$task" "$hash" "$1" "$2" "$NOW" >> "$LEDGER"; }  # <step> <true|false>
# at-times of a step of this task, newest last
times() { grep -F "\"task\":\"$task\"," "$LEDGER" 2>/dev/null | grep -F "\"step\":\"$1\"" | sed 's/.*"at":\([0-9]*\)}.*/\1/'; }
tell_lead() {  # <fact text>: one alert per beat, delivered to its holder
  grep -qF "\"task\":\"$task\",\"hash\":\"$hash\",\"step\":\"alert\"" "$LEDGER" 2>/dev/null && return 0
  if "$ALERT" raise lost-worker "$task" --fact "reason=$reason" --fact "$1" 2>/dev/null | "$ALERT" deliver >/dev/null 2>&1; then
    record alert true
  else
    record alert false
  fi
}

case "$reason" in
  api:billing_error|api:account_on_hold) tell_lead "relaunch=refused: a billing error is not cured by a relaunch on the same account"; exit 0 ;;
esac

recent=$(times relaunch | awk -v c=$(( NOW - WINDOW )) '$1 >= c' | wc -l)
if [ "$recent" -ge "$LIMIT" ]; then
  tell_lead "relaunch=tried $LIMIT times in $(( WINDOW / 60 )) minutes"
  exit 0
fi
# nothing before the ring: the ring is the first rung. The wait counts from the ring of this beat or the last relaunch, the later one.
ring_at=$(grep -F "\"task\":\"$task\",\"hash\":\"$hash\",\"step\":\"ring\"" "$LEDGER" 2>/dev/null | sed 's/.*"at":\([0-9]*\)}.*/\1/' | tail -n 1)
last=$(times relaunch | tail -n 1)
[ -n "$ring_at" ] || [ -n "$last" ] || exit 0
[ -z "$last" ] || [ "${ring_at:-0}" -ge "$last" ] || ring_at=$last
[ $(( NOW - ring_at )) -ge "$WAIT" ] || exit 0
if timeout "$BUDGET" "$CONTROL" "$task" relaunch >/dev/null 2>&1; then record relaunch true; else record relaunch false; fi
exit 0
