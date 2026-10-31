#!/usr/bin/env bash
# Carry a landed merge to every local Juggernaut copy instead of leaving it to
# whoever remembers to run the update.
#
# The copies that run on the merged code are the home the captain runs (this
# home's own checkout, JG_ROOT) and every live Squad Lead home registered here.
# A merge moves none of them by itself, so bin/jg-pr-merge.sh starts `run`
# detached the moment one lands, and the armed check is the backup path for a
# merge that start never saw, plus the drift alarm for a copy that stays behind.
#
# Usage: jg-fleet-autosync.sh run|check|digest|arm|disarm
#
#   run     One guarded convergence pass. bin/jg-update.sh owns the mechanics and
#           fast-forwards the primary and every live Squad Lead home from origin,
#           never forcing, merging, or stashing, so unlanded work stays put. Leads
#           whose advance changed the loaded instruction surface (AGENTS.md, bin/,
#           .agents/skills/) then go to bin/jg-squad-lead-restart.sh, which persists
#           their open records first and queues behind the current turn, so no lead
#           restarts mid-write or mid-lane. A skipped home, or one whose advance
#           touched no instruction file, keeps running. Single-flight: a second pass
#           reports "busy" and exits 0.
#   check   The backup path and drift alarm for the watcher's check sweep: refresh
#           origin once, run the pass when any local copy is behind (a merge the merge
#           script never saw), and print one line per copy that stayed past
#           JG_AUTOSYNC_BEHIND_MAX merges behind for JG_AUTOSYNC_ALARM_SECS. Silent
#           otherwise, and a reported distance does not repeat until it changes.
#   digest  One line per local copy: "<copy>: current" or "<copy>: <n> behind";
#           read-only, reads no network.
#   arm     Write and bind the check shim; disarm retires it. The check id is
#           fleet-autosync and the watcher's sweep cadence sets how often it runs.
#
# Copy ids are "primary" and "jg-<id>"; only local homes are converged, because a
# remote home is reached by its own host.
#
# Environment: JG_HOME, JG_ROOT_OVERRIDE, JG_STATE_OVERRIDE, JG_DATA_OVERRIDE,
#   JG_AUTOSYNC_BEHIND_MAX (2) and JG_AUTOSYNC_ALARM_SECS (600).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
DIR="$DATA/jg-fleet-autosync"
BEHIND_MAX=${JG_AUTOSYNC_BEHIND_MAX:-2}
ALARM_SECS=${JG_AUTOSYNC_ALARM_SECS:-600}
case "$BEHIND_MAX" in '' | *[!0-9]*) BEHIND_MAX=2 ;; esac
case "$ALARM_SECS" in '' | *[!0-9]*) ALARM_SECS=600 ;; esac

# shellcheck source=bin/jg-ff-lib.sh
. "$SCRIPT_DIR/jg-ff-lib.sh"

usage() { echo "usage: jg-fleet-autosync.sh run|check|digest|arm|disarm" >&2; }

# One line per local copy: "<id> <directory>". Reads durable records only.
homes() {
  local id home window meta
  printf 'primary %s\n' "$JG_ROOT"
  while IFS='|' read -r id home window meta; do
    [ -n "$id" ] && [ -n "$home" ] || continue
    grep -q '^remote_host=.' "$meta" 2>/dev/null && continue
    printf 'jg-%s %s\n' "$id" "$home"
  done < <(live_squad_lead_meta_records "$STATE" "$JG_HOME/data/squad_leads.md")
}

# How many commits origin's default branch carries that this copy lacks, or nothing
# when the copy cannot be read. Refs only: no fetch, no network.
behind() {  # <dir>
  local default
  default=$(default_branch "$1") || return 1
  git -C "$1" rev-list --count "HEAD..origin/$default" 2>/dev/null
}

# Single-flight marker for a pass. A dead holder is reclaimed, and the only thing
# removed is this script's own pid file and its directory.
acquire() {
  local lock="$DIR/.run.lock" pid
  mkdir -p "$DIR" 2>/dev/null || return 1
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid"
    return 0
  fi
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  case "$pid" in '' | *[!0-9]*) ;; *) kill -0 "$pid" 2>/dev/null && return 1 ;; esac
  printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || return 1
}

cmd_run() {
  local out ids=''
  if ! acquire; then
    echo "busy: a convergence pass is already running"
    return 0
  fi
  trap 'rm -f "$DIR/.run.lock/pid" 2>/dev/null; rmdir "$DIR/.run.lock" 2>/dev/null' EXIT HUP INT TERM
  # The check is the backup path, so the first pass arms it.
  if [ ! -f "$STATE/fleet-autosync.check.sh" ]; then
    cmd_arm > /dev/null || echo "actionable: the fleet drift check could not be armed; only the merge start carries updates until it is"
  fi
  out=$("$SCRIPT_DIR/jg-update.sh" 2>&1) || true
  printf '%s\n' "$out"
  # A merge restarts only a lead whose loaded instruction surface moved; the update
  # path's own set is wider because /resupply also re-resolves launch-time wiring on
  # an unchanged home, which a merge does not call for.
  ids=$(printf '%s\n' "$out" \
    | sed -n 's/^squad_lead \([^:]*\): updated .*(instructions changed:.*/\1/p' \
    | tr '\n' ' ')
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086 # a space-separated id list is the command's own argv
  JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/jg-squad-lead-restart.sh" $ids \
    || echo "actionable: the restart pass for $ids did not finish; those leads keep running on their old instructions"
}

cmd_check() {
  local id dir n key first last now behind_any=0
  now=$(date +%s)
  mkdir -p "$DIR/behind" 2>/dev/null || true
  # The backup path must see a merge the merge script never saw, so refresh origin
  # first; one fetch serves every worktree of this repository.
  git -C "$JG_ROOT" fetch origin --prune --quiet > /dev/null 2>&1 || true
  while read -r id dir; do
    n=$(behind "$dir") || continue
    case "$n" in '' | *[!0-9]*) continue ;; esac
    [ "$n" -gt 0 ] && behind_any=1
    key="$DIR/behind/$id"
    if [ "$n" -le "$BEHIND_MAX" ]; then
      rm -f "$key" 2>/dev/null || true
      continue
    fi
    first=$now
    last=''
    if [ -f "$key" ]; then
      read -r first last < "$key" 2>/dev/null || true
    fi
    case "$first" in '' | *[!0-9]*) first=$now ;; esac
    printf '%s %s\n' "$first" "$n" > "$key" 2>/dev/null || true
    [ "$((now - first))" -ge "$ALARM_SECS" ] || continue
    [ "$last" = "$n" ] && continue
    printf '%s is %s merges behind the merged default branch after %s minutes; the guarded fast-forward has not reached it\n' \
      "$id" "$n" "$(((now - first) / 60))"
  done < <(homes)
  # Any distance at all is a merge the merge script never carried, so start the pass
  # that does; detached with all three streams redirected, so nothing waits on it.
  if [ "$behind_any" = 1 ]; then
    mkdir -p "$DIR" 2>/dev/null \
      && nohup env JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" JG_DATA_OVERRIDE="$DATA" \
        "$SCRIPT_DIR/jg-fleet-autosync.sh" run >> "$DIR/pass.log" 2>&1 < /dev/null &
  fi
  return 0
}

cmd_digest() {
  local id dir n
  while read -r id dir; do
    n=$(behind "$dir") || n=''
    case "$n" in
      '') printf '%s: unreadable\n' "$id" ;;
      0) printf '%s: current\n' "$id" ;;
      *) printf '%s: %s behind\n' "$id" "$n" ;;
    esac
  done < <(homes)
}

cmd_arm() {
  local shim=$STATE/fleet-autosync.check.sh
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
  (umask 077; printf '#!/usr/bin/env bash\nexport JG_HOME=%q JG_STATE_OVERRIDE=%q JG_DATA_OVERRIDE=%q\nexec %q check\n' \
    "$JG_HOME" "$STATE" "$DATA" "$SCRIPT_DIR/jg-fleet-autosync.sh" > "$shim") || exit 1
  chmod 0700 "$shim" || exit 1
  JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/jg-check-register.sh" fleet-autosync > /dev/null || exit 1
  echo "armed: fleet-autosync"
}

case ${1:-} in
  run) cmd_run ;;
  check) cmd_check ;;
  digest) cmd_digest ;;
  arm) cmd_arm ;;
  disarm) JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-check-unregister.sh" fleet-autosync ;;
  --help | -h) usage ;;
  *) usage; exit 2 ;;
esac
