#!/usr/bin/env bash
# jg-reaper-lib.sh - the deterministic stale test-browser reaper and the machine
# load alarm. bin/jg-watch.sh sources it and ticks it on the check cadence, so every
# install has it with nothing to enable.
#
# A test runner that dies leaves its browsers behind, and the kill guard refuses
# both a lead and Main. Nothing here matches a name. A browser is a process whose
# own argv carries --user-data-dir; only a browser root is judged (a process whose
# parent carries the same profile is that browser's child and goes with it). The
# captain's own profile is never covered, because the config home is refused
# explicitly. The whole decision, in order (the first row that matches wins):
#
#   profile outside every fleet temp or scratch root       -> keep (not the fleet's)
#   younger than config/reaper-browser-age-hours (def. 6)  -> keep (young)
#   neither owner signal below says gone                   -> keep (owner live)
#   its environment names a JG_TASK_ID whose task record
#     (<JG_HOME>/state/<id>.meta) still exists             -> keep (live owner task)
#   otherwise                                              -> stop, log, one wake
#
# The two owner signals, either of which says the owner is gone:
#   owning-worker-gone - its parent exited, or a system manager adopted the orphan.
#   job-ended - it runs in a transient systemd-run scope (run-p<pid>-i<n>.scope, the
#     heavy-job memory gate's wrapper), and <pid>, the job's own main process, is no
#     longer alive in that scope. A launcher daemon left behind in the same scope
#     keeps the browser's parent alive for days; the scope says the job is over.
#
# Every stop logs time, pid, age, profile and reason to state/browser-reaper.log, and
# a sweep that stopped something posts one check row on the wake queue, the fleet's
# event surface. The load alarm posts one check row per episode in which every sample
# for config/reaper-load-minutes (default 10) stayed above config/reaper-load-factor
# (default 2) times the core count, naming the top process groups by count and age.
# Machine load is one host fact, so the alarm has one owner, the main home: a lead
# home (it carries the squad-lead marker, bin/jg-primary-scope-lib.sh) neither
# samples nor raises it, so no lead spends a model turn on a fact Main already
# holds. The sweep's own stop event still wakes whichever home stopped the browser.
#
# The load history is the alarm's episode record, state/.browser-reaper-load: the
# epoch of the first sample above the limit, removed by any sample at or under it.
# jg_reaper_load_over is its one reader: bin/jg-spawn.sh defers a new lane while the
# record is a whole window old and the current sample is still above the limit, so a
# load back under the limit admits at once, before the next sample clears the record.
#
# Config: reaper-off (present = do nothing), reaper-browser-age-hours, reaper-roots
# (one root per line, replacing the defaults), reaper-load-factor, reaper-load-minutes.
# Default roots: /tmp, /var/tmp, the jg-scratch and fm-scratch folders under the
# cache home, and every recorded state/*.scratch directory. A host without /proc (macOS) does
# nothing; ponytail: a ps(1) fallback is the upgrade if that is ever wanted.
# Fixture seams, only with JG_TEST_SEAM=1: JG_REAPER_PS (pid, age, ppid, comm,
# profile, job rows; the scope and environment checks still read the real pid's
# /proc entries) and JG_REAPER_LOADAVG (a file shaped like /proc/loadavg). A marked
# fixture with no table named does nothing, so a suite that starts a real watcher
# never reaps a process on the host running it.

JG_REAPER_STATE=${STATE:-${JG_STATE_OVERRIDE:-${JG_HOME:-}/state}}
JG_REAPER_CONFIG=${JG_CONFIG_OVERRIDE:-${CONFIG:-${JG_HOME:-}/config}}
JG_REAPER_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}
JG_REAPER_HOME=${JG_HOME:-}
_jg_reaper_dir=${BASH_SOURCE[0]%/*}
[ "$_jg_reaper_dir" != "${BASH_SOURCE[0]}" ] || _jg_reaper_dir=.
# shellcheck source=bin/jg-primary-scope-lib.sh
. "$_jg_reaper_dir/jg-primary-scope-lib.sh"
unset _jg_reaper_dir

jg_reaper_cfg() { cat "$JG_REAPER_CONFIG/$1" 2>/dev/null || true; } # <name>

jg_reaper_log() { # <line>: append one timestamped stop-log line
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >>"$JG_REAPER_STATE/browser-reaper.log" 2>/dev/null || true
}

jg_reaper_wake() { # <key> <payload>: one check row, only when a wake queue exists
  declare -F jg_wake_append >/dev/null && jg_wake_append check "$1" "$2" 2>/dev/null || true
}

jg_reaper_roots() { # print the fleet temp and scratch roots, one per line
  local f
  if [ -f "$JG_REAPER_CONFIG/reaper-roots" ]; then
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's:/*$::' "$JG_REAPER_CONFIG/reaper-roots"
    return 0
  fi
  printf '%s\n' /tmp /var/tmp "$JG_REAPER_CACHE/jg-scratch" "$JG_REAPER_CACHE/fm-scratch"
  for f in "$JG_REAPER_STATE"/*.scratch; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    sed -e '/^[[:space:]]*$/d' -e 's:/*$::' "$f"
  done
}

jg_reaper_candidate() { # <profile-dir> <root>...: 0 when that profile may be reaped
  local dir=$1 root
  shift
  case $dir in /*) ;; *) return 1 ;; esac
  case $dir/ in "${XDG_CONFIG_HOME:-$HOME/.config}"/*) return 1 ;; esac
  [ "$dir" != "${HOME%/}" ] || return 1
  for root in "$@"; do case $dir/ in "$root"/*) return 0 ;; esac; done
  return 1
}

jg_reaper_owner_gone() { # <ppid>: 0 when that worker is gone, 1 when it is live
  local comm
  case $1 in '' | *[!0-9]*) return 0 ;; esac
  [ "$1" -gt 1 ] || return 0
  [ -d "/proc/$1" ] || return 0
  comm=$(cat "/proc/$1/comm" 2>/dev/null) || comm=''
  case $comm in systemd | init | launchd | "(sd-pam)" | systemd-journal*) return 0 ;; esac
  return 1
}

jg_reaper_cgroup() { # <pid>: print its unified (cgroup v2) path; nothing without one
  local line
  while IFS= read -r line; do
    case $line in 0::?*) printf '%s\n' "${line#0::}" && return 0 ;; esac
  done 2>/dev/null <"/proc/$1/cgroup"
  return 0
}

jg_reaper_job_ended() { # <pid> <job>: 0 when <job>, the main pid its scope names, left it
  local own
  case $2 in '' | *[!0-9]*) return 1 ;; esac
  own=$(jg_reaper_cgroup "$1")
  [ -n "$own" ] || return 1
  # A reused pid in another cgroup is not the job, so the job has ended.
  [ "$(jg_reaper_cgroup "$2")" != "$own" ]
}

jg_reaper_task_live() { # <pid>: 0 when its environment names a task whose record exists
  local var task='' home='' state=''
  while IFS= read -r -d '' var; do
    case $var in
      JG_TASK_ID=?*) task=${var#JG_TASK_ID=} ;;
      JG_HOME=?*) home=${var#JG_HOME=} ;;
      JG_STATE_OVERRIDE=?*) state=${var#JG_STATE_OVERRIDE=} ;;
    esac
  done 2>/dev/null <"/proc/$1/environ"
  case $task in '' | */* | .*) return 1 ;; esac
  [ -n "$state" ] || { [ -n "$home" ] && state=$home/state; } || state=$JG_REAPER_STATE
  [ -e "$state/$task.meta" ]
}

jg_reaper_table() { # print "pid age ppid comm profile job" rows, TAB separated
  local fixture=${JG_REAPER_PS:-} d pid rest ppid comm dir arg hz up starttime age job
  if [ "${JG_TEST_SEAM:-}" = 1 ] && [ -n "$fixture" ] && [ -r "$fixture" ]; then
    cat "$fixture"
    return 0
  fi
  hz=$(getconf CLK_TCK 2>/dev/null) || hz=100
  up=$(awk '{printf "%d", $1; exit}' /proc/uptime 2>/dev/null) || up=0
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    read -r rest 2>/dev/null <"$d/stat" || continue
    # The stat line is "pid (comm) state ...": comm ends at its last ") ", so no
    # second read (and no fork) is needed for it.
    comm=${rest#*\(} && comm=${comm%\) *}
    # Field 1 is state here, so ppid is 2 and starttime (field 22 in the file) is 20.
    # shellcheck disable=SC2086 # Deliberate: these are the stat fields to split.
    set -- ${rest##*') '}
    ppid=${2:-} starttime=${20:-}
    case $ppid$starttime in '' | *[!0-9]*) continue ;; esac
    [ -n "$ppid" ] && [ -n "$starttime" ] || continue
    age=$((up - starttime / hz))
    [ "$age" -ge 0 ] || age=0
    dir='' job=''
    while IFS= read -r -d '' arg; do
      case $arg in --user-data-dir=?*) dir=${arg#--user-data-dir=} && break ;; esac
    done 2>/dev/null <"$d/cmdline" # stderr first: a process that exits mid-scan must not print its open error
    if [ -n "$dir" ]; then # only a browser needs its scope: one more read, never for every process
      job=$(jg_reaper_cgroup "$pid") && job=${job##*/}
      case $job in run-p[0-9]*-i*.scope) job=${job#run-p} && job=${job%%-*} ;; *) job='' ;; esac
    fi
    # The reader going away (the sweep was stopped) ends the table: a runner that
    # ignores SIGPIPE would otherwise walk every remaining process, one write error each.
    { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$age" "$ppid" "$comm" "$dir" "$job"; } 2>/dev/null || return 0
  done
}

jg_reaper_sweep() { # stop every browser root the decision in the header says to stop
  local roots=() limit pid age ppid comm dir job why stopped=0 oldest=0 oldest_dir='' root
  local browsers='' keys='' nl=$'\n' tab=$'\t'
  limit=$(jg_reaper_cfg reaper-browser-age-hours)
  case $limit in '' | *[!0-9]* | 0) limit=6 ;; esac
  limit=$((limit * 3600))
  while IFS= read -r root; do [ -n "$root" ] && roots+=("$root"); done < <(jg_reaper_roots)
  [ "${#roots[@]}" -gt 0 ] || return 0
  browsers=$(jg_reaper_table | awk -F '\t' '$5 != ""')
  keys=$nl$(awk -F '\t' '{ print $1 FS $5 }' <<<"$browsers")$nl # "pid<TAB>profile" per browser
  while IFS=$'\t' read -r pid age ppid comm dir job; do
    case $pid in '' | *[!0-9]*) continue ;; esac
    case $age in '' | *[!0-9]*) continue ;; esac
    [ -n "$dir" ] && [ "$age" -ge "$limit" ] || continue
    jg_reaper_candidate "$dir" "${roots[@]}" || continue
    # A child of a browser (zygote, renderer, gpu) carries the same profile and ends with its root.
    case $keys in *"$nl$ppid$tab$dir$nl"*) continue ;; esac
    if jg_reaper_owner_gone "$ppid"; then
      why='owning-worker-gone'
    elif jg_reaper_job_ended "$pid" "$job"; then
      why='job-ended'
    else
      continue
    fi
    ! jg_reaper_task_live "$pid" || continue
    kill -TERM "$pid" 2>/dev/null || continue
    stopped=$((stopped + 1))
    jg_reaper_log "stopped pid=$pid age=${age}s profile=$dir reason=age-over-${limit}s,fleet-profile-root,$why"
    if [ "$age" -gt "$oldest" ]; then oldest=$age oldest_dir=$dir; fi
  done <<<"$browsers"
  [ "$stopped" -gt 0 ] || return 0
  jg_reaper_wake browser-reaper \
    "check: browser reaper stopped $stopped stale test browsers: oldest ${oldest}s at $oldest_dir (state/browser-reaper.log)"
}

jg_reaper_load_groups() { # print the top process groups by count, with oldest age
  jg_reaper_table | awk -F '\t' '
    NF >= 4 && $4 != "" { n[$4]++; if ($2 + 0 > age[$4]) age[$4] = $2 + 0 }
    END { for (c in n) printf "%d\t%s\t%d\n", n[c], c, age[c] }' |
    sort -k1,1nr | head -5 | awk -F '\t' '{ printf "%s%s %d (oldest %dh)", (NR > 1 ? ", " : ""), $2, $1, int($3 / 3600) }'
}

jg_reaper_load_now() { # print the one-minute host load, or nothing when unreadable
  local src=/proc/loadavg
  [ "${JG_TEST_SEAM:-}" = 1 ] && [ -n "${JG_REAPER_LOADAVG:-}" ] && src=$JG_REAPER_LOADAVG
  awk 'NF { print $1; exit }' "$src" 2>/dev/null || true
}

jg_reaper_load_settings() { # <config-dir>: set JG_REAPER_LOAD_CORES, _LIMIT and _WINDOW (seconds)
  local factor minutes
  JG_REAPER_LOAD_CORES=$(nproc 2>/dev/null || echo 1)
  case $JG_REAPER_LOAD_CORES in '' | *[!0-9]* | 0) JG_REAPER_LOAD_CORES=1 ;; esac
  factor=$(cat "$1/reaper-load-factor" 2>/dev/null) || factor=''
  case $factor in '' | *[!0-9]* | 0) factor=2 ;; esac
  minutes=$(cat "$1/reaper-load-minutes" 2>/dev/null) || minutes=''
  case $minutes in '' | *[!0-9]* | 0) minutes=10 ;; esac
  JG_REAPER_LOAD_LIMIT=$((JG_REAPER_LOAD_CORES * factor))
  JG_REAPER_LOAD_WINDOW=$((minutes * 60))
}

jg_reaper_load_above() { # <load> <limit>: 0 when the load is a number above the limit
  case $1 in '' | *[!0-9.]*) return 1 ;; esac
  awk -v l="$1" -v t="$2" 'BEGIN { exit !(l > t) }'
}

jg_reaper_load_over() { # <state-dir> <config-dir>: 0 while the load history says the host is over its limit
  local first load now
  JG_REAPER_LOAD_WHY=''
  [ ! -e "$2/reaper-off" ] || return 1
  first=$(cat "$1/.browser-reaper-load" 2>/dev/null) || return 1
  case $first in '' | *[!0-9]*) return 1 ;; esac
  jg_reaper_load_settings "$2"
  now=$(date +%s)
  [ $((now - first)) -ge "$JG_REAPER_LOAD_WINDOW" ] || return 1
  load=$(jg_reaper_load_now)
  jg_reaper_load_above "$load" "$JG_REAPER_LOAD_LIMIT" || return 1
  # shellcheck disable=SC2034 # read by bin/jg-spawn.sh after sourcing.
  JG_REAPER_LOAD_WHY="machine load $load above $JG_REAPER_LOAD_LIMIT over $JG_REAPER_LOAD_CORES cores for $(((now - first) / 60)) min"
}

jg_reaper_load_alarm() { # main home only: one wake per episode of load above factor times cores
  local now load state first
  ! jg_root_is_squad_lead_home "$JG_REAPER_HOME" || return 0
  now=$(date +%s)
  load=$(jg_reaper_load_now)
  case $load in '' | *[!0-9.]*) return 0 ;; esac
  jg_reaper_load_settings "$JG_REAPER_CONFIG"
  state=$JG_REAPER_STATE/.browser-reaper-load
  if ! jg_reaper_load_above "$load" "$JG_REAPER_LOAD_LIMIT"; then
    rm -f "$state" "$state.raised" 2>/dev/null || true
    return 0
  fi
  first=$(cat "$state" 2>/dev/null) || first=''
  case $first in '' | *[!0-9]*) first=$now; printf '%s\n' "$first" >"$state" 2>/dev/null || true ;; esac
  [ $((now - first)) -ge "$JG_REAPER_LOAD_WINDOW" ] && [ ! -e "$state.raised" ] || return 0
  : >"$state.raised" 2>/dev/null || true
  jg_reaper_wake browser-reaper-load \
    "check: machine load $load above $JG_REAPER_LOAD_LIMIT over $JG_REAPER_LOAD_CORES cores for $(( (now - first) / 60 )) min: top process groups: $(jg_reaper_load_groups)"
}

jg_reaper_tick() { # once per watcher check cadence: the sweep, then the alarm
  local cadence now last marker
  [ ! -e "$JG_REAPER_CONFIG/reaper-off" ] || return 0
  [ "${JG_TEST_SEAM:-}" != 1 ] || [ -n "${JG_REAPER_PS:-}" ] || return 0
  cadence=${CHECK_INTERVAL:-300}
  case $cadence in '' | *[!0-9]* | 0) cadence=300 ;; esac
  marker=$JG_REAPER_STATE/.browser-reaper-sweep
  now=$(date +%s)
  last=$(stat -c %Y "$marker" 2>/dev/null || /usr/bin/stat -f %m "$marker" 2>/dev/null)
  case $last in '' | *[!0-9]*) last=0 ;; esac
  [ "$last" -eq 0 ] || [ $((now - last)) -ge "$cadence" ] || return 0
  touch "$marker" 2>/dev/null || true
  jg_reaper_sweep
  jg_reaper_load_alarm
  return 0
}
