#!/usr/bin/env bash
# End the processes that a jg-run-owned.sh record names once they are past their limit or their owner is gone.
# Usage: proc.sh [--dry-run] check|list <jg-home>
#
# A record is state/owned-procs/<pid>.rec (bin/jg-run-owned.sh writes it). The reaper acts ONLY on a pid that has a record
# and whose start time still matches it (a reused pid is a different process). Per record, in order:
#   process gone                          -> the record is removed
#   within its limit and owner alive      -> kept (an owner pid of `none` has no owner to lose; the limit alone ends it)
#   past its limit, or owner gone         -> TERM to its process group (or the pid); the record notes the time (.termed)
#   TERM sent on an earlier tick, alive   -> KILL, same target
# So a process is ended inside 2 ticks. Every move is appended to state/proc-reaper.log.
# list also names an agent process (claude, codex, opencode, pi, grok, kimi, cursor, omp) whose JG_TASK_ID has no
# state/<id>.meta, as `unowned <pid> <comm> <task>` on stdout and in the log. It is never touched: only Main ends a process with no record.
# check is the watcher-check form (silent). Exit is always 0 for check and list.
set -u
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
case "${1:-}" in check|list) ;; *) echo "usage: proc.sh [--dry-run] check|list <jg-home>" >&2; exit 2 ;; esac
[ "$#" -eq 2 ] && [ -d "$2/state" ] || { echo "usage: proc.sh [--dry-run] check|list <jg-home>" >&2; exit 2; }
MODE=$1
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state
DIR=$STATE/owned-procs
LOG=$STATE/proc-reaper.log
[ -d /proc/self ] || exit 0   # liveness is read from /proc; without it nothing is ended

note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
# shellcheck disable=SC2086
start_of() { local s; s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1; s=${s##*) }; set -- $s; printf '%s' "${20}"; }
field() { sed -n "s/^$2=//p" "$1" | head -1; }
alive_same() { [ "$(start_of "$1" 2>/dev/null)" = "$2" ]; }   # <pid> <start>

signal() {  # <TERM|KILL> <pid>: to the group when the process leads its own, else to the pid alone
  local pg; pg=$(ps -o pgid= -p "$2" 2>/dev/null | tr -d ' ')
  if [ -n "$pg" ] && [ "$pg" = "$2" ]; then kill -"$1" -- "-$2" 2>/dev/null; else kill -"$1" "$2" 2>/dev/null; fi
}

reap_records() {
  local rec pid start owner opid ostart limit began now why
  [ -d "$DIR" ] || return 0
  now=$(date +%s)
  for rec in "$DIR"/*.rec; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    pid=$(field "$rec" pid); start=$(field "$rec" start)
    [[ $pid =~ ^[0-9]+$ && $start =~ ^[0-9]+$ ]] || continue
    if ! alive_same "$pid" "$start"; then
      [ "$DRY" = 1 ] || { rm -f -- "$rec" "$rec.termed"; note "gone $pid"; }
      continue
    fi
    owner=$(field "$rec" owner); opid=$(field "$rec" owner_pid); ostart=$(field "$rec" owner_start)
    limit=$(field "$rec" limit_sec); began=$(field "$rec" started)
    [[ $limit =~ ^[0-9]+$ && $began =~ ^[0-9]+$ ]] || continue
    why=
    if [ $(( now - began )) -ge "$limit" ]; then why=past-limit
    elif [ "$opid" != none ] && ! alive_same "$opid" "$ostart"; then why="owner-gone"; fi
    [ -n "$why" ] || continue
    if [ "$DRY" = 1 ]; then printf 'would end %s (%s, %s)\n' "$pid" "$owner" "$why"; continue; fi
    if [ -e "$rec.termed" ]; then signal KILL "$pid"; note "kill $pid owner=$owner why=$why"
    else : > "$rec.termed"; signal TERM "$pid"; note "term $pid owner=$owner why=$why"; fi
  done
}

AGENTS=' claude codex opencode pi grok kimi cursor omp '
name_unowned() {
  local p comm task
  for p in /proc/[0-9]*; do
    comm=$(cat "$p/comm" 2>/dev/null) || continue
    case $AGENTS in *" $comm "*) ;; *) continue ;; esac
    task=$({ tr '\0' '\n' < "$p/environ" | sed -n 's/^JG_TASK_ID=//p' | head -1; } 2>/dev/null)
    [[ $task =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
    [ ! -e "$STATE/$task.meta" ] || continue
    printf 'unowned %s %s %s\n' "${p#/proc/}" "$comm" "$task"
    [ "$DRY" = 1 ] || note "unowned ${p#/proc/} $comm $task (named, not touched)"
  done
}

reap_records
[ "$MODE" = list ] && name_unowned
exit 0
