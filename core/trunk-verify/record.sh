#!/usr/bin/env bash
# Every verify ends with one record (ticket verify-dies-silently): sourced by bin/jg-trunk.sh, never run.
#
# A verify that stopped without writing anything (a signal, a crash, a refusal, a gate shard with no result, a kill -9) left the tip
# looking never verified, so `verify-due` started the same run again and again, the green pin never moved and go-live stayed blocked.
# The verify is now an explicit machine with one owner (this file) and one record per attempt:
#   open        --green-->       closed   the whole range passed; the pin moved                         (vr_end green)
#   open        --red-->         closed   a failed test is charged to a commit                           (vr_end red)
#   open        --incomplete-->  closed   it ended with no verdict: a rerun's failure no test accounts for,
#                                         a signal, a crash or refusal (the EXIT and signal traps), or a kill the process could not see
#                                         (vr_reap, run by `verify-due`: the marker's process is gone and no verify holds the slot)
#   open        --cancel-->      closed   a newer verify superseded it before it ran: no record, it never judged anything (vr_cancel)
# An attempt is open from vr_begin until one of those moves removes its marker, state/trunk-verify-run-<project>.<attempt> (one file per
# attempt, so queued verifies never share one): the marker's removal is what makes the end happen once, so the verify's own end and a
# reaper that finds it dead cannot both write, and a verify that judges with the tip's code (core/trunk-verify/tip-code.sh) and the
# verify that started it share one attempt id (JG_VERIFY_ATTEMPT): whichever ends it first writes the record, the other finds no marker.
# The record is one row of data/trunk-verify.tsv (project, epoch, attempt, commit, result, seconds, log, reason) and a dated log
# data/trunk/verify-<attempt>.log that lists the gate's per-attempt logs and phases (the stem of bin/jg-trunk.sh gate_stem).
# A red or incomplete end also puts the commit in state/trunk-verify-last-<project>, so `verify-due` does not start the same run on
# that tip again; a repair or revert that moves the tip is due again.
# Needs from the caller: PN, STATE, DATA, put, row, verify_running, jg_lock_* (bin/jg-lock-lib.sh).

VR_ATTEMPT=''; VR_SHA=''; VR_START=0; VR_PID=''

vr_marker() { printf '%s\n' "$STATE/trunk-verify-run-$PN.$1"; }

# Open an attempt on <sha>, and end it on every way out the process can see: a signal, or any exit that comes before a verdict.
vr_begin() {  # <sha>
  VR_SHA=$1; VR_START=$SECONDS; VR_PID=${BASHPID:-$$}
  VR_ATTEMPT=''; [ -z "${JG_VERIFY_CODE_AT:-}" ] || VR_ATTEMPT=${JG_VERIFY_ATTEMPT:-}  # the tip's code joins the attempt that started it
  [ -n "$VR_ATTEMPT" ] || VR_ATTEMPT=$PN-$(date -u +%Y%m%dT%H%M%SZ)-${1:0:12}-$VR_PID-$RANDOM
  export JG_VERIFY_ATTEMPT=$VR_ATTEMPT
  mkdir -p "$STATE"
  printf '%s\t%s\t%s\t%s\n' "$VR_ATTEMPT" "$VR_SHA" "$VR_PID" "$(date +%s)" > "$(vr_marker "$VR_ATTEMPT")"
  trap 'vr_signal INT' INT; trap 'vr_signal TERM' TERM; trap 'vr_signal HUP' HUP
}

vr_signal() {  # <name>
  vr_end incomplete "the verify was stopped by signal $1 before it had a result"
  trap - INT TERM HUP
  case $1 in INT) exit 130 ;; TERM) exit 143 ;; *) exit 129 ;; esac
}

# The exit trap: an attempt still open when the process leaves ended without a verdict (a die, a refusal, a failed command).
vr_exit() {  # <exit status>
  [ -n "$VR_ATTEMPT" ] && [ "${BASHPID:-$$}" = "$VR_PID" ] || return 0
  vr_end incomplete "the verify exited with status $1 before it had a result"
}

# Close the attempt in progress with <result> (green|red|incomplete). Writes nothing when another process already ended it.
vr_end() {  # <result> <reason>
  local at=$VR_ATTEMPT m
  [ -n "$at" ] || return 0
  VR_ATTEMPT=''; m=$(vr_marker "$at")
  mv -f -- "$m" "$m.ended" 2>/dev/null || return 0
  vr_write "$at" "$VR_SHA" "$1" "$((SECONDS - VR_START))" "${GATE_STEM:-}" "$2"
  rm -f -- "$m.ended"
  [ "$1" = green ] || put "$STATE/trunk-verify-last-$PN" "$VR_SHA"
}

# A verify that ran nothing (a newer verify superseded it): its marker goes and no record is written.
vr_cancel() {
  [ -z "$VR_ATTEMPT" ] || rm -f -- "$(vr_marker "$VR_ATTEMPT")"
  VR_ATTEMPT=''
}

# Close every attempt whose process is gone and that no live verify holds: it was killed where no trap runs. Prints one line each.
vr_reap() {
  local m at sha pid started
  for m in "$STATE"/trunk-verify-run-"$PN".*; do
    [ -f "$m" ] || continue
    case $m in *.ended) continue ;; esac
    IFS=$'\t' read -r at sha pid started < "$m" || continue
    [ -n "$at" ] && [ -n "$sha" ] || continue
    ! kill -0 "$pid" 2>/dev/null || continue
    ! verify_running || continue
    mv -f -- "$m" "$m.ended" 2>/dev/null || continue
    vr_write "$at" "$sha" incomplete "$(( $(date +%s) - ${started:-0} ))" '' "the verify (process $pid) died without writing a result: it was killed or lost"
    rm -f -- "$m.ended"
    put "$STATE/trunk-verify-last-$PN" "$sha"
    echo "verify-due: closed the verify attempt $at as incomplete: its process $pid is gone"
  done
}

vr_write() {  # <attempt> <sha> <result> <seconds> <gate stem> <reason>
  local log="$DATA/trunk/verify-$1.log" stem=${5:-} f
  mkdir -p "$DATA/trunk"
  {
    printf 'verify attempt %s\nproject: %s\ncommit: %s\nresult: %s\nwhen: %s\nseconds: %s\nreason: %s\n' "$1" "$PN" "$2" "$3" "$(date -u +%FT%TZ)" "$4" "$6"
    if [ -n "$stem" ]; then
      printf 'gate stem: %s\ngate logs (one per attempt, never truncated):\n' "$stem"
      for f in "$stem".phases "$stem"-*.log; do [ -e "$f" ] && printf '  %s\n' "$f"; done
      [ ! -s "$stem.phases" ] || { printf 'gate phases (epoch, start|end, log, exit status):\n'; sed 's/^/  /' "$stem.phases"; }
    else printf 'gate stem: none (no gate had started)\n'; fi
  } > "$log"
  row trunk-verify.tsv "$PN" "$(date +%s)" "$1" "$2" "$3" "$4" "$log" "$(printf '%s' "$6" | tr '\t\n' '  ')"
}
