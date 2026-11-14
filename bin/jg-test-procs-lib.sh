#!/usr/bin/env bash
# jg-test-procs-lib.sh - find and stop the processes a test started (sourced, never run).
#
# A test marks every process it starts through its environment: tests/lib.sh and bin/jg-test-run.sh export
# JG_TEST_FIXTURE_PROC=<owner pid>, and a child inherits it. That mark is the only proof a process belongs to a test, so a
# process without it is never listed here, whatever its name or command line says.
#   - tests/lib.sh and bin/jg-test-run.sh stop what carries their own pid when they exit (jg_test_procs_stop_marked).
#   - bin/jg-tmp-reaper.sh stops what carries any mark, names a jg-* path in the temp root and is older than an hour
#     (reap_test_procs), the backstop for a suite that was SIGKILLed before it could clean up.
# Liveness is read from /proc, so a host without /proc lists and stops nothing. This process and its ancestors are never listed.

JG_TEST_PROC_VAR=JG_TEST_FIXTURE_PROC
JG_TEST_PROC_GRACE_SEC=${JG_TEST_PROC_GRACE_SEC:-2}

# Every pid of the running user whose environment holds the mark; <owner> limits it to one owner pid, else any mark.
jg_test_procs_marked() {  # [<owner pid>]
  local owner=${1:-} pattern skip=" $$ " p f pid
  [ -d /proc/self ] || return 0
  if [ -n "$owner" ]; then pattern="^$JG_TEST_PROC_VAR=$owner\$"; else pattern="^$JG_TEST_PROC_VAR=[0-9][0-9]*\$"; fi
  p=$$
  while [ "${p:-0}" -gt 1 ]; do
    p=$(awk '{ sub(/^[0-9]+ \(.*\) /, ""); print $2; exit }' "/proc/$p/stat" 2>/dev/null) || break
    case "$p" in '' | *[!0-9]*) break ;; esac
    skip="$skip$p "
  done
  # -z reads each NUL-separated variable as a line, so one grep covers every process.
  while IFS= read -r f; do
    pid=${f#/proc/}; pid=${pid%/environ}
    case "$skip" in *" $pid "*) continue ;; esac
    [ -O "/proc/$pid" ] && printf '%s\n' "$pid"
  done < <(grep -alz -e "$pattern" /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n')
  return 0
}

# Seconds a process has run.
jg_test_proc_age() {  # <pid>
  local stat rest hz up start fields
  hz=$(getconf CLK_TCK 2>/dev/null) || hz=100
  up=$(awk '{ printf "%d", $1; exit }' /proc/uptime 2>/dev/null) || return 1
  read -r stat 2>/dev/null < "/proc/$1/stat" || return 1
  rest=${stat##*) }
  # shellcheck disable=SC2206  # Deliberate: split the stat fields; starttime is the 20th after the state.
  fields=($rest)
  start=${fields[19]:-}
  case "$start" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s\n' $((up - start / hz))
}

# TERM, a short grace, then KILL for the ones still there.
jg_test_procs_stop() {  # <pid>...
  local pid n=0 left=''
  for pid in "$@"; do kill -TERM "$pid" 2>/dev/null && n=$((n + 1)); done
  [ "$n" -gt 0 ] || return 0
  sleep "$JG_TEST_PROC_GRACE_SEC"
  for pid in "$@"; do [ -d "/proc/$pid" ] && left="$left $pid"; done
  # shellcheck disable=SC2086  # a short list of numeric pids
  [ -z "$left" ] || kill -KILL $left 2>/dev/null || true
}

# What this owner started and left running: stopped when the owner exits.
jg_test_procs_stop_marked() {  # <owner pid>
  local pids
  pids=$(jg_test_procs_marked "$1" | tr '\n' ' ')
  # shellcheck disable=SC2086  # numeric pids
  [ -z "$pids" ] || jg_test_procs_stop $pids
}

# The reaper pass: a marked process that names $TMP_ROOT/jg-* and is at least JG_TMP_TEST_PROC_AGE_SEC old (default 3600).
# The caller sets TMP_ROOT and LOG.
reap_test_procs() {
  local min=${JG_TMP_TEST_PROC_AGE_SEC:-3600} pid age cmd stopped=0
  case "$min" in '' | *[!0-9]*) min=3600 ;; esac
  while read -r pid; do
    [ -n "$pid" ] || continue
    cmd=$({ tr '\0' '\n' < "/proc/$pid/cmdline"; } 2>/dev/null) || continue
    case "$cmd" in *"$TMP_ROOT"/jg-*) ;; *) continue ;; esac
    age=$(jg_test_proc_age "$pid") || continue
    [ "$age" -ge "$min" ] || continue
    printf '%s test-process-reaped pid %s (age %ss): %s\n' "$(date -u +%FT%TZ)" "$pid" "$age" "$(printf '%s' "$cmd" | head -c 200 | tr '\n' ' ')" >> "$LOG"
    jg_test_procs_stop "$pid"
    stopped=$((stopped + 1))
  done < <(jg_test_procs_marked)
  return 0
}
