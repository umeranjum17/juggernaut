#!/usr/bin/env bash
# lock-lease watcher check (slice H7): every trunk and landing lock of a home has a holder and a lease.
# Usage: lock-lease.check.sh <jg-home>
# A lock is state/.trunk-*.lock. Its holder record is three files (bin/jg-wake-lib.sh): pid, since (epoch it took the lock) and beat
# (epoch of its last sign of life, from jg_lock_beat; absent = none yet). The check reads each lock once per tick:
#   holder gone (pid dead, or the pid now belongs to a process that started after `since`)  -> the lock is broken at once
#   holder alive and no beat for JG_LOCK_LEASE_WARN_S (default 300)                          -> one `lock-held` alert naming the holder
#   no beat for JG_LOCK_LEASE_END_S (default 600) and the tick started the holder            -> its process group is ended, the lock broken
# "The tick started it" is read from the holder's own command line: a detached landing job (`trunk-landing.sh run|runbatch|verify|
# live|publish`) is what the landing check launches. Any other holder is never ended; it only raises the alert. The alert goes through
# the `slow-delivery` row of the alert table (bin/jg-alert.sh); the row `lock-held` is H14's rename. Prints one line per break or end,
# nothing otherwise.
set -u
FMH=${1:?usage: lock-lease.check.sh <jg-home>}
FMH=$(cd "$FMH" 2>/dev/null && pwd -P) || exit 0
WARN=${JG_LOCK_LEASE_WARN_S:-300}
END=${JG_LOCK_LEASE_END_S:-600}
export JG_HOME=$FMH
STATE=${JG_STATE_OVERRIDE:-$FMH/state}
export JG_STATE_OVERRIDE=$STATE
[ -d "$STATE" ] || exit 0
# The installed copy lives outside the repository, so the library and the alert script are the home's own.
ROOT=${JG_LOCK_LEASE_ROOT:-$FMH}
# shellcheck source=bin/jg-wake-lib.sh disable=SC1091
. "$ROOT/bin/jg-wake-lib.sh"

now=${JG_LOCK_LEASE_NOW:-$(date +%s)}  # the test seam: a later clock stands in for a long wait
hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
btime=$(awk '$1=="btime"{print $2}' /proc/stat 2>/dev/null || true)

# proc_start <pid>: the epoch the process started, empty when it cannot be read.
proc_start() {
  local stat ticks
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
  ticks=$(awk '{ sub(/^.*\) /, ""); print $20 }' <<<"$stat")
  [ -n "$ticks" ] && [ -n "$btime" ] || return 0
  echo $(( btime + ticks / hz ))
}

# gone <pid> <since>: true when the holder named by the record no longer runs.
gone() {
  local started
  kill -0 "$1" 2>/dev/null || [ -d "/proc/$1" ] || return 0
  [ -d "/proc/$1" ] || return 1
  grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2>/dev/null && return 0
  started=$(proc_start "$1")
  # A process that started after the lock was taken cannot be its holder: the pid was reused (2 s: tick resolution).
  [ -z "$started" ] || [ -z "$2" ] || [ "$started" -le $(( $2 + 2 )) ] || return 0
  return 1
}

tick_started() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -Eq 'trunk-landing\.sh (run|runbatch|verify|live|publish)( |$)'; }

for lock in "$STATE"/.trunk-*.lock; do
  [ -e "$lock" ] || [ -L "$lock" ] || continue
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  case $pid in ''|*[!0-9]*) continue ;; esac  # mid-acquire: bin/jg-wake-lib.sh owns that case
  name=${lock##*/}
  since=$(cat "$lock/since" 2>/dev/null || true)
  case $since in ''|*[!0-9]*) since=$(jg_path_mtime "$lock") ;; esac
  beat=$(cat "$lock/beat" 2>/dev/null || true)
  case $beat in ''|*[!0-9]*) beat=$since ;; esac
  [ "$beat" -ge "$since" ] || beat=$since
  if gone "$pid" "$since"; then
    [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$pid" ] || continue
    jg_lock_remove_path "$lock" || continue
    echo "lock-lease: broke $name (holder $pid is gone, lock held $(( now - since ))s)"
    continue
  fi
  idle=$(( now - beat ))
  [ "$idle" -ge "$WARN" ] || continue
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-120)
  bash "$ROOT/bin/jg-alert.sh" raise slow-delivery "lock-${name#.}" --kind ship-delivering --held "$idle" --deliver \
    --note "lock-held: $name has been held ${idle}s with no beat by process $pid ($cmd)" >/dev/null 2>&1 || true
  if [ "$idle" -ge "$END" ] && tick_started "$pid"; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do gone "$pid" "$since" && break; sleep 0.2; done
    gone "$pid" "$since" || { kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true; sleep 0.2; }
    if gone "$pid" "$since" && [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$pid" ]; then
      jg_lock_remove_path "$lock" || true
      echo "lock-lease: ended holder $pid of $name (no beat for ${idle}s, started by the tick) and broke the lock"
    fi
  fi
done
exit 0
