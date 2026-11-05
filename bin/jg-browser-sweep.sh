#!/usr/bin/env bash
# jg-browser-sweep.sh - stop chrome-devtools-axi bridges and puppeteer browsers that a run left behind.
#
# Usage: jg-browser-sweep.sh [--dry-run | --apply] [--hours N] [--no-bridges]
#   --dry-run     List what would be stopped; stop nothing (default).
#   --apply       Stop it, then print the browser count before and after.
#   --hours N     Age limit in whole hours (default 24; 0 selects every match).
#   --no-bridges  Select puppeteer browsers only, never bridges.
#
# Why it exists: chrome-devtools-axi starts one bridge per session name and the
# bridge has no idle exit, so a run that never calls `chrome-devtools-axi stop`
# leaves a bridge, a chrome-devtools-mcp and a headless browser alive for good.
# Our own callers stop their session in an EXIT/INT/TERM trap; this sweep is the
# backstop for runs killed harder than a trap can handle, and for other tools.
#
# What it selects, and only at or past the age limit:
#   - a bridge: a node process whose script is chrome-devtools-axi-bridge.js.
#     It is stopped with `chrome-devtools-axi stop` for its own session (read from
#     the bridge's environment); if the bridge is still alive after that, TERM then
#     KILL go to that bridge and its descendants, found from the process table.
#   - a puppeteer browser: a chrome process with no --type= whose own argument is
#     --user-data-dir=<prefix>* (default /tmp/puppeteer_dev_chrome_profile-). TERM
#     then KILL go to that process and its descendants.
# It never selects the user's real Chrome (no such profile argument), a process
# whose command line only mentions the path (the executable must be chrome), a
# process younger than the limit, or itself. Before KILL it re-reads the command
# line, so a reused pid is not hit. After the kills it removes the profile folder
# of a stopped browser, and one older than the limit that no process names, only
# when it is a real folder (never a link) owned by this user, directly under the
# prefix's parent, with a name made of letters and digits after the prefix.
#
# Not wired to a periodic check: jg-sentinel runs on every home and its tests run
# on real hosts, so an automatic kill of other lanes' sessions stays a manual call.
#
# Test seams: JG_BROWSER_SWEEP_PS_FILE (ps -eo pid=,ppid=,etimes=,args= text),
# JG_BROWSER_SWEEP_SESSIONS_FILE ("<pid> <session>" lines) and
# JG_BROWSER_SWEEP_PROFILE_PREFIX.
# Exit: 0 after a pass, 1 when something selected is still alive, 2 for usage.
set -u

MODE=dry-run
HOURS=24
BRIDGES=1
PREFIX=${JG_BROWSER_SWEEP_PROFILE_PREFIX:-/tmp/puppeteer_dev_chrome_profile-}

while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) MODE=dry-run ;;
    --apply) MODE=apply ;;
    --no-bridges) BRIDGES=0 ;;
    --hours) shift; HOURS=${1:-} ;;
    --hours=*) HOURS=${1#--hours=} ;;
    -h|--help) sed -n '2,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "jg-browser-sweep: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
case $HOURS in ''|*[!0-9]*) echo "jg-browser-sweep: --hours needs a whole number" >&2; exit 2 ;; esac
LIMIT=$(( HOURS * 3600 ))

snapshot() {
  if [ -n "${JG_BROWSER_SWEEP_PS_FILE:-}" ]; then cat "$JG_BROWSER_SWEEP_PS_FILE"; else ps -ww -eo pid=,ppid=,etimes=,args=; fi
}

# select <limit> <prefix> <bridges 0|1> <self pid>: read the process table on stdin, print
# "bridge <pid> <age>" and "browser <pid> <age> <profile>" for each match.
select_matches() {
  awk -v limit="$1" -v prefix="$2" -v bridges="$3" -v self="$4" '
    function base(p) { sub(/.*\//, "", p); return p }
    $1 == self || $3 < limit { next }
    {
      exe = $4
      if (bridges && base(exe) ~ /^node/) {
        for (i = 5; i <= NF; i++) if ($i ~ /(^|\/)chrome-devtools-axi-bridge\.js$/) { print "bridge", $1, $3; next }
      }
      if (base(exe) !~ /^(chrome|google-chrome|google-chrome-stable|chromium|chromium-browser)$/) next
      prof = ""
      for (i = 5; i <= NF; i++) {
        if ($i ~ /^--type=/) { prof = ""; break }
        if (index($i, "--user-data-dir=" prefix) == 1) prof = substr($i, 17)
      }
      if (prof != "") print "browser", $1, $3, prof
    }'
}

session_of() {
  local pid=$1 s=
  if [ -n "${JG_BROWSER_SWEEP_SESSIONS_FILE:-}" ]; then
    s=$(awk -v p="$pid" '$1 == p { print $2; exit }' "$JG_BROWSER_SWEEP_SESSIONS_FILE")
  else
    s=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^CHROME_DEVTOOLS_AXI_SESSION=//p' | head -n1)
  fi
  printf '%s' "$s"
}

# tree <pid>: the pid and every descendant, from the snapshot on stdin.
tree() {
  awk -v root="$1" '
    { par[$1] = $2; all[++n] = $1 }
    END {
      keep[root] = 1
      do { grew = 0; for (i = 1; i <= n; i++) { p = all[i]; if (!(p in keep) && (par[p] in keep)) { keep[p] = 1; grew = 1 } } } while (grew)
      for (p in keep) print p
    }'
}

alive() { kill -0 "$1" 2>/dev/null; }
cmdline() { ps -ww -o args= -p "$1" 2>/dev/null; }

# stop_tree <pid>: TERM the tree, wait, then KILL only the pids whose command line is unchanged.
stop_tree() {
  local root=$1 p snap
  snap=$(ps -ww -eo pid=,ppid=,etimes=,args=)
  local -A cmd=()
  local pids
  pids=$(printf '%s\n' "$snap" | tree "$root")
  for p in $pids; do cmd[$p]=$(cmdline "$p"); kill -TERM "$p" 2>/dev/null || true; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    local any=0
    for p in $pids; do alive "$p" && any=1; done
    [ "$any" -eq 0 ] && return 0
    sleep 0.5
  done
  for p in $pids; do
    if alive "$p" && [ "$(cmdline "$p")" = "${cmd[$p]}" ]; then kill -KILL "$p" 2>/dev/null || true; fi
  done
}

remove_profile() {
  local dir=$1 parent name
  parent=$(dirname -- "$PREFIX")
  name=${dir#"$PREFIX"}
  case $dir in "$PREFIX"*) ;; *) return 0 ;; esac
  case $name in ''|*[!A-Za-z0-9]*) return 0 ;; esac
  [ "$(dirname -- "$dir")" = "$parent" ] || return 0
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 0
  # Match in the shell, not with grep: a grep named here would list itself in the table.
  case " $(snapshot) " in *"--user-data-dir=$dir "*|*"--user-data-dir=$dir"$'\n'*) return 0 ;; esac
  rm -rf -- "$dir" && echo "removed profile $dir"
}

count_browsers() { snapshot | select_matches 0 "$PREFIX" 0 $$ | grep -c '^browser ' || true; }
count_bridges() { snapshot | select_matches 0 "$PREFIX" 1 $$ | grep -c '^bridge ' || true; }

matches=$(snapshot | select_matches "$LIMIT" "$PREFIX" "$BRIDGES" $$)
before_browsers=$(count_browsers)
before_bridges=$(count_bridges)
rc=0
stopped_profiles=

while read -r kind pid age prof; do
  [ -n "${kind:-}" ] || continue
  if [ "$kind" = bridge ]; then
    sess=$(session_of "$pid")
    label="bridge pid=$pid session=${sess:-unknown} age=$(( age / 3600 ))h"
    if [ "$MODE" = dry-run ]; then echo "would stop $label"; continue; fi
    echo "stop $label"
    if [ -n "$sess" ] && command -v chrome-devtools-axi >/dev/null 2>&1; then
      CHROME_DEVTOOLS_AXI_SESSION=$sess timeout 20 chrome-devtools-axi stop >/dev/null 2>&1 || true
    fi
    if alive "$pid"; then stop_tree "$pid"; fi
    if alive "$pid"; then echo "STILL ALIVE bridge pid=$pid"; rc=1; fi
  else
    label="browser pid=$pid profile=$prof age=$(( age / 3600 ))h"
    if [ "$MODE" = dry-run ]; then echo "would kill $label"; continue; fi
    echo "kill $label"
    if alive "$pid"; then stop_tree "$pid"; fi
    if alive "$pid"; then echo "STILL ALIVE browser pid=$pid"; rc=1; else stopped_profiles="$stopped_profiles $prof"; fi
  fi
done <<EOF
$matches
EOF

# A bridge stop takes its browser with it; list the profiles of browsers gone since the first look.
if [ "$MODE" = apply ]; then
  for dir in $(printf '%s\n' "$matches" | awk '$1 == "browser" { print $4 }') $stopped_profiles; do
    remove_profile "$dir"
  done
  for dir in "$PREFIX"*; do
    [ -d "$dir" ] || continue
    [ -n "$(find "$dir" -maxdepth 0 -mmin "+$(( HOURS * 60 ))" 2>/dev/null)" ] || continue
    remove_profile "$dir"
  done
fi

after_browsers=$(count_browsers)
after_bridges=$(count_bridges)
if [ "$MODE" = dry-run ]; then
  echo "dry run: browsers=$before_browsers bridges=$before_bridges, nothing stopped (use --apply)"
else
  echo "browsers before=$before_browsers after=$after_browsers; bridges before=$before_bridges after=$after_bridges"
fi
exit "$rc"
