#!/usr/bin/env bash
# dispatch-start.sh - report-only observer of the dispatch-start machine (core/machines/tables/dispatch-start.tsv).
#
# Usage: dispatch-start.sh <ticket-id>   print ready, starting, started, deferred or refused; print nothing for a ticket with no approval record
# core/auto-dispatch/dispatch.sh owns the reader (the start records data/auto-dispatch/<id>.start.<attempt> and the lane record). It only reads.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
bash "$root/core/auto-dispatch/dispatch.sh" state "$JG_HOME" "${1:?usage: dispatch-start.sh <ticket-id>}" 2>/dev/null || true
