#!/usr/bin/env bash
# stall-action watcher check: a worker or lead whose pane output has not changed past its bound is interrupted
# through the control plane and re-rung through the steering inbox, with no model turn. Nothing is printed, so the
# check never wakes anyone.
# Usage: stall-action.sh check <jg-home>
#
# The watcher already keeps the evidence for a worker. state/.hash-<key> is rewritten only when a pane's last lines
# change, so its age is how long the output stayed the same (time spent printing is never counted).
# state/.count-<key> is rewritten on every poll, so a fresh one proves the watcher is looking at that pane right now.
# The key is the window name with `:`, `/` and `.` turned into `_` (bin/jg-watch.sh window_key). One hash covers the
# whole tail, so a hung foreground call and a hung background terminal look the same here: unchanged output.
# The watcher never hashes a squad lead's pane (an idle lead is healthy by design), so for a lead this check reads
# the pane itself with bin/jg-peek.sh and keeps its own hash and first-seen time in data/stall-action/seen/<key>.
# A task is acted on when ALL hold: its meta names a window with a hash record older than the bound (5 minutes for a
# worker, 10 for a squad lead; whole minutes in config/stall-bound-workers and config/stall-bound-leads replace
# them); the poll record is no older than 10 minutes; the task has no verified exit; its status log holds no
# declared wait (`paused:`, captain-held) and its latest event is not a captain-relevant one (done, failed,
# needs-decision, blocked: those are waiting on juggernaut, not stalled); and its semantic busy record
# (state/<id>.busy-state) does not say the agent is idle, because an agent waiting at its prompt is not stuck inside
# a call and the watcher's own stale path owns it. A task is acted on at most once in 30 minutes
# (JG_STALL_ACTION_COOLDOWN), so a harness with no busy record cannot be woken in a loop. When the classifier cannot
# answer, the task is left alone.
# One action per hash, recorded in data/stall-action/actions.jsonl: `interrupt` through bin/jg-control.sh, then
# `ring`, a steering record through bin/jg-send.sh that tells the worker its last call was cut off and to carry on.
# A failed interrupt is tried once more on a later sweep and then given up for that hash. A new hash (the pane moved
# and stalled again) is a new stall. Rollback: unwire the check (unwiring.sh); the ledger is only history.
# A BACKGROUND terminal is covered too. An agent whose turn ended reads idle in its busy record while a command it
# started (a checkpoint, a shell, a test run) hangs in its worktree, and an idle agent is otherwise left to the
# watcher's stale path. So an idle record exempts a task only when the process table shows no such command: a process
# that is neither a harness nor a bare shell, running in the task's worktree for at least JG_STALL_ACTION_BG_MIN_AGE
# seconds (default 120, which keeps a passing git or tool call out). It needs /proc and bin/jg-agent-process-lib.sh;
# where either is missing the idle record exempts as before. The re-ring then names that command.
# THE BEAT. A task that has a beat record (state/beats/<id>, written by bin/jg-beat.sh from the agent's own hooks, or from
# the busy verdict for Codex and Pi) is judged by the beat instead of the pane hash, by its last line and the bound:
#   silent          the last beat is a working one (UserPromptSubmit, PostToolBatch) and is older than the bound:
#                   interrupt, then re-ring, as for a stalled pane;
#   api-error       the last beat is a StopFailure carrying error=<type>: the turn died on that API error; re-ring only;
#   idle-no-reason  the last beat is a Stop: the agent's turn ended and its status log holds no declared wait and no
#                   captain-relevant event, so it stopped without saying why; re-ring only;
#   no-start        a Claude task has no beat and no status line this long after its meta was written: it never started;
#                   re-ring only.
# Nothing is ever hung in the last three, so there is nothing to interrupt. A task with no beat record keeps the pane rule.
# The same exemptions, cooldown and one-action-per-beat ledger apply. Seams for tests: JG_STALL_ACTION_PROC_LIB, JG_STALL_ACTION_BG_MIN_AGE, JG_STALL_ACTION_CONTROL, JG_STALL_ACTION_SEND, JG_STALL_ACTION_PEEK, JG_STALL_ACTION_CLASSIFY, JG_STALL_ACTION_NOW (epoch),
# JG_STALL_ACTION_WATCH_FRESH (seconds a poll record may be old).
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: stall-action.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
export JG_HOME=$FMH
STATE=$FMH/state
CONTROL=${JG_STALL_ACTION_CONTROL:-$FMH/bin/jg-control.sh}
SEND=${JG_STALL_ACTION_SEND:-$FMH/bin/jg-send.sh}
PEEK=${JG_STALL_ACTION_PEEK:-$FMH/bin/jg-peek.sh}
CLASSIFY=${JG_STALL_ACTION_CLASSIFY:-$FMH/bin/jg-classify.sh}
NOW=${JG_STALL_ACTION_NOW:-$(date +%s)}
FRESH=${JG_STALL_ACTION_WATCH_FRESH:-600}
COOLDOWN=${JG_STALL_ACTION_COOLDOWN:-1800}
PROC_LIB=${JG_STALL_ACTION_PROC_LIB:-$FMH/bin/jg-agent-process-lib.sh}
BG_MIN=${JG_STALL_ACTION_BG_MIN_AGE:-120}
DIR=$FMH/data/stall-action LEDGER=$DIR/actions.jsonl
START=$(date +%s) LIMIT=$(( ${JG_CHECK_TIMEOUT:-30} - 5 )); [ "$LIMIT" -ge 5 ] || LIMIT=5
BUDGET=$(( LIMIT / 3 )); [ "$BUDGET" -ge 3 ] || BUDGET=3
umask 077

minutes() {  # <config file> <default>: the whole minutes the file holds, else the default
  local v; v=$(tr -dc 0-9 2>/dev/null < "$1"); [ "${v:-0}" -gt 0 ] && printf '%s' "$v" || printf '%s' "$2"
}
WORKER_MIN=$(minutes "$FMH/config/stall-bound-workers" 5)
LEAD_MIN=$(minutes "$FMH/config/stall-bound-leads" 10)
background_job() {  # <worktree>: "<pid> <name>" of a command other than a harness or bare shell running there, else nothing
  [ -n "$1" ] && [ -d /proc/self ] && [ -r "$PROC_LIB" ] || return 0
  (
    # shellcheck source=/dev/null
    . "$PROC_LIB" 2>/dev/null || exit 0
    wt=$(cd "$1" 2>/dev/null && pwd -P) || exit 0
    for p in /proc/[0-9]*; do
      pid=${p#/proc/}; [ "$pid" != "$$" ] || continue
      cwd=$(readlink "$p/cwd" 2>/dev/null) || continue
      case "$cwd/" in "$wt"/*) ;; *) continue ;; esac
      row=$(ps -o etimes=,comm= -p "$pid" 2>/dev/null) || continue
      read -r el comm <<< "$row"; el=${el:-0}; [ -n "${comm:-}" ] && [ "$el" -ge "$BG_MIN" ] || continue
      argv0=$(tr '\0' '\n' < "$p/cmdline" 2>/dev/null | head -n 1)
      args=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
      [ "$(jg_agent_process_classify "$comm" "$argv0" "$args" "$pid")" = other ] || continue
      printf '%s %s' "$pid" "$comm"; exit 0
    done
  )
}
# <task> <meta> <bound seconds> <harness>: "<verdict> <epoch>" from the beat record, nothing when the beat shows no trouble.
# The epoch names the beat the verdict rests on (the meta's time for no-start), so one beat is acted on once.
beat_verdict() {
  local rec=$STATE/beats/$1 at ev rest
  if [ ! -s "$rec" ]; then
    [ "$4" = claude ] && [ ! -s "$STATE/$1.status" ] || return 0
    at=$(stat -c %Y "$2" 2>/dev/null) || return 0
    [ $(( NOW - at )) -ge "$3" ] && printf 'no-start %s' "$at"
    return 0
  fi
  read -r at ev rest < <(tail -n 1 "$rec") || return 0
  case "$at" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( NOW - at )) -ge "$3" ] || return 0
  case "$ev" in
    UserPromptSubmit|PostToolBatch) printf 'silent %s' "$at" ;;
    StopFailure) case "$rest" in error=*) printf 'api-error %s' "$at" ;; esac ;;
    Stop) printf 'idle-no-reason %s' "$at" ;;
  esac
}
age() { local m; m=$(stat -c %Y "$1" 2>/dev/null) && printf '%s' "$(( NOW - m ))"; }  # <file>: seconds since modified
# <task> <hash> <step> <want rc: ok|bad>: how many recorded attempts of the step.
tries() { grep -F "\"task\":\"$1\",\"hash\":\"$2\",\"step\":\"$3\"" "$LEDGER" 2>/dev/null | grep -c "\"ok\":$4" || true; }
record() { printf '{"task":"%s","hash":"%s","step":"%s","ok":%s,"at":%s}\n' "$1" "$2" "$3" "$4" "$NOW" >> "$LEDGER"; }  # <task> <hash> <step> <true|false>

mkdir -p "$DIR" 2>/dev/null || exit 0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  [ $(( $(date +%s) - START )) -lt "$LIMIT" ] || exit 0
  task=${meta##*/}; task=${task%.meta}
  window='' kind='' worktree='' harness='' vkind=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in window=*) window=${line#window=} ;; kind=*) kind=${line#kind=} ;; worktree=*) worktree=${line#worktree=} ;; harness=*) harness=${line#harness=} ;; esac
  done < "$meta"
  [ -n "$window" ] || continue
  key=${window//:/_}; key=${key//\//_}; key=${key//./_}
  [ -e "$STATE/$task.exit" ] && [ "$STATE/$task.exit" -nt "$meta" ] && continue
  if [ "$kind" = squad_lead ]; then bound=$(( LEAD_MIN * 60 )); else bound=$(( WORKER_MIN * 60 )); fi
  if [ "$kind" = squad_lead ]; then
    pane=$(timeout "$BUDGET" "$PEEK" "$task" 40 2>/dev/null) || continue
    [ -n "$pane" ] || continue
    hash=$(printf '%s' "$pane" | md5sum | cut -c1-32)
    seen=$DIR/seen/$key
    if [ "$(cut -d' ' -f1 "$seen" 2>/dev/null)" != "$hash" ]; then
      mkdir -p "$DIR/seen" && printf '%s %s\n' "$hash" "$NOW" > "$seen"
      continue
    fi
    unchanged=$(( NOW - $(cut -d' ' -f2 "$seen") ))
  elif verdict=$(beat_verdict "$task" "$meta" "$bound" "$harness"); [ -s "$STATE/beats/$task" ] || [ -n "$verdict" ]; then
    [ -n "$verdict" ] || continue
    vkind=${verdict% *}; hash=beat${verdict#* }
    unchanged=$(( NOW - ${verdict#* } ))
  else
    hashfile=$STATE/.hash-$key
    [ -f "$hashfile" ] || continue
    unchanged=$(age "$hashfile") || continue
    polled=$(age "$STATE/.count-$key") || continue
    [ "$polled" -le "$FRESH" ] || continue
    hash=$(tr -dc 'A-Za-z0-9' < "$hashfile" | cut -c1-32)
  fi
  [ -n "$hash" ] && [ "$unchanged" -ge "$bound" ] || continue
  bg=''
  if [ -z "$vkind" ] && grep -q ' state=idle ' "$STATE/$task.busy-state" 2>/dev/null; then
    bg=$(background_job "$worktree"); [ -n "$bg" ] || continue
  fi
  last_at=$(grep -F "\"task\":\"$task\"," "$LEDGER" 2>/dev/null | grep '"ok":true' | tail -n 1 | sed 's/.*"at":\([0-9]*\)}.*/\1/')
  [ -z "$last_at" ] || [ "$(( NOW - last_at ))" -ge "$COOLDOWN" ] || [ "$(tries "$task" "$hash" interrupt true)" -gt 0 ] || continue
  wait_line=$("$CLASSIFY" declared-wait "$STATE/$task.status" 2>/dev/null) || continue
  [ -z "$wait_line" ] || continue
  last=$("$CLASSIFY" last-line "$STATE/$task.status" 2>/dev/null) || continue
  if [ -n "$last" ]; then
    "$CLASSIFY" is-relevant "$last" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 1 ] || continue
  fi

  if { [ -z "$vkind" ] || [ "$vkind" = silent ]; } && [ "$(tries "$task" "$hash" interrupt true)" -eq 0 ]; then
    [ "$(tries "$task" "$hash" interrupt false)" -lt 2 ] || continue
    if timeout "$BUDGET" "$CONTROL" "$task" interrupt >/dev/null 2>&1; then
      record "$task" "$hash" interrupt true
    else
      record "$task" "$hash" interrupt false
      continue
    fi
  fi
  [ "$(tries "$task" "$hash" ring true)$(tries "$task" "$hash" ring false)" = 00 ] || continue
  mins=$(( unchanged / 60 ))
  if [ "$vkind" = api-error ]; then
    text="Your last turn ended on an API error ($(tail -n 1 "$STATE/beats/$task" | sed 's/.*error=//')) $mins minutes ago. Check where the task stands, and carry on with it."
  elif [ "$vkind" = idle-no-reason ]; then
    text="Your turn ended $mins minutes ago and your status log shows no wait and no done line. Say why you stopped: carry on with the task, or write a status line that names what you wait for."
  elif [ "$vkind" = no-start ]; then
    text="Your session showed no sign of starting in $mins minutes. Read your instructions, write a working status line and begin the task."
  elif [ -n "$bg" ]; then
    text="A background command (process ${bg% *}, ${bg#* }) has shown no new output for $mins minutes while you were idle. Check what it is waiting on, stop it or rerun it with a time limit, and carry on with the task."
  else
    text="Your last call showed no new output for $mins minutes, so it was interrupted. Check what it was waiting on, rerun it with a time limit or take another route, and carry on with the task."
  fi
  if [ "$kind" = squad_lead ]; then
    id=$(printf '%s %s' "$task" "$hash" | sha256sum | cut -c1-16)
    set -- "$task" --fire-and-forget "$id" "$text"
  else
    set -- "$task" "$text"
  fi
  if timeout "$BUDGET" "$SEND" "$@" >/dev/null 2>&1; then record "$task" "$hash" ring true; else record "$task" "$hash" ring false; fi
done
exit 0
