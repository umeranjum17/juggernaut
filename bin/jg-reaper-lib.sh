#!/usr/bin/env bash
# jg-reaper-lib.sh - the deterministic stale test-browser reaper and the machine
# load alarm. bin/jg-watch.sh sources it and ticks it on the check cadence, so every
# install has it with nothing to enable.
#
# A test runner that dies leaves its browsers behind, and the kill guard refuses
# both a lead and Main. Nothing here matches a name, so a process is stopped only
# when all three hold: it is older than config/reaper-browser-age-hours (default 6),
# its --user-data-dir is inside a fleet temp or scratch root, and its owning worker
# is gone - its parent exited, or a system manager adopted the orphan. A browser
# whose launcher is still alive is left alone even when days old: that is launcher
# hygiene, not abandonment. The captain's own profile is never covered, because the
# config home is refused explicitly.
#
# Every stop logs time, pid, age, profile and reason to state/browser-reaper.log, and
# a sweep that stopped something posts one check row on the wake queue, the fleet's
# event surface. The load alarm posts one check row per episode in which every sample
# for ten minutes stayed above config/reaper-load-factor (default 2) times the core
# count, naming the top process groups by count and age.
#
# Config: reaper-off (present = do nothing), reaper-browser-age-hours, reaper-roots
# (one root per line, replacing the defaults), reaper-load-factor. Default roots:
# /tmp, /var/tmp, the jg-scratch and fm-scratch folders under the cache home, and
# every recorded state/*.scratch directory. A host without /proc (macOS) does
# nothing; ponytail: a ps(1) fallback is the upgrade if that is ever wanted.
# Fixture seams, only with JG_TEST_SEAM=1: JG_REAPER_PS (pid, age, ppid, comm,
# profile rows) and JG_REAPER_LOADAVG (a file shaped like /proc/loadavg). A marked
# fixture with no table named does nothing, so a suite that starts a real watcher
# never reaps a process on the host running it.

JG_REAPER_STATE=${STATE:-${JG_STATE_OVERRIDE:-${JG_HOME:-}/state}}
JG_REAPER_CONFIG=${JG_CONFIG_OVERRIDE:-${CONFIG:-${JG_HOME:-}/config}}
JG_REAPER_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}

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

jg_reaper_table() { # print "pid age ppid comm profile" rows, TAB separated
  local fixture=${JG_REAPER_PS:-} d pid rest ppid comm dir arg hz up starttime age
  if [ "${JG_TEST_SEAM:-}" = 1 ] && [ -n "$fixture" ] && [ -r "$fixture" ]; then
    cat "$fixture"
    return 0
  fi
  hz=$(getconf CLK_TCK 2>/dev/null) || hz=100
  up=$(awk '{printf "%d", $1; exit}' /proc/uptime 2>/dev/null) || up=0
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    read -r rest 2>/dev/null <"$d/stat" || continue
    # Field 1 is state here, so ppid is 2 and starttime (field 22 in the file) is 20.
    # shellcheck disable=SC2086 # Deliberate: these are the stat fields to split.
    set -- ${rest##*') '}
    ppid=${2:-} starttime=${20:-}
    case $ppid$starttime in '' | *[!0-9]*) continue ;; esac
    [ -n "$ppid" ] && [ -n "$starttime" ] || continue
    age=$((up - starttime / hz))
    [ "$age" -ge 0 ] || age=0
    comm=$(cat "$d/comm" 2>/dev/null) || comm=''
    dir=''
    while IFS= read -r -d '' arg; do
      case $arg in --user-data-dir=?*) dir=${arg#--user-data-dir=} && break ;; esac
    done 2>/dev/null <"$d/cmdline" # stderr first: a process that exits mid-scan must not print its open error
    # The reader going away (the sweep was stopped) ends the table: a runner that
    # ignores SIGPIPE would otherwise walk every remaining process, one write error each.
    { printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$age" "$ppid" "$comm" "$dir"; } 2>/dev/null || return 0
  done
}

jg_reaper_sweep() { # stop every process that meets all three conditions
  local roots=() limit pid age ppid comm dir stopped=0 oldest=0 oldest_dir='' root
  limit=$(jg_reaper_cfg reaper-browser-age-hours)
  case $limit in '' | *[!0-9]* | 0) limit=6 ;; esac
  limit=$((limit * 3600))
  while IFS= read -r root; do [ -n "$root" ] && roots+=("$root"); done < <(jg_reaper_roots)
  [ "${#roots[@]}" -gt 0 ] || return 0
  while IFS=$'\t' read -r pid age ppid comm dir; do
    case $pid in '' | *[!0-9]*) continue ;; esac
    case $age in '' | *[!0-9]*) continue ;; esac
    [ -n "$dir" ] && [ "$age" -ge "$limit" ] || continue
    jg_reaper_candidate "$dir" "${roots[@]}" || continue
    jg_reaper_owner_gone "$ppid" || continue
    kill -TERM "$pid" 2>/dev/null || continue
    stopped=$((stopped + 1))
    jg_reaper_log "stopped pid=$pid age=${age}s profile=$dir reason=age-over-${limit}s,fleet-profile-root,owning-worker-gone"
    if [ "$age" -gt "$oldest" ]; then oldest=$age oldest_dir=$dir; fi
  done < <(jg_reaper_table)
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

jg_reaper_load_alarm() { # one wake per episode of load above factor times cores
  local now load cores threshold state first src=/proc/loadavg
  now=$(date +%s)
  [ "${JG_TEST_SEAM:-}" = 1 ] && [ -n "${JG_REAPER_LOADAVG:-}" ] && src=$JG_REAPER_LOADAVG
  load=$(awk 'NF { print $1; exit }' "$src" 2>/dev/null) || load=''
  case $load in '' | *[!0-9.]*) return 0 ;; esac
  cores=$(nproc 2>/dev/null || echo 1)
  case $cores in '' | *[!0-9]* | 0) cores=1 ;; esac
  threshold=$(jg_reaper_cfg reaper-load-factor)
  case $threshold in '' | *[!0-9]* | 0) threshold=2 ;; esac
  threshold=$((cores * threshold))
  state=$JG_REAPER_STATE/.browser-reaper-load
  if ! awk -v l="$load" -v t="$threshold" 'BEGIN { exit !(l > t) }'; then
    rm -f "$state" "$state.raised" 2>/dev/null || true
    return 0
  fi
  first=$(cat "$state" 2>/dev/null) || first=''
  case $first in '' | *[!0-9]*) first=$now; printf '%s\n' "$first" >"$state" 2>/dev/null || true ;; esac
  [ $((now - first)) -ge 600 ] && [ ! -e "$state.raised" ] || return 0
  : >"$state.raised" 2>/dev/null || true
  jg_reaper_wake browser-reaper-load \
    "check: machine load $load above $threshold over $cores cores for $(( (now - first) / 60 )) min: top process groups: $(jg_reaper_load_groups)"
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
