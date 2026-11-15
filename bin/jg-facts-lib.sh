#!/usr/bin/env bash
# jg-facts-lib.sh - the typed facts a guard reads about ready, proof, retry and cursor, one reader per fact.
#
# Each reader prints `key<TAB>value` lines and changes nothing. The writers that used to decide from text, a file name or an
# environment variable now ask the same reader, so the fact a guard reads is the fact the writer acted on. `jg-machine-guard.sh fact`
# prints any of them (docs: core/machines/README.md "Facts").
#
#   jg_fact_reuse                                          proof: the effective sealed-proof reuse switch, its source and whether its value is valid
#   jg_fact_writer <ref> <new-sha>                         proof: the trunk-writer capability the reference-transaction hook reads, for one ref move
#   jg_fact_ready <state-dir> <id>                         ready: whether the lane's last status line is a done report, and its epoch
#   jg_fact_flush <flush-file> <ready> <oldest> <now> <at-ready> <after-min>    ready: whether a queue's flush is due, and why
#   jg_fact_sweep_retry <state-dir> <mem-dir> <id> <now> <start-s>              retry: the never-started relaunch budget and the next step
#   jg_fact_wake <state-dir> <file>                        cursor: the reported and classified positions of one wake stream
#   jg_fact_lane_waited <state-dir> <id> <recon-phase> <agent-state cmd...>   waited: whether anyone waits for the lane's agent, and why
#
# The *_effective, *_at, *_due and *_next forms print one word (or return a status) for a caller that needs only the decision.

jg_fact_num() { case ${1:-} in '' | *[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
jg_fact_mtime() { stat -c %Y "$1" 2>/dev/null || date +%s; }
jg_fact_val() {  # <facts> <key>: one value out of a reader's output
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { print $2; exit }'
}

# --- proof reuse switch (bin/jg-trunk.sh sealed_run_covers) -------------------------------------------------------------
# JG_TRUNK_SEALED_REUSE=0 forces the tests to run; every other value, and no value, allows reuse.
jg_fact_reuse_effective() { [ "${JG_TRUNK_SEALED_REUSE:-1}" = 0 ] && echo off || echo on; }
jg_fact_reuse() {
  local src=default valid=yes
  if [ -n "${JG_TRUNK_SEALED_REUSE+x}" ]; then
    src="env"
    case $JG_TRUNK_SEALED_REUSE in 0 | 1) ;; *) valid=no ;; esac
  fi
  printf 'value\t%s\nsource\t%s\nvalid\t%s\neffective\t%s\n' "${JG_TRUNK_SEALED_REUSE:--}" "$src" "$valid" "$(jg_fact_reuse_effective)"
}

# --- trunk writer capability (the reference-transaction hook of bin/jg-trunk.sh ensure_guard) ----------------------------
# An internal, process-local capability: a nonempty JG_TRUNK_WRITER lets a ref move forward, and JG_TRUNK_RETIRE equal to the ref
# lets that one ref be deleted. It is never owner consent and never an authenticated identity.
jg_fact_writer() {  # <ref> <new-sha>
  local ref=$1 new=$2 move=forward cap=none
  case $new in *[!0]*) ;; *) move=delete ;; esac
  if [ "$move" = delete ]; then [ "${JG_TRUNK_RETIRE:-}" = "$ref" ] && cap=retire
  else [ -z "${JG_TRUNK_WRITER:-}" ] || cap="write"; fi
  printf 'scope\tprocess-env\nref\t%s\nmove\t%s\nwriter\t%s\nretire\t%s\ncapability\t%s\noutcome\t%s\n' \
    "$ref" "$move" "$([ -n "${JG_TRUNK_WRITER:-}" ] && echo set || echo unset)" "${JG_TRUNK_RETIRE:-none}" "$cap" \
    "$([ "$cap" = none ] && echo refused || echo allowed)"
}

# --- ready: the worker's done report and the queue's flush (core/trunk-landing/trunk-landing.sh) -------------------------
# The last line of state/<id>.status is `done [at=<epoch>]: ...`. Prints the epoch (0 when the line names none), status 1 when the
# lane is not ready.
jg_fact_ready_at() {  # <state-dir> <id>
  local line; line=$(tail -n 1 "$1/$2.status" 2>/dev/null || true)
  case $line in done\ * | done:*) printf '%s\n' "$(printf '%s' "$line" | sed -n 's/^done[^[]*\[at=\([0-9]*\)\].*/\1/p')" | grep . || echo 0 ;; *) return 1 ;; esac
}
jg_fact_ready() {  # <state-dir> <id>
  local at line why=ok ready=yes
  line=$(tail -n 1 "$1/$2.status" 2>/dev/null || true)
  if at=$(jg_fact_ready_at "$1" "$2"); then [ "$at" != 0 ] || why='done line names no time'
  else ready=no; at=-; [ -n "$line" ] && why="last line is ${line%%[ :]*}" || why='no status line'; fi
  printf 'ready\t%s\nready_at\t%s\nreason\t%s\n' "$ready" "$at" "$why"
}
# A queue's ready lanes wait until <at-ready> of them are ready, or the oldest has waited <after-min> minutes, or a flush was asked.
jg_fact_flush_reason() {  # <flush-file> <ready> <oldest> <now> <at-ready> <after-min>
  if [ -e "$1" ]; then echo requested
  elif [ "$2" -ge "$5" ]; then echo count
  elif [ $(( $4 - $3 )) -ge $(( $6 * 60 )) ]; then echo age
  else echo none; fi
}
jg_fact_flush_due() { [ "$(jg_fact_flush_reason "$@")" != none ]; }
jg_fact_flush() {
  local why; why=$(jg_fact_flush_reason "$@")
  printf 'flush\t%s\nreason\t%s\nready\t%s\noldest\t%s\nat_ready\t%s\nafter_minutes\t%s\n' "$([ "$why" = none ] && echo wait || echo due)" "$why" "$2" "$3" "$5" "$6"
}

# --- retry: the lead sweep's relaunch budget for a lane that never wrote a status line (core/lead-sweep/lead-sweep.sh) ------
# One relaunch, then the lane is parked. The clock runs from the lane's record, or from the relaunch once there was one.
jg_fact_lane_lock_held() { ls "$1"/.trunk-run-"$2"-*.lock >/dev/null 2>&1; }
jg_fact_sweep_retry() {  # <state-dir> <mem-dir> <id> <now> <start-s>
  local state=$1 mem=$2 id=$3 now=$4 start=$5 since tried basis=record nxt parked=no lock=none
  since=$(jg_fact_mtime "$state/$id.meta"); tried=$(head -n 1 "$mem/$id.relaunched" 2>/dev/null)
  case $tried in '' | *[!0-9]*) tried=0 ;; esac
  [ "$tried" -le "$since" ] || { since=$tried; basis=relaunch; }
  [ ! -e "$state/$id.parked" ] || parked=yes
  jg_fact_lane_lock_held "$state" "$id" && lock=held
  if [ "$parked" = yes ] || [ "$lock" = held ]; then nxt=none
  elif [ $(( now - since )) -lt "$start" ]; then nxt="wait"
  elif [ "$tried" -eq 0 ]; then nxt="relaunch"
  else nxt="park"; fi
  printf 'retries\t%s\nbudget\t1\nclock_since\t%s\nclock_basis\t%s\nparked\t%s\nlock\t%s\nnext\t%s\n' "$([ "$tried" -eq 0 ] && echo 0 || echo 1)" "$since" "$basis" "$parked" "$lock" "$nxt"
}

# --- waited: whether anyone waits for the agent of a lane (core/lead-sweep, bin/jg-worker-stop-alert.sh) -------------------
# A lane's last status line says what the worker reported, not whether the work is over: a steer or a relaunch after a done line makes
# the lane live again (machine worker, edge done -> working "rework"). The agent of a waited-for lane is never ended unseen. Reasons, in order:
#   steer       an unread steer is in state/<id>.inbox/
#   round       the lane is a Recon whose draft has an open critic round (phase drafted, assigned or critiqued; the caller reads it
#               from core/machines/observers/recon.sh, and passes none when the lane has no handoff record)
#   steer-read  a steer is newer than the lane's last status line (the worker took it and has not reported since)
#   relaunched  the agent is alive and its last exit record is newer than the last status line: it was started again after the lane ended
# The agent state (alive, dead, missing, unknown) is asked only for the last reason, as the trailing command: `<cmd...>` prints it.
jg_fact_lane_waited() {  # <state-dir> <id> <recon-phase> <agent-state cmd...>
  local state=$1 id=$2 phase=$3 inbox why=- unread oldest=0 f at status_at exited
  shift 3
  inbox=$state/$id.inbox
  unread=$(find "$inbox" -maxdepth 1 -type f -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
  status_at=$(stat -c %Y "$state/$id.status" 2>/dev/null || echo 0)
  if [ "$unread" -gt 0 ]; then
    why=steer
    for f in "$inbox"/*.msg; do at=$(stat -c %Y "$f" 2>/dev/null || echo 0); [ "$oldest" -ne 0 ] && [ "$at" -ge "$oldest" ] || oldest=$at; done
  else
    case $phase in drafted | assigned | critiqued) why=round ;; esac
    if [ "$why" = - ] && [ -n "$(find "$inbox/handled" -maxdepth 1 -type f -name '*.msg' -newer "$state/$id.status" 2>/dev/null | head -n 1)" ]; then why=steer-read; fi
    if [ "$why" = - ]; then
      exited=$(head -n 1 "$state/$id.exit" 2>/dev/null); case $exited in '' | *[!0-9]*) exited=0 ;; esac
      if [ "$exited" -gt "$status_at" ] && [ "$("$@" 2>/dev/null)" = alive ]; then why=relaunched; fi
    fi
  fi
  printf 'waited\t%s\nreason\t%s\nunread\t%s\nsince\t%s\n' "$([ "$why" = - ] && echo no || echo yes)" "$why" "$unread" "$oldest"
}

# --- cursor: the positions of one wake stream (bin/jg-wake-lib.sh) -------------------------------------------------------
# Needs bin/jg-wake-lib.sh sourced. `reported` is whether the file's signature was announced; `classified` is the byte position
# already read; `pending` is what lies beyond it. A marker that is missing or unreadable reads as position 0, which classifies the
# whole file rather than losing an event, and `reset` says which of the two it was.
jg_fact_wake() {  # <state-dir> <file>
  local marker classified size reported=stale rst=none
  marker=$(jg_wake_signal_seen_path "$1" "$2")
  size=$(stat -c %s "$2" 2>/dev/null || echo 0)
  classified=$(jg_wake_signal_seen_size "$1" "$2")
  jg_wake_signal_reported_current "$1" "$2" && reported=current
  if [ ! -e "$marker" ]; then rst="marker-absent"
  elif [ "$classified" -eq 0 ] && [ "$size" -gt 0 ] && [ "$reported" = stale ]; then rst="unreadable"
  elif [ "$classified" -gt "$size" ]; then rst="file-shrunk"; fi
  printf 'stream\t%s\nreported\t%s\nclassified\t%s\nsize\t%s\npending\t%s\nreset\t%s\n' "$(basename "$marker")" "$reported" "$classified" "$size" "$(( size > classified ? size - classified : 0 ))" "$rst"
}
