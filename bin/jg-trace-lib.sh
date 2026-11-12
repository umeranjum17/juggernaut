#!/usr/bin/env bash
# jg-trace-lib.sh - the one call every writer makes to put a moment on a ticket's trail.
#
# jg_trace_record <task or ticket> <kind> <ref-kind> <ref> --source <source> [--at <epoch>] [--payload <json>] ...
#   Runs `jg-backlog.sh trace record`: the provenance event first, then the time on the row. A failed write is one warning line and
#   returns 1; a spawn, a landing or a merge never stops for a trail that could not be written.
[ -z "${_JG_TRACE_LIB:-}" ] || return 0
_JG_TRACE_LIB=1
_jg_trace_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

jg_trace_record() {
  local out
  if ! out=$(JG_HOME="${JG_HOME:-$_jg_trace_dir/..}" "$_jg_trace_dir/jg-backlog.sh" trace record "$@" 2>&1); then
    printf 'warning: trace record %s %s failed: %s\n' "${1:-?}" "${2:-?}" "$(printf '%s' "$out" | head -n 1)" >&2
    return 1
  fi
}
