#!/usr/bin/env bash
# Stop leftover throwaway nats-servers from old test and journey runs.
#
# A test or journey that starts its own `nats-server` and dies before its trap runs leaves that
# server alive, holding memory, for as long as the machine is up. This lists those servers and,
# with --stop, stops them. It never matches by name alone and never calls pkill or killall: it
# reads the process table once, decides per exact pid, and prints the decision for every
# nats-server it sees before it signals anything.
#
# A server is a candidate only when ALL of these hold:
#   - it is owned by the caller;
#   - its config file (`-c`/`--config`), or with no config its store directory (`-sd`), resolves
#     (a relative path against the process's own working directory) to a path below an allowlist
#     root: /tmp, /var/tmp, $TMPDIR, and the fm-scratch and jg-scratch folders of the cache
#     home. --root <dir> (repeatable) replaces that list, for a lab;
#   - that path is not inside a real Juggernaut home (a directory with bin/jg-bus.sh, or $JG_HOME)
#     under `state/`, so a home's live bus server (state/bus/bus.conf) is never a candidate even
#     when the home sits below an allowlist root;
#   - it is older than --min-age-minutes (default 360), so a run in progress is left alone.
#
# Usage: bin/jg-stray-nats-reap.sh [--stop] [--root <dir>]... [--min-age-minutes <n>]
# Default is a dry run. Output, one line per nats-server:
#   skip <pid> <reason> <path>      not a candidate (not-yours, no-path, outside-allowlist,
#                                   live-home, too-young)
#   would stop <pid> age=<n>m <path>   dry run
#   will stop / stopped <pid> ...      with --stop: the full list first, then each stop
# A stop sends TERM to that pid, waits five seconds, then KILL if the same process is still
# there; the pid is re-checked against its command line and start time before each signal.
# Nothing is deleted.
set -u

stop=0 min_age=360
roots=()
while [ $# -gt 0 ]; do
  case "$1" in
    --stop) stop=1 ;;
    --root) shift; [ -n "${1:-}" ] || { echo "jg-stray-nats-reap: --root needs a directory" >&2; exit 2; }; roots+=("$1") ;;
    --min-age-minutes) shift; min_age=${1:-}; case "$min_age" in '' | *[!0-9]*) echo "jg-stray-nats-reap: --min-age-minutes needs a number" >&2; exit 2 ;; esac ;;
    -h | --help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: jg-stray-nats-reap.sh [--stop] [--root <dir>]... [--min-age-minutes <n>]" >&2; exit 2 ;;
  esac
  shift
done

norm() { # <abs path>: collapse //, /./ and /x/../ without touching the disk
  local part IFS=/
  local -a st=()
  set -f
  for part in $1; do
    case "$part" in
      '' | .) ;;
      ..) [ "${#st[@]}" -eq 0 ] || unset "st[${#st[@]}-1]" ;;
      *) st+=("$part") ;;
    esac
  done
  set +f
  printf '/%s\n' "${st[*]:-}"
}

if [ "${#roots[@]}" -eq 0 ]; then
  cache=${XDG_CACHE_HOME:-${HOME:-/nonexistent}/.cache}
  roots=(/tmp /var/tmp "$cache/fm-scratch" "$cache/jg-scratch")
  [ -z "${TMPDIR:-}" ] || roots+=("$TMPDIR")
fi
allow=()
for r in "${roots[@]}"; do
  case "$r" in /*) ;; *) echo "jg-stray-nats-reap: root must be absolute: $r" >&2; exit 2 ;; esac
  # Physical path when the root exists, so a symlinked /tmp matches the process's physical cwd.
  allow+=("$(norm "$(cd -P -- "$r" 2>/dev/null && pwd -P || printf '%s' "$r")")")
done
live_home=
[ -z "${JG_HOME:-}" ] || live_home=$(norm "$(cd -P -- "$JG_HOME" 2>/dev/null && pwd -P || printf '%s' "$JG_HOME")")

me=$(id -u)

age_minutes() { # <ps etime: [[dd-]hh:]mm:ss>
  local t=$1 d=0 a b c
  case "$t" in *-*) d=${t%%-*}; t=${t#*-} ;; esac
  IFS=: read -r a b c <<<"$t"
  if [ -n "${c:-}" ]; then echo $((10#$d * 1440 + 10#$a * 60 + 10#$b)); else echo $((10#$d * 1440 + 10#$a)); fi
}

argv_of() { # <pid>: the command line, one argument per line
  if [ -r "/proc/$1/cmdline" ]; then tr '\0' '\n' <"/proc/$1/cmdline"; else ps -o args= -p "$1" 2>/dev/null | tr ' ' '\n'; fi
}

ident_of() { # <pid>: command name, start time and arguments - the pid's identity
  printf '%s|%s|%s' "$(ps -o comm= -p "$1" 2>/dev/null)" "$(ps -o lstart= -p "$1" 2>/dev/null)" "$(argv_of "$1" | tr '\n' ' ')"
}

# path_of <pid>: the resolved config (else store) path, empty when it names none or cannot resolve.
path_of() {
  local cwd conf='' store='' arg prev=''
  cwd=$(readlink "/proc/$1/cwd" 2>/dev/null || true)
  cwd=${cwd% (deleted)}
  while IFS= read -r arg; do
    case "$prev" in
      -c | --config) conf=$arg ;;
      -sd | --store_dir) store=$arg ;;
    esac
    case "$arg" in
      --config=* | -c=*) conf=${arg#*=} ;;
      --store_dir=* | -sd=*) store=${arg#*=} ;;
    esac
    prev=$arg
  done < <(argv_of "$1")
  local p=${conf:-$store}
  [ -n "$p" ] || return 0
  case "$p" in /*) ;; *) [ -n "$cwd" ] || return 0; p=$cwd/$p ;; esac
  norm "$p"
}

is_live_home() { # <resolved path>: under state/ of a real Juggernaut home
  local p=$1 home
  case "$p" in */state/*) home=${p%/state/*} ;; *) return 1 ;; esac
  [ -e "$home/bin/jg-bus.sh" ] || { [ -n "$live_home" ] && [ "$home" = "$live_home" ]; }
}

cand_pid=() cand_age=() cand_path=() cand_ident=()
while read -r pid uid etime comm; do
  [ "$comm" = nats-server ] || continue
  if [ "$uid" != "$me" ]; then echo "skip $pid not-yours -"; continue; fi
  path=$(path_of "$pid")
  if [ -z "$path" ]; then echo "skip $pid no-path -"; continue; fi
  if is_live_home "$path"; then echo "skip $pid live-home $path"; continue; fi
  ok=0
  for r in "${allow[@]}"; do case "$path" in "$r"/*) ok=1 ;; esac; done
  if [ "$ok" = 0 ]; then echo "skip $pid outside-allowlist $path"; continue; fi
  age=$(age_minutes "$etime")
  if [ "$age" -lt "$min_age" ]; then echo "skip $pid too-young $path"; continue; fi
  cand_pid+=("$pid") cand_age+=("$age") cand_path+=("$path") cand_ident+=("$(ident_of "$pid")")
done < <(ps -eo pid=,uid=,etime=,comm=)

verb="would stop"
[ "$stop" = 0 ] || verb="will stop"
for i in "${!cand_pid[@]}"; do echo "$verb ${cand_pid[$i]} age=${cand_age[$i]}m ${cand_path[$i]}"; done
echo "${#cand_pid[@]} stray nats-server(s)"
if [ "$stop" = 0 ]; then
  [ "${#cand_pid[@]}" -eq 0 ] || echo "dry run: nothing stopped; add --stop to stop them"
  exit 0
fi

rc=0
for i in "${!cand_pid[@]}"; do
  pid=${cand_pid[$i]}
  # Same process still: a pid reused since the listing carries another start time or command line.
  [ "$(ident_of "$pid")" = "${cand_ident[$i]}" ] || { echo "skip $pid changed ${cand_path[$i]}"; continue; }
  kill "$pid" 2>/dev/null || { echo "failed $pid ${cand_path[$i]}"; rc=1; continue; }
  for _ in $(seq 25); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  if kill -0 "$pid" 2>/dev/null && [ "$(ident_of "$pid")" = "${cand_ident[$i]}" ]; then kill -KILL "$pid" 2>/dev/null || true; fi
  echo "stopped $pid ${cand_path[$i]}"
done
exit "$rc"
