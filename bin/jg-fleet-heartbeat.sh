#!/usr/bin/env bash
# jg-fleet-heartbeat.sh - one deterministic pass, no model, that proves every home
# in this fleet is moving: this primary home plus every local Squad Lead home in
# data/squad_leads.md.
#
# Usage:
#   jg-fleet-heartbeat.sh [rows]     one TSV row per home
#   jg-fleet-heartbeat.sh check      the watcher check form (see below)
#   jg-fleet-heartbeat.sh arm | disarm
#
# rows   Columns: home, verdict, working lanes, lane target (- when unset), ready
#        backlog (? when the home summary is missing), open waits, beacon age in
#        seconds (999999 when no watcher ever ran), why, peak (bin/jg-peak-gate.sh's
#        peak-price sentence for that home, `-` for a home that is not read). The
#        home is `overwatch` for this home and
#        the registry id for a Squad Lead. Every field comes from records the
#        home already writes; nothing is re-derived:
#          working  state/<task>.meta of kind ship or scout whose last state
#                   line is not paused, blocked, needs-decision, done or failed;
#          target   config/lane-target (one positive integer);
#          ready    ready_work in state/home-summary.json;
#          waits    open wait-timer episodes in state/.waiting-timers/, each
#                   already climbing its own owner, lead, Main, card ladder;
#          beacon   jg_watcher_progress_age (bin/jg-wake-lib.sh): the watcher
#                   beacon, or a starting watcher's lock while it has none.
#        Verdict, first match wins:
#          STALLED  work exists (working or ready) and the beacon is absent or
#                   older than JG_FLEET_HEARTBEAT_BEACON_SECS (default 900): no
#                   supervision is moving this home;
#          GAP      ready work with lanes free (working below the target, or
#                   none working when no target is set), or an open wait;
#          IDLE     no working lane and no ready work;
#          MOVING   otherwise;
#          DORMANT  stopped by bin/jg-squad-lead-dormant.sh with no open work;
#                   it wakes when work is routed to it, so it is no gap.
#        A remote Squad Lead is UNREAD, and a registered home that is not a
#        directory is STALLED.
# check  Prints one line per home that turns GAP or STALLED, again every
#        JG_FLEET_HEARTBEAT_REFIRE_SECS (default 600) while it stays there, and
#        one line when it recovers; the watcher turns each line into a wake for
#        Main. An unchanged healthy fleet prints nothing.
#        A finished lane that was never closed is reported the same way:
#        `fleet heartbeat: <home> lane <id> is done but still open - land it and
#        close it`, once and again only after the re-fire window. The proof is the
#        lane's authoritative current state (bin/jg-crew-state.sh, local reads only):
#        done while its worker endpoint still answers, which is work nobody landed.
#        State: state/.fleet-heartbeat/<home> (verdict, since, last fired) and
#        state/.fleet-heartbeat/lane-<home>-<id> for a reported lane.
# arm    Writes state/fleet-heartbeat.check.sh and binds it with
#        jg-check-register.sh. disarm retires it with jg-check-unregister.sh.
#        A Squad Lead home refuses arm: the primary home reads it.
#        bin/jg-bootstrap.sh arms it on every primary home's session start
#        unless config/fleet-heartbeat-off exists.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
# shellcheck source=bin/jg-compat.sh
. "$SCRIPT_DIR/jg-compat.sh"
# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
STATE="$JG_HOME/state"
BEACON_SECS=${JG_FLEET_HEARTBEAT_BEACON_SECS:-900}
REFIRE_SECS=${JG_FLEET_HEARTBEAT_REFIRE_SECS:-600}
NOW=$(date +%s)

die() { printf 'jg-fleet-heartbeat: %s\n' "$1" >&2; exit "${2:-1}"; }

# home_row <id> <home-dir>: one TSV row.
home_row() {
  local id=$1 home=$2 st meta kind last working=0 target=- ready='?' waits=0 age why verdict peak
  [ -d "$home" ] || { printf '%s\tSTALLED\t0\t-\t?\t0\t-\thome %s is not a directory\t-\n' "$id" "$home"; return; }
  if [ "$id" != overwatch ] && squad_lead_dormant "$STATE" "$id"; then
    printf '%s\tDORMANT\t0\t-\t-\t0\t-\tno open work; stopped, wakes on routed work\t-\n' "$id"
    return
  fi
  st=$home/state
  for meta in "$st"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
    case "${kind:-ship}" in ship|scout) ;; *) continue ;; esac
    last=$(grep -E '^(working|paused|blocked|needs-decision|done|failed)[ :[]' "${meta%.meta}.status" 2>/dev/null | tail -1)
    case "$last" in paused*|blocked*|needs-decision*|done*|failed*) ;; *) working=$((working + 1)) ;; esac
  done
  target=$(awk 'NF { print; exit }' "$home/config/lane-target" 2>/dev/null)
  case "$target" in ''|*[!0-9]*|0) target=- ;; esac
  ready=$(jq -r '.ready_work // empty | numbers' "$st/home-summary.json" 2>/dev/null) || ready=
  [ -n "$ready" ] || ready='?'
  for meta in "$st"/.waiting-timers/*; do
    [ -f "$meta" ] && waits=$((waits + 1))
  done
  age=$(jg_watcher_progress_age "$st")
  if [ "$working" -gt 0 ] || { [ "$ready" != '?' ] && [ "$ready" -gt 0 ]; }; then
    if [ "$age" -gt "$BEACON_SECS" ]; then
      verdict=STALLED why="work waits but no supervision beat for ${age}s"
      [ "$age" -lt 999999 ] || why="work waits but no supervision has run"
    elif [ "$ready" != '?' ] && [ "$ready" -gt 0 ] \
      && { { [ "$target" = - ] && [ "$working" -eq 0 ]; } || { [ "$target" != - ] && [ "$working" -lt "$target" ]; }; }; then
      verdict=GAP why="$ready ready, $working of ${target/-/?} lanes working"
    elif [ "$waits" -gt 0 ]; then
      verdict=GAP why="$waits open wait(s) climbing their ladder"
    else
      verdict=MOVING why="$working lanes working"
    fi
  elif [ "$waits" -gt 0 ]; then
    verdict=GAP why="$waits open wait(s) climbing their ladder"
  else
    verdict=IDLE why="no ready work and no working lane"
  fi
  peak=$(JG_HOME="$home" JG_STATE_OVERRIDE="$st" JG_CONFIG_OVERRIDE="$home/config" \
    "$SCRIPT_DIR/jg-peak-gate.sh" status 2>/dev/null) || peak=
  [ -n "$peak" ] || peak='?'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$verdict" "$working" "$target" "$ready" "$waits" "$age" "$why" "$peak"
}

cmd_rows() {
  local reg line
  home_row overwatch "$JG_HOME"
  reg=$(jg_compat_pick "$JG_HOME/data/squad_leads.md")
  [ -f "$reg" ] || return 0
  while IFS= read -r line; do
    squad_lead_registry_parse_line "$line" || continue
    if [ "$SQUAD_LEAD_REGISTRY_REMOTE" -eq 1 ]; then
      printf '%s\tUNREAD\t-\t-\t?\t-\t-\tremote home on %s\n' "$SQUAD_LEAD_REGISTRY_ID" "$SQUAD_LEAD_REGISTRY_HOST"
    else
      home_row "$SQUAD_LEAD_REGISTRY_ID" "$SQUAD_LEAD_REGISTRY_HOME"
    fi
  done < "$reg"
}

# 0 when lane <id> in <home> is authoritatively done while its worker endpoint still
# answers: the work finished but nobody landed and closed the lane (owner rule 12).
# One jg-crew-state.sh read per lane, local sources only (JG_CREW_STATE_NO_FORGE).
lane_done_but_open() {  # <id> <home>
  local line state src last
  [ -f "$2/state/$1.meta" ] || return 1
  # Cheap pre-filter: only a lane whose log already says done can be finished, so
  # the authoritative read runs for those alone.
  last=$(grep -E '^done[ :[]' "$2/state/$1.status" 2>/dev/null | tail -1)
  [ -n "$last" ] || return 1
  line=$(env JG_HOME="$2" JG_STATE_OVERRIDE="$2/state" JG_DATA_OVERRIDE="${JG_DATA_OVERRIDE:-$2/data}" \
    JG_CREW_STATE_NO_FORGE=1 "${JG_CREW_STATE_BIN:-$SCRIPT_DIR/jg-crew-state.sh}" "$1" 2>/dev/null) || true
  case "$line" in state:*) ;; *) return 1 ;; esac
  state=${line#state: }; state=${state%% *}
  src=${line#*source: }; src=${src%% *}
  [ "$state" = "done" ] && [ "$src" = pane ]
}

# cmd_check's second half: one line per finished-but-open lane, on the same
# first-sighting and re-fire cadence as a home verdict.
check_open_lanes() {  # <home-label> <home-dir>
  local label=$1 home=$2 meta id rec old since fired
  for meta in "$home"/state/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    lane_done_but_open "$id" "$home" || continue
    rec=$DIR/lane-$label-$id old='' since=$NOW fired=0
    [ ! -f "$rec" ] || IFS=$'\t' read -r old since fired < "$rec"
    if [ "$old" != open ] || [ "$fired" -eq 0 ] || [ $((NOW - fired)) -ge "$REFIRE_SECS" ]; then
      printf 'fleet heartbeat: %s lane %s is done but still open - land it and close it\n' "$label" "$id"
      fired=$NOW
    fi
    printf 'open\t%s\t%s\n' "$since" "$fired" > "$rec.tmp" && mv -f -- "$rec.tmp" "$rec"
  done
}

cmd_check() {
  local dir=$STATE/.fleet-heartbeat rows id verdict working target ready waits age why peak rec old since fired reg line
  DIR=$dir
  mkdir -p "$dir" || die "cannot write $dir"
  rows=$(cmd_rows)
  while IFS=$'\t' read -r id verdict working target ready waits age why peak; do
    [ -n "$id" ] || continue
    rec=$dir/$id old='' since=$NOW fired=0
    [ ! -f "$rec" ] || IFS=$'\t' read -r old since fired < "$rec"
    [ "$old" = "$verdict" ] || since=$NOW fired=0
    case "$verdict" in
      GAP|STALLED)
        if [ "$fired" -eq 0 ] || [ $((NOW - fired)) -ge "$REFIRE_SECS" ]; then
          printf 'fleet heartbeat: %s %s for %ss - %s\n' "$id" "$verdict" "$((NOW - since))" "$why"
          fired=$NOW
        fi ;;
      *) case "$old" in GAP|STALLED) printf 'fleet heartbeat: %s %s again\n' "$id" "$verdict" ;; esac ;;
    esac
    printf '%s\t%s\t%s\n' "$verdict" "$since" "$fired" > "$rec.tmp" && mv -f -- "$rec.tmp" "$rec"
  done <<EOF
$rows
EOF
  check_open_lanes overwatch "$JG_HOME"
  reg=$(jg_compat_pick "$JG_HOME/data/squad_leads.md")
  [ -f "$reg" ] || return 0
  while IFS= read -r line; do
    squad_lead_registry_parse_line "$line" || continue
    [ "$SQUAD_LEAD_REGISTRY_REMOTE" -eq 0 ] || continue
    [ -d "$SQUAD_LEAD_REGISTRY_HOME" ] || continue
    check_open_lanes "$SQUAD_LEAD_REGISTRY_ID" "$SQUAD_LEAD_REGISTRY_HOME"
  done < "$reg"
}

cmd_arm() {
  local marker shim=$STATE/fleet-heartbeat.check.sh tmp
  marker=$(jg_compat_marker "$JG_HOME")
  { [ ! -e "$marker" ] && [ ! -L "$marker" ]; } || die "a Squad Lead home is read by its primary home; not armed" 2
  tmp=$(umask 077; mktemp "$STATE/.jg-fleet-heartbeat.XXXXXX") || die "cannot write the check shim"
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q check\n' "$JG_HOME" "$SCRIPT_DIR/jg-fleet-heartbeat.sh" > "$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$shim"; } || { rm -f -- "$tmp"; die "cannot write the check shim"; }
  JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-register.sh" fleet-heartbeat >/dev/null || die "cannot register the check"
  printf 'armed: fleet-heartbeat\n'
}

case "${1:-rows}" in
  rows) cmd_rows ;;
  check) cmd_check ;;
  arm) cmd_arm ;;
  disarm) JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-unregister.sh" fleet-heartbeat ;;
  *) die "usage: jg-fleet-heartbeat.sh [rows|check|arm|disarm]" 2 ;;
esac
