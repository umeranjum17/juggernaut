#!/usr/bin/env bash
# quota-failover watcher check: prints the wake lines the last passes left in
# state/quota-failover.wake as one line (the watcher's check: wake), then
# starts the next pass detached, since a pass's live tests outlast a check.
# Usage: check.sh <jg-home>
set -u
wake=$1/state/quota-failover.wake
mv -f "$wake" "$wake.$$" 2>/dev/null && { JG_HOME=$1 JG_STATE_OVERRIDE=$1/state "$1/bin/jg-alert.sh" capacity quota-failover "$(paste -sd ';' "$wake.$$")" --print; rm -f "$wake.$$"; }
setsid -f "$(cd "$(dirname "$0")" && pwd)/quota-failover" "$1" >/dev/null 2>&1 </dev/null
