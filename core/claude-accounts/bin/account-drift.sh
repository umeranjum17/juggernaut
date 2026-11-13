#!/usr/bin/env bash
# account-drift.sh - a lane never wakes onto an account the home no longer selects. One tick compares each live Claude lane's recorded
# account (state/<task>.meta, account=) with what the home selects for the lane's model now: the pin (config/claude-account) or the
# by-model map (config/claude-account-by-model), resolved by bin/jg-worker-account-lib.sh, the one owner of that choice.
#
# Usage: account-drift.sh tick     one pass over every live lane
# Env:   JG_HOME (required), JG_DRIFT_CONTROL (lifecycle command; default <home>/bin/jg-control.sh),
#        JG_DRIFT_ALERT (default <home>/bin/jg-alert.sh), JG_CONFIG_OVERRIDE, JG_STATE_OVERRIDE (as the rest of the home).
# Rules, each re-read every tick, so nothing is queued and "a busy lane moves at its next idle" needs no list:
#   drift   recorded account != selected account, and the lane is idle (state/<task>.busy-state says idle under the armed gen)
#           -> `jg-control.sh <task> relaunch` (a plain relaunch: it re-reads the pin and the map; the lane's inbox survives it and the
#           new agent is told to read it). A busy, unknown or unarmed lane is left alone until a later tick finds it idle.
#   failed  the lane's last beat (state/beats/<task>) is "<epoch> StopFailure ..." and its recorded account is on hold or is no longer
#           selected -> one relaunch per beat, idle or not (a failed turn has ended).
#   refused a relaunch that fails, or that leaves the record on the old account, raises one capacity alert naming the lane and the
#           account, once per wanted account; the lane is not tried again until the home selects something else.
# A home with no pin and no map selects nothing, so no lane drifts (the pool picks at launch and a running worker stays). Only Claude
# lanes with a recorded account are read. Marks are under state/account-drift/<task>.{tried,refused,beat}.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
JG_HOME=${JG_HOME:?set JG_HOME to the Juggernaut home}
CONFIG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
HOME_STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
CONTROL=${JG_DRIFT_CONTROL:-$JG_HOME/bin/jg-control.sh}
ALERT=${JG_DRIFT_ALERT:-$JG_HOME/bin/jg-alert.sh}
MARKS=$HOME_STATE/account-drift
# shellcheck source=/dev/null
. "$here/../../../bin/jg-worker-account-lib.sh"
pool_state=$(sed -n 's/^state=//p' "$CONFIG/account-pool" 2>/dev/null | head -n 1)
case "$pool_state" in /*) ;; *) pool_state=$HOME_STATE ;; esac

meta_get() { sed -n "s/^$2=//p" "$1" | tail -n 1; }  # <meta> <key>

# <task>: success when the lane's busy record says idle under the armed gen. Anything else is not idle.
lane_idle() {
  local rec=$HOME_STATE/$1.busy-state gen cur state
  [ -r "$rec" ] && [ -r "$HOME_STATE/$1.busy-gen" ] || return 1
  IFS= read -r cur <"$HOME_STATE/$1.busy-gen" || return 1
  gen=$(sed -n '1s/.* gen=\([^ ]*\).*/\1/p' "$rec")
  state=$(sed -n '1s/.* state=\([^ ]*\).*/\1/p' "$rec")
  [ -n "$cur" ] && [ "$gen" = "$cur" ] && [ "$state" = idle ]
}

# <declared account>: success when a hold names it by pool id or by folder.
account_held() {
  local f id folder
  for f in "$pool_state"/claude-accounts-held/*; do
    [ -s "$f" ] || continue
    id=${f##*/}; IFS=$'\t' read -r _at folder _r <"$f"
    [ "$1" = "$id" ] || [ "$1" = "$folder" ] && return 0
  done
  return 1
}

# <task> <account> <why>: one capacity alert per wanted account, naming the lane and the account.
refuse() {
  [ "$(cat "$MARKS/$1.refused" 2>/dev/null)" = "$2" ] && return 0
  echo "$2" >"$MARKS/$1.refused"
  "$ALERT" capacity "account-drift-$1" "lane $1 could not be moved off account ${3:-} to the account the home selects now ($2): $4" --print >/dev/null 2>&1 \
    || echo "warning: the account-drift alert for $1 was not raised" >&2
}

# <task> <recorded> <wanted>: a plain relaunch; the lane counts as moved only when its record shows the wanted account.
move() {
  local task=$1 recorded=$2 wanted=$3 out
  if ! out=$("$CONTROL" "$task" relaunch 2>&1); then
    refuse "$task" "$wanted" "$recorded" "$(printf '%s' "$out" | tail -n 1)"
    return
  fi
  echo "$wanted" >"$MARKS/$task.tried"
}

lane_tick() {
  local meta=$1 task model selected recorded beat_at ev wanted=
  task=${meta##*/}; task=${task%.meta}
  [ "$(meta_get "$meta" harness)" = claude ] || return 0
  recorded=$(meta_get "$meta" account)
  [ -n "$recorded" ] || return 0
  { [ -e "$HOME_STATE/$task.exit" ] && [ "$HOME_STATE/$task.exit" -nt "$meta" ]; } && return 0
  model=$(meta_get "$meta" model); [ "$model" != default ] || model=
  selected=$(jg_worker_account_resolve claude "$CONFIG" "$model" 2>/dev/null | cut -f1)
  if [ -z "$selected" ] || [ "$selected" = "$recorded" ]; then
    rm -f "$MARKS/$task.tried" "$MARKS/$task.refused"
    [ -n "$selected" ] || return 0
  fi
  # A stop-failure beat on a held or deselected account: one relaunch per beat, idle or not.
  read -r beat_at ev _rest < <(tail -n 1 "$HOME_STATE/beats/$task" 2>/dev/null) || true
  if [ "${ev:-}" = StopFailure ] && [ "$(cat "$MARKS/$task.beat" 2>/dev/null)" != "${beat_at:-}" ] \
    && { account_held "$recorded" || [ "$selected" != "$recorded" ]; }; then
    echo "$beat_at" >"$MARKS/$task.beat"
    move "$task" "$recorded" "${selected:-$recorded}"
    return
  fi
  [ "$selected" != "$recorded" ] || return 0
  [ "$(cat "$MARKS/$task.refused" 2>/dev/null)" != "$selected" ] || return 0
  lane_idle "$task" || return 0
  # Relaunched before for this wanted account and still recorded elsewhere: do not loop, say so once.
  if [ "$(cat "$MARKS/$task.tried" 2>/dev/null)" = "$selected" ]; then
    refuse "$task" "$selected" "$recorded" "a relaunch left the lane's record on the old account"
    return
  fi
  move "$task" "$recorded" "$selected"
}

cmd_tick() {
  local meta
  mkdir -p "$MARKS" || { echo "error: cannot write $MARKS" >&2; exit 1; }
  for meta in "$HOME_STATE"/*.meta; do
    [ -e "$meta" ] || continue
    lane_tick "$meta"
  done
}

case "${1:-}" in
  tick) cmd_tick ;;
  *) echo "usage: account-drift.sh tick" >&2; exit 2 ;;
esac
