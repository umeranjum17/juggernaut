#!/usr/bin/env bash
# jg-ready-idle.sh - the one producer of the ready-idle alert (alert table row ready-idle, core/machines/styles/alert-table.tsv).
#
# Usage:
#   jg-ready-idle.sh fire <subject>     raise ready-idle for the subject and deliver its ring: one wake to the row's first holder
#   jg-ready-idle.sh clear <prefix>     the condition ended: resolve every live ready-idle alert whose subject starts with the prefix
#                                       and withdraw its queued wake
# Every producer of a ready home (the watcher's ready-work check, the wait-timers' stalled-backlog backstop, the fleet-stall
# check) calls this instead of appending its own wake. Each producer keeps its own re-raise window, so a fire ends any live
# record of the same subject first and rings again; the alert function keeps one live record for one key.
# The subject is the producer's name, a colon, then the ready ids joined by `+`. It is cut to 100 characters of [A-Za-z0-9._+:()-].
# JG_HOME and JG_STATE_OVERRIDE name the home. Exit 0 on success, 1 when the alert function refuses, 2 on a usage error.
set -u
export LC_ALL=C
_root=$(cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/.." && pwd)
_alert() { bash "$_root/bin/jg-alert.sh" "$@"; }
_subject() { printf '%s' "$1" | tr -c 'A-Za-z0-9._+:()-' '-' | cut -c1-100; }

cmd_fire() {
  local subject ring
  subject=$(_subject "${1:?usage: fire <subject>}")
  _alert resolve "ready-idle--$subject" >/dev/null 2>&1 || true
  ring=$(_alert raise ready-idle "$subject") || exit 1
  [ -z "$ring" ] || printf '%s\n' "$ring" | _alert deliver
}

cmd_clear() {
  local prefix key
  prefix=$(_subject "${1:?usage: clear <prefix>}")
  while IFS= read -r key; do
    case $key in "ready-idle--$prefix"*) ;; *) continue ;; esac
    # shellcheck source=bin/jg-wake-lib.sh disable=SC1091
    command -v jg_wake_withdraw >/dev/null 2>&1 || . "$_root/bin/jg-wake-lib.sh"
    _alert resolve "$key" >/dev/null 2>&1 || true
    jg_wake_withdraw check "alert-$key" || true
  done < <(_alert list)
}

case ${1:-} in
  fire|clear) c=$1; shift; "cmd_$c" "$@" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
