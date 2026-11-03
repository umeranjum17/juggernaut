#!/usr/bin/env bash
# Stop lab nats-servers whose test directory is gone.
#
# The machine-bus test and its journey start a throwaway `nats-server -c
# <tmproot>/jg-bus-machine.XXXXXX/.../bus.conf`. A run killed hard enough to skip its
# traps leaves that server alive after its directory is removed. This reaper stops exactly
# those: a process named nats-server, owned by the caller, whose `-c` config path is
# absolute, has a `jg-bus-machine.<suffix>` directory in it, and whose config directory no
# longer exists. It matches by pid and by config path and nothing else:
#
#   - a server whose config directory still exists is a live run (or another home's) and
#     is left alone;
#   - a server with no jg-bus-machine directory in its config path (the captain bus, any
#     home's real bus) is never a candidate, whatever state its files are in;
#   - a process owned by another user is never a candidate.
#
# Usage: bin/jg-bus-reap.sh [--dry-run] [--under <dir>]
# --under (or JG_BUS_REAP_UNDER) narrows the candidates to configs below <dir>, for a lab.
# Prints one `reaped <pid> <config>` line per server stopped (`would reap` with --dry-run).
set -u

dry=0
under=${JG_BUS_REAP_UNDER:-}
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --under) shift; under=${1:-}; [ -n "$under" ] || { echo "jg-bus-reap: --under needs a directory" >&2; exit 2; } ;;
    -h | --help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: jg-bus-reap.sh [--dry-run] [--under <dir>]" >&2; exit 2 ;;
  esac
  shift
done
under=${under%/}

me=$(id -u)

# conf_of <pid>: the lab config path of this pid's own command line, empty unless it is a
# nats-server owned by the caller started on an absolute jg-bus-machine config path.
conf_of() {
  local line
  line=$(ps -o uid=,comm=,args= -p "$1" 2>/dev/null) || return 0
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086 # split the ps columns on purpose
  set -- $line
  [ "$1" = "$me" ] && [ "$2" = nats-server ] || return 0
  shift 2
  local conf=
  while [ $# -gt 0 ]; do
    case "$1" in
      -c | --config) conf=${2:-}; break ;;
      -c=* | --config=*) conf=${1#*=}; break ;;
    esac
    shift
  done
  case "$conf" in
    /*/jg-bus-machine.*/*) printf '%s\n' "$conf" ;;
  esac
}

while read -r pid; do
  conf=$(conf_of "$pid")
  [ -n "$conf" ] || continue
  [ ! -d "$(dirname -- "$conf")" ] || continue
  [ -z "$under" ] || case "$conf" in "$under"/*) ;; *) continue ;; esac
  if [ "$dry" = 1 ]; then
    echo "would reap $pid $conf"
    continue
  fi
  # Re-read the pid right before the signal: it must still be the same server on the same config.
  [ "$(conf_of "$pid")" = "$conf" ] || continue
  kill "$pid" 2>/dev/null || continue
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$pid" 2>/dev/null && [ "$(conf_of "$pid")" = "$conf" ]; then kill -KILL "$pid" 2>/dev/null || true; fi
  echo "reaped $pid $conf"
done < <(ps -eo pid=,comm= | awk '$2 == "nats-server" {print $1}')
exit 0
