#!/usr/bin/env bash
# tests/jg-fleet-heartbeat.test.sh - one shell pass proves every home in the fleet
# is moving, and its check wakes Main on a gap until the gap closes
# (bin/jg-fleet-heartbeat.sh).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-fleet-heartbeat)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
HB="$ROOT/bin/jg-fleet-heartbeat.sh"

lane() {  # <home> <task> <last status line>
  printf 'kind=ship\n' > "$1/state/$2.meta"
  printf '%s\n' "$3" > "$1/state/$2.status"
}

# pane <home> <task> <busy|idle>: the semantic busy record a live pane publishes,
# with the harness that trusts it. A lane with no such record has no pane reading
# and falls back to its status log.
pane() {  # <home> <task> <busy|idle>
  local gen="g$2.1"
  printf 'harness=pi\nwindow=fake:%s\n' "$2" >> "$1/state/$2.meta"
  printf '%s\n' "$gen" > "$1/state/$2.busy-gen"
  printf 'v1 gen=%s seq=1 state=%s source=pi-ext event=agent-start ts=1\n' "$gen" "$3" \
    > "$1/state/$2.busy-state"
}

row_field() {  # <rows> <home> <column>
  printf '%s\n' "$1" | awk -F '\t' -v h="$2" -v c="$3" '$1 == h { print $c }'
}

home() {  # <dir> <ready> [target] -> a home whose watcher beat just now
  mkdir -p "$1/state" "$1/config"
  printf '{"ready_work":%s}\n' "$2" > "$1/state/home-summary.json"
  [ -z "${3-}" ] || printf '%s\n' "$3" > "$1/config/lane-target"
  touch "$1/state/.last-watcher-beat"
}

setup() {  # <name> -> a primary home with three local Squad Leads and one remote
  local d=$TMP_ROOT/$1
  home "$d/main" 0
  mkdir -p "$d/main/data"
  lane "$d/main" ship-a 'working [at=1]: building'
  home "$d/leads/gappy" 3 2
  lane "$d/leads/gappy" g1 'working [at=1]: building'
  lane "$d/leads/gappy" g2 'paused [at=1]: waiting on CI until 2026-10-30T09:00Z'
  home "$d/leads/quiet" 0
  lane "$d/leads/quiet" q1 'done [at=1]: PR https://example.test/pr/1'
  home "$d/leads/dead" 1
  touch -d '2 hours ago' "$d/leads/dead/state/.last-watcher-beat"
  {
    printf -- '- gappy - a lead with free lanes (home: %s; scope: g; projects: g; added 2026-10-30)\n' "$d/leads/gappy"
    printf -- '- quiet - an idle lead (home: %s; scope: q; projects: q; added 2026-10-30)\n' "$d/leads/quiet"
    printf -- '- dead - a lead whose watcher stopped (home: %s; scope: x; projects: x; added 2026-10-30)\n' "$d/leads/dead"
    printf -- '- far - a remote lead (host: box; root: /r; home: /r/h; scope: f; projects: f; added 2026-10-30)\n'
  } > "$d/main/data/squad_leads.md"
  printf '%s\n' "$d"
}

hb() {  # <case-dir> args...
  local d=$1
  shift
  env JG_HOME="$d/main" "$HB" "$@" 2>&1
}

verdict() { printf '%s\n' "$1" | awk -F '\t' -v h="$2" '$1 == h { print $2 }'; }

test_rows_give_every_home_one_verdict() {
  local d out
  d=$(setup rows)
  out=$(hb "$d" rows) || fail "rows failed: $out"
  assert_equals "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 5 "one row per home: $out"
  assert_equals "$(verdict "$out" overwatch)" MOVING "a working lane with no ready work is moving"
  assert_equals "$(verdict "$out" gappy)" GAP "ready work with a free lane is a gap"
  assert_contains "$out" "3 ready, 1 of 2 lanes working (target 2)" \
    "a paused lane with no pane reading must not count as working"
  assert_equals "$(verdict "$out" quiet)" IDLE "a done lane and no ready work is idle"
  assert_equals "$(verdict "$out" dead)" STALLED "work with no supervision beat is stalled"
  assert_equals "$(verdict "$out" far)" UNREAD "a remote home is not read"
  pass "rows give every home one verdict"
}

test_an_open_wait_is_a_gap_and_filled_lanes_are_moving() {
  local d out
  d=$(setup waits)
  lane "$d/leads/gappy" g3 'working [at=1]: building'
  mkdir -p "$d/main/state/.waiting-timers"
  printf 'x\n' > "$d/main/state/.waiting-timers/ship-a"
  out=$(hb "$d" rows)
  assert_equals "$(verdict "$out" gappy)" MOVING "lanes at the target with ready work are moving"
  assert_equals "$(verdict "$out" overwatch)" GAP "an open wait is a gap"
  pass "an open wait is a gap and filled lanes are moving"
}

test_check_wakes_on_a_gap_refires_and_reports_recovery_once() {
  local d out
  d=$(setup check)
  out=$(hb "$d" check)
  assert_contains "$out" "fleet heartbeat: gappy GAP" "the first gap must wake Main"
  assert_contains "$out" "fleet heartbeat: dead STALLED" "a stalled home must wake Main"
  assert_not_contains "$out" "overwatch" "a moving home must stay silent"
  assert_equals "$(hb "$d" check)" "" "an unchanged gap inside the re-fire window is silent"
  out=$(JG_FLEET_HEARTBEAT_REFIRE_SECS=0 hb "$d" check)
  assert_contains "$out" "fleet heartbeat: gappy GAP" "a gap still open after the window must re-fire"
  lane "$d/leads/gappy" g2 'working [at=2]: CI green, back on it'
  out=$(hb "$d" check)
  assert_contains "$out" "fleet heartbeat: gappy MOVING again" "recovery must be reported"
  assert_not_contains "$(hb "$d" check)" "gappy" "recovery is reported once"
  pass "check wakes on a gap, re-fires, and reports recovery once"
}

test_arm_registers_a_check_the_watcher_trusts_only_on_a_primary_home() {
  local d
  d=$(setup arm)
  hb "$d" arm > /dev/null || fail "arm failed"
  bash -c '. "$1/bin/jg-pr-lib.sh"; . "$1/bin/jg-check-lib.sh"; jg_custom_check_registered "$2" fleet-heartbeat' _ "$ROOT" "$d/main/state" \
    || fail "the watcher would reject the armed check"
  hb "$d" disarm > /dev/null
  [ ! -e "$d/main/state/fleet-heartbeat.check.sh" ] || fail "disarm left the shim"
  touch "$d/main/.jg-squad-lead-home"
  if hb "$d" arm > /dev/null; then fail "a Squad Lead home must refuse arm"; fi
  pass "arm registers a trusted check only on a primary home"
}

# Rule 12: a lead lands finished work and closes the lane. A lane whose work is
# done while its worker still answers is work nobody closed, so the heartbeat
# names it once, re-fires it after the window, and stays quiet once it is gone.
test_check_names_a_finished_lane_nobody_closed() {
  local d out stub
  d=$(setup closed)
  stub="$d/crew-state.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
case "$1" in
  q1) printf 'state: done \302\267 source: pane \302\267 idle at its prompt\n' ;;
  *)  printf 'state: working \302\267 source: run-step \302\267 execution active\n' ;;
esac
SH
  chmod +x "$stub"
  out=$(JG_CREW_STATE_BIN="$stub" hb "$d" check)
  assert_contains "$out" "fleet heartbeat: quiet lane q1 is done but still open - land it and close it" \
    "a finished lane whose worker still answers must be named"
  assert_equals "$(JG_CREW_STATE_BIN="$stub" hb "$d" check | grep -c 'lane q1')" 0 \
    "the same open lane inside the re-fire window is silent"
  assert_contains "$(JG_CREW_STATE_BIN="$stub" JG_FLEET_HEARTBEAT_REFIRE_SECS=0 hb "$d" check)" "lane q1" \
    "an open lane still open after the window must re-fire"
  rm -f "$d/leads/quiet/state/q1.meta"
  assert_not_contains "$(JG_CREW_STATE_BIN="$stub" JG_FLEET_HEARTBEAT_REFIRE_SECS=0 hb "$d" check)" "lane q1" \
    "a closed lane must be silent"
  pass "check names a finished lane nobody closed, re-fires it, and goes quiet once it is closed"
}
test_check_names_a_finished_lane_nobody_closed

# A lane's status log is an event log, so its last line is history: a pane that
# is busy right now is working even when that line says it paused or finished.
# The idle-lane alarm must not fire on a fleet whose panes are all busy.
test_a_busy_pane_is_working_whatever_its_status_line_says() {
  local d out
  d=$(setup panes)
  lane "$d/leads/gappy" g1 'paused [at=1]: waiting on CI'
  lane "$d/leads/gappy" g2 'done [at=1]: PR https://example.test/pr/2'
  pane "$d/leads/gappy" g1 busy
  pane "$d/leads/gappy" g2 busy
  out=$(hb "$d" rows)
  assert_equals "$(verdict "$out" gappy)" MOVING \
    "three ready items beside two busy panes must not raise the idle-lane alarm"
  assert_contains "$out" "2 lanes working" \
    "a busy pane must count as working whatever its last status line says"
  assert_equals "$(row_field "$out" gappy 3)" 2 "working lanes"
  assert_equals "$(row_field "$out" gappy 4)" 2 "the lane target stays its own number"
  assert_equals "$(row_field "$out" gappy 9)" 2 "open lanes"
  pass "a busy pane is working whatever its status line says"
}

# working, open and the target are three separate numbers, and no target caps the
# count of working lanes: five busy panes on a home whose target is two report
# five, not two.
test_the_working_count_is_never_capped_by_the_target() {
  local d out i
  d=$(setup cap)
  for i in 1 2 3 4 5; do
    lane "$d/leads/gappy" "c$i" 'working [at=1]: building'
    pane "$d/leads/gappy" "c$i" busy
  done
  pane "$d/leads/gappy" g1 busy
  out=$(hb "$d" rows)
  assert_equals "$(row_field "$out" gappy 3)" 6 "working lanes over the target"
  assert_equals "$(row_field "$out" gappy 4)" 2 "the target is unchanged"
  assert_equals "$(row_field "$out" gappy 9)" 7 "open lanes"
  assert_equals "$(verdict "$out" gappy)" MOVING "lanes over the target are moving, never a gap"
  pass "the working count is never capped by the target"
}

test_rows_give_every_home_one_verdict
test_an_open_wait_is_a_gap_and_filled_lanes_are_moving
test_a_busy_pane_is_working_whatever_its_status_line_says
test_the_working_count_is_never_capped_by_the_target
test_check_wakes_on_a_gap_refires_and_reports_recovery_once
test_arm_registers_a_check_the_watcher_trusts_only_on_a_primary_home
