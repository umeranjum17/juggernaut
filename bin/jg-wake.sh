#!/usr/bin/env bash
# jg-wake.sh - one supervision entry point over the durable wake queue: `next`
# drains, classifies, and reports in a single call, replacing a drain plus a hand
# classification of what came back. The drain still owns presentation, open
# decisions, unread status lines, record divergence, branch outcomes, watcher
# liveness, and the exact WAKE_ACK_REQUIRED command; `next` returns its exit code and
# adds which rows are the wakes this turn exists for, that the rest wait for a turn,
# and how many events were recorded since the last report. `settled [COUNT]` prints
# the last record-only events. docs/watcher-continuity.md "Wake urgency classes" owns
# the classes, the threshold, and the batch cadence.
#
# Usage: jg-wake.sh next [--ack-through SEQUENCE --recovery-generation GENERATION]
#        jg-wake.sh settled [COUNT]
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"

case "${1:-}" in
  next)
    shift
    rc=0
    at=
    "$SCRIPT_DIR/jg-wake-drain.sh" "$@" || rc=$?
    since=$(cat "$STATE/.wake-settled.cursor" 2>/dev/null || echo 0)
    case "$since" in ''|*[!0-9]*) since=0 ;; esac
    printf '\n--- wake classes (%s) ---\nnow     the row(s) above are the wakes this turn exists for\n' \
      "$(jg_wake_routing_file)"
    silent_n=$(awk -F '\t' -v c="$since" 'NF >= 5 && $1 > c { n++ } END { print n + 0 }' \
      "$STATE/.wake-settled" 2>/dev/null) && [ -n "$silent_n" ] || silent_n=0
    printf 'batch   any other queued row waits for a turn, so routine events cost no turn of their own\n'
    printf 'silent  %s event(s) recorded since the last report (jg-wake.sh settled)\n' "$silent_n"
    jg_epoch_seconds_to at
    printf '%s\n' "$at" > "$STATE/.wake-settled.cursor" 2>/dev/null || true
    exit "$rc"
    ;;
  settled)
    shift
    count=${1:-20}
    case "$count" in ''|*[!0-9]*) count=20 ;; esac
    tail -n "$count" "$STATE/.wake-settled" 2>/dev/null || echo "no record-only event yet"
    ;;
  *) echo "usage: jg-wake.sh next|settled  (see the header of this script)" >&2; exit 2 ;;
esac
