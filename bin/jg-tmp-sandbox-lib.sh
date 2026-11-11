#!/usr/bin/env bash
# jg-tmp-sandbox-lib.sh - the test-sandbox pass of bin/jg-tmp-reaper.sh (sourced, never run).
#
# A test run that hangs leaves its fixture behind with processes still running in it (trunk-landing and trunk verify
# fixtures; each one slows every real landing). This pass stops those processes and removes the fixture folder once
# the sandbox is older than its own timeout. It acts on a sandbox only when ALL of these hold:
#   - it is a top-level entry of the temp root named jg-trunk.* or tmp.*, a real directory (never a symlink), owned
#     by the running user,
#   - it holds a trunk-landing tree: a bin/jg-trunk.sh or core/trunk-landing/trunk-landing.sh below it (symlinks are
#     not followed, so a link back to a live checkout does not qualify),
#   - it is not a task root: no gotmp directory, no state/<id>.meta of this home for jg-<id>, and no recorded task
#     meta that names the folder,
#   - no process in it carries a recorded task: a process whose environment names a JG_TASK_ID with a state/<id>.meta
#     in this home (or in its own state directory, when that lies outside the sandbox) keeps the whole sandbox.
#
# Its age is the age of its oldest process (the sandboxes that matter are the ones still running); a sandbox with no
# process is as old as the newest change inside it. The timeout is the one-line number of seconds in the sandbox's
# own .jg-sandbox-timeout file, else JG_TMP_SANDBOX_TIMEOUT_SEC (default 3600). A sandbox at or past its timeout has
# its processes sent TERM, then KILL when they stay after a short grace, and its folder removed. Each stop and removal
# is logged to state/tmp-reaper.log.
#
# The caller sets STATE, TMP_ROOT and LOG, and provides is_task_root and remove_entry (bin/jg-tmp-reaper.sh).
# Liveness is read from /proc, so a host without /proc stops and removes nothing.

JG_SANDBOX_TIMEOUT_DEFAULT=${JG_TMP_SANDBOX_TIMEOUT_SEC:-3600}
JG_SANDBOX_GRACE_SEC=${JG_TMP_SANDBOX_GRACE_SEC:-2}

# True for a name that may be a test sandbox; the folder checks come after.
sandbox_name() {  # <base>
  case "$1" in jg-trunk.?* | tmp.?*) return 0 ;; esac
  return 1
}

sandbox_has_trunk_tree() {  # <dir>
  [ -n "$(find "$1" -maxdepth 5 \( -path '*/bin/jg-trunk.sh' -o -path '*/core/trunk-landing/trunk-landing.sh' \) -type f -print -quit 2>/dev/null)" ]
}

# A recorded task meta in this home that names the folder makes it a live task's folder.
sandbox_named_by_meta() {  # <dir>
  local f
  # shellcheck disable=SC2153  # STATE is set by the sourcing bin/jg-tmp-reaper.sh
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    grep -qF -- "$1" "$f" 2>/dev/null && return 0
  done
  return 1
}

sandbox_timeout() {  # <dir>: print the timeout in seconds
  local t
  t=$(sed -n '1p' "$1/.jg-sandbox-timeout" 2>/dev/null | tr -d ' \t')
  case "$t" in '' | *[!0-9]* | 0) t=$JG_SANDBOX_TIMEOUT_DEFAULT ;; esac
  case "$t" in '' | *[!0-9]* | 0) t=3600 ;; esac
  printf '%s\n' "$t"
}

# One line per process that works in <dir>: "<pid> <age seconds>". Skips this process and its ancestors.
sandbox_holders() {  # <dir>
  local d pid cwd stat rest hz up start age skip=" $$ " p
  hz=$(getconf CLK_TCK 2>/dev/null) || hz=100
  up=$(awk '{ printf "%d", $1; exit }' /proc/uptime 2>/dev/null) || return 0
  p=$$
  while [ "${p:-0}" -gt 1 ]; do
    p=$(awk '{ sub(/^[0-9]+ \(.*\) /, ""); print $2; exit }' "/proc/$p/stat" 2>/dev/null) || break
    case "$p" in '' | *[!0-9]*) break ;; esac
    skip="$skip$p "
  done
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    case "$skip" in *" $pid "*) continue ;; esac
    [ -O "$d" ] || continue
    cwd=$(readlink "$d/cwd" 2>/dev/null) || cwd=''
    case "$cwd" in "$1" | "$1"/*) ;; *)
      tr '\0' '\n' < "$d/cmdline" 2>/dev/null | grep -qE -- "(^|[^[:alnum:]_.-])$(printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g')(/|\$)" || continue ;;
    esac
    read -r stat 2>/dev/null < "$d/stat" || continue
    rest=${stat##*) }
    # shellcheck disable=SC2086  # Deliberate: split the stat fields; starttime is the 20th after the state.
    set -- $rest
    start=${20:-}
    case "$start" in '' | *[!0-9]*) continue ;; esac
    age=$((up - start / hz))
    [ "$age" -ge 0 ] || age=0
    printf '%s %s\n' "$pid" "$age"
  done
}

# 0 when the process carries a recorded task: JG_TASK_ID plus a state/<id>.meta in this home or its own state directory.
sandbox_process_has_task() {  # <pid> <sandbox dir>
  local var task='' home='' state=''
  while IFS= read -r -d '' var; do
    case "$var" in
      JG_TASK_ID=?*) task=${var#JG_TASK_ID=} ;;
      JG_HOME=?*) home=${var#JG_HOME=} ;;
      JG_STATE_OVERRIDE=?*) state=${var#JG_STATE_OVERRIDE=} ;;
    esac
  done 2>/dev/null < "/proc/$1/environ"
  case "$task" in '' | */* | .*) return 1 ;; esac
  [ -e "$STATE/$task.meta" ] && return 0
  [ -n "$state" ] || { [ -n "$home" ] && state=$home/state; } || return 1
  case "$state" in "$2" | "$2"/*) return 1 ;; esac
  [ -e "$state/$task.meta" ]
}

sandbox_newest_age() {  # <dir>: seconds since the newest change inside
  local newest
  newest=$(find "$1" -printf '%T@\n' 2>/dev/null | sort -nr | head -n 1)
  newest=${newest%%.*}
  case "$newest" in '' | *[!0-9]*) printf '0\n'; return ;; esac
  printf '%s\n' $(($(date +%s) - newest))
}

# Stop every listed pid: TERM, a short grace, then KILL for the ones still there.
sandbox_stop() {  # <pid>...
  local pid n=0 left
  for pid in "$@"; do kill -TERM "$pid" 2>/dev/null && n=$((n + 1)); done
  [ "$n" -gt 0 ] || return 0
  sleep "$JG_SANDBOX_GRACE_SEC"
  left=''
  for pid in "$@"; do [ -d "/proc/$pid" ] && left="$left $pid"; done
  # shellcheck disable=SC2086  # a short list of numeric pids
  [ -z "$left" ] || kill -KILL $left 2>/dev/null || true
}

reap_sandboxes() {
  local entry base pid age timeout oldest pids holders have_task line
  [ -d /proc/self ] || return 0
  while IFS= read -r -d '' entry; do
    base=${entry##*/}
    sandbox_name "$base" || continue
    is_task_root "$entry" && continue
    sandbox_has_trunk_tree "$entry" || continue
    sandbox_named_by_meta "$entry" && continue
    holders=$(sandbox_holders "$entry")
    pids=() oldest=0 have_task=0
    while read -r pid age; do
      [ -n "$pid" ] || continue
      if sandbox_process_has_task "$pid" "$entry"; then have_task=1; break; fi
      pids+=("$pid")
      [ "$age" -le "$oldest" ] || oldest=$age
    done <<< "$holders"
    [ "$have_task" -eq 0 ] || continue
    [ "${#pids[@]}" -gt 0 ] || oldest=$(sandbox_newest_age "$entry")
    timeout=$(sandbox_timeout "$entry")
    [ "$oldest" -ge "$timeout" ] || continue
    if [ "${#pids[@]}" -gt 0 ]; then
      sandbox_stop "${pids[@]}"
      line="stopped ${#pids[@]} processes"
    else
      line="no processes"
    fi
    if remove_entry "$entry"; then
      printf '%s sandbox-reaped %s (%s, age %ss, timeout %ss)\n' "$(date -u +%FT%TZ)" "$entry" "$line" "$oldest" "$timeout" >> "$LOG"
    fi
  done < <(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -user "$(id -u)" -type d \( -name 'jg-trunk.*' -o -name 'tmp.*' \) -print0 2>/dev/null)
}
