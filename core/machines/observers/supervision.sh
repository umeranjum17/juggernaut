#!/usr/bin/env bash
# supervision.sh - report-only observer of the supervisor-session machine (core/machines/tables/supervision.tsv): one word per home.
#
# Usage: supervision.sh [<home-name>]   print off, starting, watching, handling or read-only (the id names the home; this home is read)
# Records read, never written:
#   read-only  state/.lock-refused holds the pid of a live session that was refused the lock (the diagnostic record; no writer yet)
#   off        no state/.lock, or its first line is not a live pid
#   handling   the lock is live and state/.wake-queue is not empty
#   watching   the lock is live and state/.last-watcher-beat is not older than the lock
#   starting   the lock is live and the watcher has not beaten since the lock was taken
# The command only reads: it takes no lock and drains no wake.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
alive() { case $1 in ''|*[!0-9]*) return 1;; esac; kill -0 "$1" 2>/dev/null; }
pid=$(sed -n 1p "$STATE/.lock" 2>/dev/null)
if alive "$pid"; then :; else
  alive "$(sed -n 1p "$STATE/.lock-refused" 2>/dev/null)" && echo read-only || echo off
  exit 0
fi
[ -s "$STATE/.wake-queue" ] && { echo handling; exit 0; }
[ -e "$STATE/.last-watcher-beat" ] && [ ! "$STATE/.lock" -nt "$STATE/.last-watcher-beat" ] && { echo watching; exit 0; }
echo starting
