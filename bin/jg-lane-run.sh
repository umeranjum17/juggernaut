#!/usr/bin/env bash
# jg-lane-run.sh - run a replay or measurement harness so it dies with its lane.
# Usage: jg-lane-run.sh <task-id> -- <command> [args...]
# The harness runs in its own process group and carries a per-run token in its
# environment (JG_LANE_TOKEN), which every descendant inherits. The token is
# recorded in state/<id>.lane-groups BEFORE the harness starts. When the harness
# ends, or this wrapper is signalled, the whole group is stopped, then every
# process still carrying the token (a loop that moved to its own session) is
# stopped too: TERM, then KILL, and a survivor is reported and fails the run. If this wrapper is itself killed
# (no trap runs), bin/jg-teardown.sh stops every process still carrying a
# recorded token, including ones that left the group - the record decides, never
# a name or pattern. Exit status is the harness's. Needs bash job control, so it
# works with or without setsid(1).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"

id=${1:-}
case $id in '' | *[!A-Za-z0-9._-]* | .*) echo "usage: jg-lane-run.sh <task-id> -- <command> [args...]" >&2; exit 2 ;; esac
shift
[ "${1:-}" != -- ] || shift
[ "$#" -gt 0 ] || { echo "jg-lane-run: no command given" >&2; exit 2; }

token=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null) || token=
[ -n "$token" ] || { echo "jg-lane-run: cannot make a run token (no /proc uuid or uuidgen); nothing was started" >&2; exit 1; }
if ! { mkdir -p "$STATE" && printf '%s\n' "$token" >>"$STATE/$id.lane-groups"; }; then
  echo "jg-lane-run: cannot record the run token in $STATE/$id.lane-groups; nothing was started" >&2
  exit 1
fi

set -m
JG_LANE_TOKEN=$token "$@" </dev/null &
pgid=$!
set +m

stop_group() { # TERM, then KILL what is left, of the harness group only
  kill -TERM -- "-$pgid" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- "-$pgid" 2>/dev/null || return 0; sleep 0.1; done
  kill -KILL -- "-$pgid" 2>/dev/null || true
}

# token_pids lists every live process whose environment carries this run's token, wherever it moved
# (another session, another group, another cwd). The record decides, never a name or pattern.
token_pids() {
  local e
  for e in /proc/[0-9]*/environ; do
    [ "$e" = "/proc/$$/environ" ] && continue
    if { tr '\0' '\n' <"$e" | grep -qxF "JG_LANE_TOKEN=$token"; } 2>/dev/null; then e=${e#/proc/}; echo "${e%/environ}"; fi
  done
}
signal_token() { # $1 = signal; the token is re-read at signal time, so a reused pid is not hit
  local p
  for p in $(token_pids); do kill "-$1" "$p" 2>/dev/null || true; done
}
reap_token() { # TERM, then KILL, what carries the token but left the harness group; never leave it silent
  local left
  [ -d /proc/self ] || { echo "jg-lane-run: no /proc on this host; cannot reap harness processes that left the group" >&2; return 0; }
  left=$(token_pids)
  [ -n "$left" ] || return 0
  signal_token TERM
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(token_pids)" ] && return 0; sleep 0.1; done
  echo "jg-lane-run: $id harness process(es) ignored TERM, escalating to KILL: $(echo "$left" | tr "\n" " ")" >&2
  signal_token KILL
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(token_pids)" ] && return 0; sleep 0.1; done
  echo "jg-lane-run: REFUSED: $id harness process(es) survive KILL: $(token_pids | tr "\n" " ")" >&2
  return 1
}

trap 'stop_group; reap_token; exit 143' TERM INT HUP
wait "$pgid"
rc=$?
stop_group
reap_token || { [ "$rc" -ne 0 ] || rc=70; }
exit "$rc"
