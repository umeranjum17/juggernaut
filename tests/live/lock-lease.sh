#!/usr/bin/env bash
# Live check 2 (stop 1, every 1 min): every trunk and landing lock is younger than its lease. A lock's last sign of life is its
# `beat` (else `since`) record (core/lock-lease); the lease is JG_LOCK_LEASE_END_S, default 600 s. A lock with no record is read by mtime.
# shellcheck source=tests/live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
lease=${JG_LOCK_LEASE_END_S:-600}; now=$(live_now); n=0; old=''
for lock in "$STATE"/.trunk-*.lock; do
  [ -e "$lock" ] || continue
  n=$((n + 1))
  seen=$(cat "$lock/beat" 2>/dev/null || cat "$lock/since" 2>/dev/null || true)
  case $seen in ''|*[!0-9]*) seen=$(live_mtime "$lock") ;; esac
  [ $((now - seen)) -le "$lease" ] || old="$old ${lock##*/}($((now - seen))s)"
done
[ -z "$old" ] || live_red "lock older than its ${lease}s lease:$old"
live_pass "$n lock(s), all inside the ${lease}s lease"
