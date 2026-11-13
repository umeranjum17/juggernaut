#!/usr/bin/env bash
# The speculative window of the landing check (sourced by core/trunk-landing/trunk-landing.sh; it runs nothing itself).
# W is how many landing gates one project keeps running at once, each on top of the lanes ahead of it. It grows by one when a lane
# lands and halves (rounded down, never under 1) when a gate ends red, and never passes the cap: the least of
#   gate-slots   the project's policy (bin/jg-trunk-policy-lib.sh; gate-slots=1 turns the window off),
#   heavy_slots  the heavy runs the host budget allows (config/lane-scale, core/lane-scale/fleet.sh).
# bin/jg-trunk.sh chains as many gates in order as the window allows (its chain of fronts), so the window is the only owner of the width.
# A project with no record starts at the cap, so a home that never saw a red gates as wide as it was allowed to. The record is
# state/trunk-window-<project>: one whole number, written under a lock.
# Needs $STATE and $FMH and the lock helpers of bin/jg-wake-lib.sh; it reads the policy itself, because the run and runbatch jobs
# call it before the check's own policy helpers exist.

window_cap() {  # <project>: the widest the window may be now
  local pn=$1 slots heavy cap v
  # shellcheck source=bin/jg-trunk-policy-lib.sh disable=SC1091
  . "$FMH/bin/jg-trunk-policy-lib.sh"
  slots=$(jg_trunk_policy gate-slots "$pn"); case $slots in ''|*[!0-9]*) slots=2 ;; esac
  v=$(sed -n 's/^heavy_slots=//p' "$FMH/config/lane-scale" 2>/dev/null | tail -n 1)
  case $v in ''|*[!0-9]*) heavy=2 ;; *) heavy=$v ;; esac
  cap=$slots
  [ "$heavy" -ge "$cap" ] || cap=$heavy
  [ "$cap" -ge 1 ] || cap=1
  printf '%s\n' "$cap"
}

window_size() {  # <project>: W, kept between 1 and the cap
  local pn=$1 cap w
  cap=$(window_cap "$pn")
  w=$(cat "$STATE/trunk-window-$pn" 2>/dev/null || true)
  case $w in ''|*[!0-9]*) w=$cap ;; esac
  [ "$w" -le "$cap" ] || w=$cap
  [ "$w" -ge 1 ] || w=1
  printf '%s\n' "$w"
}

window_move() {  # <project> landed|red: one step of the rule; prints the new W
  local pn=$1 w cap lock; lock="$STATE/.trunk-window-$pn.lock"
  jg_lock_acquire_wait "$lock" || return 1
  w=$(window_size "$pn"); cap=$(window_cap "$pn")
  case $2 in
    landed) w=$((w + 1)); [ "$w" -le "$cap" ] || w=$cap ;;
    red) w=$((w / 2)); [ "$w" -ge 1 ] || w=1 ;;
  esac
  printf '%s\n' "$w" > "$STATE/trunk-window-$pn.tmp.$$" && mv -f -- "$STATE/trunk-window-$pn.tmp.$$" "$STATE/trunk-window-$pn"
  jg_lock_release "$lock"
  printf '%s\n' "$w"
}

# Whether the output of a refused landing is a red gate (a lint or test of the lane failed), not a conflict, a wait or the machine.
window_is_red() {  # <lander output>
  printf '%s\n' "$1" | grep -q "^REFUSED: gate '[^']*' failed"
}
