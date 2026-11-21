#!/usr/bin/env bash
# jg-worker-stop-alert.sh - an agent that someone waits for is never ended or lost unseen: one P1 alert to the lane's owner at once.
#
# Usage:
#   jg-worker-stop-alert.sh waited <id> [<agent-state>]     print why someone waits for the lane's agent and exit 0; print nothing and exit 1 when
#                                                           nobody does. <agent-state> (alive, dead, missing, unknown) skips the backend query.
#   jg-worker-stop-alert.sh raise <id> ended|lost <why>     raise the worker-stopped alert (P1, first rung Main, never quiet) for the lane at once
#
# Whether someone waits is one typed fact (bin/jg-facts-lib.sh jg_fact_lane_waited): an unread steer in the lane's inbox, an open Recon critic
# round, a steer newer than its last status line, or a relaunch after its done line. The callers ask before they act, because ending an agent
# changes the answer for the last reason:
#   bin/jg-control.sh exit        asks before the stop and raises `ended` once the stop is proven
#   core/lead-sweep               never ends a waited-for agent; it raises `lost` when a waited-for agent is already dead or missing
# `ended` is a new episode, so it resolves the lane's earlier alert and rings again; `lost` keeps one live alert per lane (the sweep runs every beat).
# The alert is delivered through bin/jg-alert.sh at once (--deliver): a check wake for Main, climbing to the captain when it is not answered.
# JG_HOME and JG_STATE_OVERRIDE name the home. Exit: 0 waited / raised, 1 nobody waits, 2 usage.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$HERE/.." && pwd -P)
HOME_DIR=${JG_HOME:-$ROOT}
STATE=${JG_STATE_OVERRIDE:-$HOME_DIR/state}
# shellcheck source=bin/jg-facts-lib.sh
. "$HERE/jg-facts-lib.sh"
usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
mval() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

cmd_waited() {
  local id=$1 agent=${2:-} meta=$STATE/$1.meta phase=none facts
  [ -f "$meta" ] || return 1
  if [ "$(mval "$meta" kind)" = scout ]; then
    phase=$(JG_HOME="$HOME_DIR" JG_DATA_OVERRIDE="$HOME_DIR/data" JG_STATE_OVERRIDE="$STATE" "$ROOT/core/machines/observers/recon.sh" "$id" 2>/dev/null || echo none)
    [ -n "$phase" ] || phase=none
  fi
  if [ -n "$agent" ]; then facts=$(jg_fact_lane_waited "$STATE" "$id" "$phase" echo "$agent")
  else
    # shellcheck disable=SC2016  # the single-quoted body is the child shell's own script
    facts=$(jg_fact_lane_waited "$STATE" "$id" "$phase" bash -c '. "$1/jg-backend.sh" >/dev/null 2>&1 && jg_backend_agent_state "$(jg_backend_of_meta "$2")" "$(jg_backend_target_of_meta "$2")" "$2" "$3"' _ "$HERE" "$meta" "$id")
  fi
  [ "$(jg_fact_val "$facts" waited)" = yes ] || return 1
  jg_fact_val "$facts" reason
}

cmd_raise() {
  local id=$1 how=$2 why=$3 ticket
  case $how in ended | lost) ;; *) usage ;; esac
  ticket=$(mval "$STATE/$id.meta" ticket); ticket=${ticket:-$id}
  [ "$how" != ended ] || JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE" "$HERE/jg-alert.sh" resolve "worker-stopped--$id" --proof source:ended >/dev/null 2>&1 || true
  JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE" "$HERE/jg-alert.sh" raise worker-stopped "$id" --deliver --ticket "$ticket" \
    --note "the agent of $id was $how while someone waits for it ($why); relaunch it or answer its steer" >/dev/null
}

[ "$#" -ge 2 ] || usage
op=$1; id=$2; shift 2
case $id in '' | */* | *..*) usage ;; esac
case $op in
  waited) cmd_waited "$id" "${1:-}" ;;
  raise) [ "$#" -eq 2 ] || usage; cmd_raise "$id" "$1" "$2" ;;
  *) usage ;;
esac
