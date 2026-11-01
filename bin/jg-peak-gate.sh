#!/usr/bin/env bash
# jg-peak-gate.sh - when, never which: refuse a new lane on a peak-priced route
# during a peak window so the work waits for off-peak instead of paying double.
#
# Usage:
#   jg-peak-gate.sh admit --task <id> --model <route> [--override <reason>]
#   jg-peak-gate.sh status        one line for the session digest and the heartbeat
#   jg-peak-gate.sh waiting       how many tasks wait for off-peak
#   jg-peak-gate.sh route <route> [<epoch>]
#   jg-peak-gate.sh check         the watcher check form (see below)
#   jg-peak-gate.sh arm | disarm
#
# admit  The dispatch gate. It exits 0 when the route may start now, and 75 when
#        it must wait, printing the window end and the override flag. bin/jg-spawn.sh
#        calls it for every fresh ship, scout, and relaunch; a squad_lead is idle
#        infrastructure and is not gated. A RUNNING lane is never touched, because
#        nothing here can stop one: only a new spawn arrives. A refused task stays
#        ready in the backlog - admit writes state/.peak-waiting/<id> and touches
#        nothing else, so queued work is deferred, never blocked.
#        --override <reason> is the captain-urgent path: it admits the spawn and
#        appends one line naming the task, the route, the window, and the reason
#        to state/.peak-overrides.log.
#        config/peak-billing decides whether peak costs anything: `per-token` (the
#        default when the file is absent, which is the avoiding default) gates, and
#        `capped` - the old session/weekly caps, where a busy hour is free - admits
#        without gating. Any other value is treated as per-token.
# status The peak line: which routes peak now and when that ends, or when the next
#        peak starts, plus how many tasks wait for off-peak.
# check  Prints one line when an off-peak stretch begins and tasks are waiting for
#        it, so the leads dispatch what waited. No model runs: the watcher polls
#        this script, and the off-peak stretch that already woke the fleet is
#        marked in state/.peak-gate/, so it fires exactly once.
# arm    Writes state/peak-gate.check.sh and binds it with jg-check-register.sh;
#        disarm retires it. bin/jg-bootstrap.sh arms it on every primary home's
#        session start unless config/peak-guard-off exists.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
# shellcheck source=bin/jg-peak-lib.sh
. "$SCRIPT_DIR/jg-peak-lib.sh"

die() { printf 'jg-peak-gate: %s\n' "$1" >&2; exit "${2:-1}"; }

# JG_PEAK_NOW pins the epoch: a test proves an 11:59/12:00 edge without waiting
# for it, and the arithmetic never reads a clock of its own.
now_epoch() { printf '%s\n' "${JG_PEAK_NOW:-$(date +%s)}"; }

iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null ||
    TZ=UTC0 date -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s' "$1"
}

# jg_peak_labels: one `provider/model-glob` label per confirmed row.
jg_peak_labels() {
  jg_peak_rows | cut -f1,2 | tr '\t' '/'
}

waiting_count() {
  local f n=0
  for f in "$STATE"/.peak-waiting/*; do
    [ -f "$f" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

billing_plan() {
  local plan=
  [ -f "$CONFIG/peak-billing" ] && plan=$(awk 'NF { print; exit }' "$CONFIG/peak-billing" 2>/dev/null)
  case "$plan" in capped) printf 'capped' ;; *) printf 'per-token' ;; esac
}

# peak_now_line: the shared sentence `status` prints.
peak_now_line() {
  local now=$1 label end start peak='' n peak_end='' next_start=''
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    if jg_peak_route_in_peak "$label" "$now"; then
      peak="$peak${peak:+, }$label"
      end=$(jg_peak_route_peak_end "$label" "$now")
      [ -n "$end" ] || continue
      case "$peak_end" in
      '') peak_end=$end ;;
      *) [ "$end" -le "$peak_end" ] || peak_end=$end ;;
      esac
    else
      start=$(jg_peak_route_next_start "$label" "$now")
      [ -n "$start" ] || continue
      case "$next_start" in
      '') next_start=$start ;;
      *) [ "$start" -ge "$next_start" ] || next_start=$start ;;
      esac
    fi
  done <<EOF
$(jg_peak_labels)
EOF
  n=$(waiting_count)
  if [ -n "$peak" ]; then
    printf 'peak now on %s until %s; %s task(s) waiting for off-peak' "$peak" "$(iso "$peak_end")" "$n"
  elif [ -n "$next_start" ]; then
    printf 'off-peak; next peak at %s; %s task(s) waiting for off-peak' "$(iso "$next_start")" "$n"
  else
    printf 'no peak windows recorded; %s task(s) waiting for off-peak' "$n"
  fi
}

cmd_status() {
  local now=${1:-}
  [ -n "$now" ] || now=$(now_epoch)
  printf '%s (%s plan)\n' "$(peak_now_line "$now")" "$(billing_plan)"
}

cmd_waiting() { printf '%s\n' "$(waiting_count)"; }

cmd_route() {
  local route=${1?route} now=${2:-} end
  [ -n "$now" ] || now=$(now_epoch)
  if jg_peak_route_in_peak "$route" "$now"; then
    end=$(jg_peak_route_peak_end "$route" "$now")
    printf 'peak until %s\n' "$(iso "$end")"
    return 3
  fi
  end=$(jg_peak_route_next_start "$route" "$now")
  if [ -n "$end" ]; then printf 'off-peak next %s\n' "$(iso "$end")"; else printf 'off-peak\n'; fi
}

cmd_admit() {
  local task='' route='' override='' now end plan marker
  now=$(now_epoch)
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --task) task=${2-}; shift 2 || die "admit: --task needs a value" 2 ;;
    --model) route=${2-}; shift 2 || die "admit: --model needs a value" 2 ;;
    --override) override=${2-}; shift 2 || die "admit: --override needs a value" 2 ;;
    *) die "admit: unknown argument $1" 2 ;;
    esac
  done
  [ -n "$task" ] || die "admit: --task is required" 2
  marker=$STATE/.peak-waiting/"$task"
  # No route named means no known price list, so nothing here can price it.
  if [ -z "$route" ]; then
    rm -f -- "$marker" 2>/dev/null || true
    return 0
  fi
  plan=$(billing_plan)
  if [ "$plan" = capped ]; then return 0; fi
  if ! jg_peak_route_in_peak "$route" "$now"; then
    rm -f -- "$marker" 2>/dev/null || true
    return 0
  fi
  end=$(jg_peak_route_peak_end "$route" "$now")
  if [ -n "$override" ]; then
    mkdir -p "$STATE" 2>/dev/null || die "admit: cannot write $STATE"
    printf '%s task=%s route=%s peak-until=%s override=%s\n' \
      "$(iso "$now")" "$task" "$route" "$(iso "$end")" "$override" |
      tee -a "$STATE/.peak-overrides.log"
    rm -f -- "$marker" 2>/dev/null || true
    return 0
  fi
  mkdir -p "$STATE/.peak-waiting" 2>/dev/null || die "admit: cannot write $STATE/.peak-waiting"
  : >"$marker" || die "admit: cannot write $marker"
  printf 'peak-price guard: %s waits for off-peak (peak ends %s); task %s stays queued.\n' \
    "$route" "$(iso "$end")" "$task" >&2
  printf 'peak-price guard: re-dispatch after %s, or pass --peak-override "<reason>" for captain-urgent work.\n' \
    "$(iso "$end")" >&2
  exit 75
}

cmd_check() {
  local dir=$STATE/.peak-gate now key label marker start
  now=$(now_epoch)
  [ "$(waiting_count)" -gt 0 ] || return 0
  key=
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    jg_peak_route_in_peak "$label" "$now" && return 0
    start=$(jg_peak_route_next_start "$label" "$now")
    [ -n "$start" ] || continue
    case "$key" in
    '') key=$start ;;
    *) [ "$start" -ge "$key" ] || key=$start ;;
    esac
  done <<EOF
$(jg_peak_labels)
EOF
  [ -n "$key" ] || return 0
  mkdir -p "$dir" || die "cannot write $dir"
  marker=$dir/dispatched-"$key"
  [ ! -e "$marker" ] || return 0
  printf 'peak gate: off-peak now - %s task(s) waited for off-peak; dispatch them (next peak %s)\n' \
    "$(waiting_count)" "$(iso "$key")"
  : >"$marker"
}

cmd_arm() {
  local shim=$STATE/peak-gate.check.sh tmp
  tmp=$(umask 077; mktemp "$STATE/.jg-peak-gate.XXXXXX") || die "cannot write the check shim"
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q check\n' "$JG_HOME" "$SCRIPT_DIR/jg-peak-gate.sh" >"$tmp" &&
    chmod 0700 "$tmp" && mv -f -- "$tmp" "$shim"; } || { rm -f -- "$tmp"; die "cannot write the check shim"; }
  JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-register.sh" peak-gate >/dev/null || die "cannot register the check"
  printf 'armed: peak-gate\n'
}

case "${1:-status}" in
admit)
  shift
  cmd_admit "$@"
  ;;
status)
  shift
  cmd_status "$@"
  ;;
waiting) cmd_waiting ;;
route)
  shift
  cmd_route "$@"
  ;;
check) cmd_check ;;
arm) cmd_arm ;;
disarm) JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-unregister.sh" peak-gate ;;
*) die "usage: jg-peak-gate.sh [admit|status|waiting|route|check|arm|disarm]" 2 ;;
esac
