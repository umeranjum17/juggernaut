#!/usr/bin/env bash
# Shared wait-machine policy for the watcher and its escalation workflow.
export JG_WAIT_PLACEHOLDER_SECS=1800
jg_wait_machine_state() {  # <bin-directory> <task>
  local result state
  # STATE belongs to the caller.
  # shellcheck disable=SC2153
  result=$(JG_STATE_OVERRIDE="$STATE" "$1/jg-machine.sh" show wait "$2") || return 1
  state=$(printf '%s\n' "$result" | awk -F '\t' '$1 == "state" {print $2}')
  [ -n "$state" ] || { printf 'wait machine: missing state for %s\n' "$2" >&2; return 1; }
  printf '%s\n' "$state"
}
