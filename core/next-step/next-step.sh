#!/usr/bin/env bash
# next-step.sh - finished work is never silently left: the done-unhandled alert (P1) for a Recon whose required next step nobody took.
# Usage: next-step.sh tick <jg-home>   raise the alert for each Recon whose owed step has waited as long as the alert's row says (10 minutes),
#                                      climb a live one, and resolve each one whose step was taken
#        next-step.sh open <jg-home>   resolve what was taken, then print one line for each live alert, naming the lane, its step and how it is taken;
#                                      exit 0 when any is open, 1 when none is (the turn-end guard reads this)
# The definition of a "required next step" is bin/jg-facts-lib.sh jg_fact_next_step, the one the drain's sweep refusal reads too. This script holds
# none of it: it asks that fact for every lane, and the alert it keeps is the durable record that a step went unhandled. A Recon and its critic can
# owe the same step (the relay of an accepted draft), so the alert is one per Recon: done-unhandled--<Recon id>. An acknowledgement of the alert,
# a drained wake row or a sweep never closes it; only the fact reading "no step owed" again does, and the resolve names that reading as its proof.
# A Recon that is gone is never read as handled: its cleanup closes the alert (jg-alert.sh resolve-ticket). The delivery tick runs `tick` in every
# home with no model awake (bin/jg-delivery-tick.sh). The state directory is JG_STATE_OVERRIDE, else <home>/state; the data directory is
# JG_DATA_OVERRIDE, else <home>/data. Exit 2 is a usage error.
set -u
export LC_ALL=C
{ [ "$#" -eq 2 ] && [ -d "${JG_STATE_OVERRIDE:-$2/state}" ] && { [ "$1" = tick ] || [ "$1" = open ]; }; } || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
op=$1
H=$(cd "$2" && pwd -P)
STATE=${JG_STATE_OVERRIDE:-$H/state}
DATA=${JG_DATA_OVERRIDE:-$H/data}
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
# shellcheck source=bin/jg-facts-lib.sh
. "$ROOT/bin/jg-facts-lib.sh"
alert() { JG_HOME=$H JG_STATE_OVERRIDE=$STATE bash "$ROOT/bin/jg-alert.sh" "$@"; }
live_works() { alert list | sed -n 's/^done-unhandled--//p'; }

# Every finished lane is asked once; each Recon that some lane of it still owes a step for is kept with its ticket, its oldest clock and the
# first lane's line.
declare -A TICKET=() SINCE=() LINE=()
collect() {
  local meta lane facts work since
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    lane=$(basename "$meta" .meta)
    facts=$(jg_fact_next_step "$STATE" "$DATA" "$lane")
    [ "$(jg_fact_val "$facts" step)" != none ] || continue
    work=$(jg_fact_val "$facts" work)
    since=$(jg_fact_val "$facts" since)
    if [ -z "${SINCE[$work]+x}" ]; then
      TICKET[$work]=$(jg_fact_val "$facts" ticket); SINCE[$work]=$since; LINE[$work]=$(jg_fact_next_step_text "$lane" "$facts")
    elif [ "$since" -lt "${SINCE[$work]}" ]; then SINCE[$work]=$since; fi
  done
}

# Each live alert whose Recon no lane owes a step for is resolved, with the Recon's own reading of the fact as its proof.
resolve_taken() {
  local work why
  collect
  while IFS= read -r work; do
    [ -f "$STATE/$work.meta" ] && [ -z "${SINCE[$work]+x}" ] || continue
    why=$(jg_fact_val "$(jg_fact_next_step "$STATE" "$DATA" "$work")" reason | tr -c 'A-Za-z0-9_./=:@+\n-' '-')
    alert resolve "done-unhandled--$work" --proof "source:${why:-step-taken}" >/dev/null || echo "next-step: could not resolve done-unhandled--$work" >&2
  done < <(live_works)
}

cmd_tick() {
  local work held after='' now key
  resolve_taken
  now=$(date +%s)
  for work in "${!SINCE[@]}"; do
    [ -n "$after" ] || after=$(alert row done-unhandled | cut -f3)   # the wait is the alert row's own, read once and only when a step is owed
    held=$((now - SINCE[$work]))
    [ "$held" -ge "$after" ] || continue
    key=done-unhandled--$work
    case $(alert word "$key" 2>/dev/null) in
      '' | resolved)
        alert raise done-unhandled "$work" --ticket "${TICKET[$work]}" --held "$held" --deliver \
          --note "finished work with no next step for ${held}s: ${LINE[$work]}" >/dev/null ;;
      *) { alert climb "$key" 2>/dev/null || true; } | alert deliver >/dev/null ;;
    esac
  done
}

cmd_open() {
  local work any=1
  resolve_taken
  while IFS= read -r work; do
    if [ -n "${SINCE[$work]+x}" ]; then printf '%s\n' "${LINE[$work]}"
    else printf '%s: its done line still owes a next step (alert done-unhandled--%s is open)\n' "$work" "$work"; fi
    any=0
  done < <(live_works)
  return "$any"
}

"cmd_$op"
