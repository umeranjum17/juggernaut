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

home() {  # <dir> <ready> [target] -> a home whose watcher beat just now and whose summary is fresh
  mkdir -p "$1/state" "$1/config"
  printf '{"ready_work":%s,"generated_epoch":%s}\n' "$2" "$(date +%s)" > "$1/state/home-summary.json"
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
  assert_contains "$out" "3 ready, 1 of 2 lanes working" "a paused lane must not count as working"
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

# A paused wait climbs nothing, so it is no gap, and a gap the home has anyway
# names it as paused instead of folding it into the climbing count.
test_a_paused_wait_is_named_as_paused_and_is_no_gap() {
  local d out
  d=$(setup paused)
  mkdir -p "$d/main/state/.waiting-timers"
  printf 'x\n' > "$d/main/state/.waiting-timers/ship-a"
  lane "$d/main" ship-a 'paused [at=1]: waiting on the vendor until 2026-10-30T09:00Z'
  out=$(hb "$d" rows)
  assert_not_equals "$(verdict "$out" overwatch)" GAP "a paused wait must not be a gap"
  assert_contains "$out" "1 paused wait(s)" "a paused wait must be named as paused"
  assert_not_contains "$out" "open wait(s) climbing" "a paused wait must not be named as a climbing wait"
  # The home's own pause record makes every wait in it a paused one, and the
  # home itself no gap at all.
  mkdir -p "$d/main/data"
  printf '# Paused for the Juggernaut migration\n\nStop new work.\n- Resume rule: Main sends an explicit resume order.\n' \
    > "$d/main/data/paused-for-juggernaut.md"
  lane "$d/leads/gappy" g1 'blocked [at=1]: the vendor key is missing'
  out=$(hb "$d" rows)
  assert_equals "$(verdict "$out" overwatch)" PAUSED "a paused home is no gap"
  assert_contains "$out" "paused by its own pause record" "a paused home must say why it is no gap"
  # The resume order puts the home back on the ladder.
  rm -f "$d/main/data/paused-for-juggernaut.md"
  assert_not_equals PAUSED "$(verdict "$(hb "$d" rows)" overwatch)" \
    "the removed pause record must take the home off the paused verdict"
  # A blocker in a home that is not paused still climbs, and a gap that has one
  # paused wait beside it prints both counts.
  printf 'kind=ship\n' > "$d/leads/quiet/state/q2.meta"
  printf 'blocked [at=1]: waiting on the vendor\n' > "$d/leads/quiet/state/q2.status"
  printf 'kind=ship\n' > "$d/leads/quiet/state/q3.meta"
  printf 'paused [at=1]: waiting on the vendor\n' > "$d/leads/quiet/state/q3.status"
  mkdir -p "$d/leads/quiet/state/.waiting-timers"
  printf 'x\n' > "$d/leads/quiet/state/.waiting-timers/q2"
  printf 'x\n' > "$d/leads/quiet/state/.waiting-timers/q3"
  out=$(hb "$d" rows)
  assert_equals "$(verdict "$out" quiet)" GAP "a blocker wait in an unpaused home is still a gap"
  assert_contains "$out" "1 open wait(s) climbing their ladder, 1 paused wait(s)" \
    "a gap must count its climbing waits and name the paused one separately: $out"
  pass "a paused wait is named as paused and is no gap"
}

# A report or a lane list parked under a pause record's name must never pause a
# home: a record is a pause only when its content declares one. The home keeps
# its ordinary verdict and its alarm, and the heartbeat says out loud which
# file it refused and that file's first line.
test_a_lane_list_never_pauses_a_home_and_is_named() {
  local d out
  d=$(setup pause-report)
  printf '2\n' > "$d/main/config/lane-target"
  printf '# Paused lanes for the Juggernaut-only push\n\nNo new work; nothing merged.\n- alpha: parked\n' \
    > "$d/main/data/paused-for-juggernaut.md"
  out=$(hb "$d" rows)
  assert_equals "$(verdict "$out" overwatch)" MOVING \
    "a lane list under a pause record's name must not pause the home"
  assert_contains "$out" \
    "data/paused-for-juggernaut.md is not a pause declaration (first line: # Paused lanes for the Juggernaut-only push), so this home is not paused" \
    "the heartbeat must name the refused file and its first line"
  # Live work keeps its alarm: ready work with a free lane still turns GAP.
  printf '{"ready_work":2,"generated_epoch":%s}\n' "$(date +%s)" > "$d/main/state/home-summary.json"
  out=$(hb "$d" check)
  assert_contains "$out" "overwatch GAP" \
    "live work beside a refused pause record must still raise its alarm"
  assert_contains "$out" "data/paused-for-juggernaut.md is not a pause declaration" \
    "the alarm must name the refused record"
  # A genuine pause order under the home's own new record name still silences it.
  rm -f "$d/main/data/paused-for-juggernaut.md"
  printf '# Paused for the vendor migration\n\nStop new work.\n- Resume rule: Main sends an explicit resume order.\n' \
    > "$d/main/data/.jg-pause-order.md"
  out=$(hb "$d" rows)
  assert_equals "$(verdict "$out" overwatch)" PAUSED \
    "a genuine pause order under data/.jg-pause-order.md must still pause the home"
  assert_not_contains "$out" "is not a pause declaration" \
    "a genuine pause order must not be named as refused"
  # A genuine pause already declared under the old name still holds.
  mv "$d/main/data/.jg-pause-order.md" "$d/main/data/paused-for-juggernaut.md"
  assert_equals "$(verdict "$(hb "$d" rows)" overwatch)" PAUSED \
    "a genuine pause already declared under the old record name must still hold"
  # A record whose first line declares the lift is a declared end, not a refused file.
  printf '# Fleet pause - lifted 2026-10-03T16:54:36Z\n\n- Resume rule: Main lifted it.\n' \
    > "$d/main/data/fleet-pause-2026-11-02.md"
  rm -f "$d/main/data/paused-for-juggernaut.md"
  out=$(hb "$d" rows)
  assert_not_equals PAUSED "$(verdict "$out" overwatch)" \
    "a record whose first line declares the lift must take the home off the paused verdict"
  assert_not_contains "$out" "is not a pause declaration" \
    "a declared lift is an end, not a refused report"
  pass "a lane list never pauses a home and is named, and a genuine pause still holds"
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

test_a_goal_step_waiting_is_ready_work_named_in_the_row() {
  local d out
  d=$(setup goal-step)
  rm -f "$d/main/state/ship-a."*  # no lane working: a Goal step waiting is a gap
  mkdir -p "$d/main/data/jg-goal-loop"
  assert_equals "$(verdict "$(hb "$d" rows)" overwatch)" IDLE "no lane and no Goal step is idle"
  printf 'ship 1\n' > "$d/main/data/jg-goal-loop/goal-a.next"
  out=$(hb "$d" rows)
  assert_equals "$(verdict "$out" overwatch)" GAP "a Goal step waiting for the lead is a gap"
  assert_contains "$out" "1 Goal step(s) next" "the row names the Goal step"
  rm -f "$d/main/data/jg-goal-loop/goal-a.next"
  assert_equals "$(verdict "$(hb "$d" rows)" overwatch)" IDLE "a taken step closes the gap"
  pass "rows count a Goal step waiting for the lead as ready work and name it"
}
test_a_goal_step_waiting_is_ready_work_named_in_the_row

# The ready count is the store's count of tickets that can start, written by the real refresh
# and read by the real heartbeat. A stand-in bd serves 200 ready rows, 6 of which name a
# registered project and can start; the rest name no project or another one.
store_home() {  # <dir> -> a home with a stand-in store, its pinned tools, and one registered project
  local d=$1 os arch
  mkdir -p "$d/bin" "$d/state" "$d/config" "$d/data" "$d/store/.beads/embeddeddolt/jg"
  printf '{"dolt_mode": "embedded", "dolt_database": "jg"}\n' > "$d/store/.beads/metadata.json"
  printf 'no-git-ops: true\n' > "$d/store/.beads/config.yaml"
  cat > "$d/bin/bd" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ready) [ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"; cat "$ROWS_READY" ;;
  list) cat "$ROWS_ALL" ;;
  blocked) echo '[]' ;;
esac
SH
  { cat "$d/bin/bd"; printf '# dolt\n'; } > "$d/bin/dolt"
  chmod +x "$d"/bin/*
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m); case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  sha() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
  printf 'bd 1.3.4\ndolt 2.6.0\nbd-sha256-%s-%s %s\ndolt-sha256-%s-%s %s\n' \
    "$os" "$arch" "$(sha "$d/bin/bd")" "$os" "$arch" "$(sha "$d/bin/dolt")" > "$d/pins"
  printf '%s\n' "$d/store/.beads" > "$d/config/beads-dir"
  printf -- '- proj [local-trunk] - the one project (added 2026-11-01)\n' > "$d/data/projects.md"
  python3 - "$d" <<'PY'
import json, sys
d = sys.argv[1]
rows = []
for i in range(200):
    labels = ["project:proj"] if i < 6 else (["project:other"] if i < 100 else [])
    rows.append({"id": "t%d" % i, "title": "[feature] row %d" % i, "status": "open", "issue_type": "task",
                 "created_at": "2026-11-01T00:00:00Z", "labels": labels, "metadata": {},
                 "dependency_count": 0, "dependent_count": 0})
json.dump(rows, open(d + "/ready.json", "w"))
json.dump(rows, open(d + "/all.json", "w"))
PY
  touch "$d/state/.last-watcher-beat"
}

store_env() {  # <dir> command...: run with the home's stand-in store
  local d=$1
  shift
  env JG_HOME="$d" JG_PIN_FILE_OVERRIDE="$d/pins" JG_BEADS_BD="$d/bin/bd" JG_BEADS_DOLT="$d/bin/dolt" \
    ROWS_READY="$d/ready.json" ROWS_ALL="$d/all.json" "$@"
}

test_ready_count_is_what_can_start_and_never_from_an_old_number() {
  local d=$TMP_ROOT/spawnable out
  store_home "$d"
  out=$(store_env "$d" "$ROOT/bin/jg-backlog.sh" ready --spawnable 2>&1) || fail "ready --spawnable failed: $out"
  assert_contains "$out" "count: 6" "6 of 200 ready rows can start"
  assert_contains "$(store_env "$d" "$ROOT/bin/jg-backlog-spawnable.sh" 2>&1)" "count: 6" "the reader behind it gives the same count"
  # A lane holding one of the six takes it out of the count.
  printf 'kind=ship\n' > "$d/state/t0.meta"; printf 'working [at=1]: x\n' > "$d/state/t0.status"
  assert_contains "$(store_env "$d" "$ROOT/bin/jg-backlog.sh" ready --spawnable 2>&1)" "count: 5" "a ticket a live lane holds cannot start"
  rm -f "$d/state/t0.meta" "$d/state/t0.status"
  store_env "$d" "$ROOT/bin/jg-home-summary-refresh.sh" || fail "refresh failed"
  assert_equals "$(jq -r .ready_work "$d/state/home-summary.json")" 6 "the summary carries the count the store gives"
  # All lanes busy: no GAP.
  printf '1\n' > "$d/config/lane-target"
  lane "$d" ship-a 'working [at=1]: building'
  out=$(env JG_HOME="$d" "$HB" rows)
  assert_equals "$(verdict "$out" overwatch)" MOVING "every lane busy is no gap, whatever the ready rows"
  # A free lane: GAP naming 6.
  printf '2\n' > "$d/config/lane-target"
  out=$(env JG_HOME="$d" "$HB" rows)
  assert_equals "$(verdict "$out" overwatch)" GAP "a free lane with ready work is a gap"
  assert_contains "$out" "6 ready, 1 of 2 lanes working" "the GAP names the count the store gives"
  # A summary 59 hours old: ready not known, no GAP, one stale line.
  jq --argjson t "$(( $(date +%s) - 59 * 3600 ))" '.generated_epoch = $t' "$d/state/home-summary.json" > "$d/s.tmp" \
    && mv "$d/s.tmp" "$d/state/home-summary.json"
  out=$(env JG_HOME="$d" "$HB" rows)
  assert_not_contains "$(verdict "$out" overwatch)" GAP "an old number never makes a gap"
  assert_contains "$out" "summary is stale (3540 min old), ready not known" "the row says the summary is stale, once"
  assert_equals "$(printf '%s\n' "$out" | grep -o 'summary is stale' | wc -l | tr -d ' ')" 1 "one stale line"
  assert_equals "$(printf '%s\t' "$out" | cut -f5)" '?' "the ready count is not known"
  assert_equals "$(env JG_HOME="$d" "$HB" check | grep -c GAP)" 0 "the check wakes nobody for an old number"
  pass "the ready count is what can start, and an old number is not known"
}
test_ready_count_is_what_can_start_and_never_from_an_old_number

test_a_slow_store_ends_the_read_at_its_limit_and_the_heartbeat_stays_fast() {
  local d=$TMP_ROOT/slow start took out
  store_home "$d"
  start=$(date +%s)
  out=$(STUB_SLEEP=70 JG_BACKLOG_SPAWNABLE_LIMIT=2 store_env "$d" "$ROOT/bin/jg-backlog.sh" ready --spawnable 2>&1); code=$?
  took=$(( $(date +%s) - start ))
  expect_code 124 "$code" "a store that sleeps 70 s ends at its limit: $out"
  [ "$took" -lt 10 ] || fail "the read ran $took s, past its limit"
  start=$(date +%s)
  STUB_SLEEP=70 JG_BACKLOG_SPAWNABLE_LIMIT=2 store_env "$d" "$ROOT/bin/jg-home-summary-refresh.sh" || fail "refresh failed"
  took=$(( $(date +%s) - start ))
  [ "$took" -lt 20 ] || fail "the refresh ran $took s with a 2-second store limit"
  assert_equals "$(jq -r '.ready_work' "$d/state/home-summary.json")" null "a store that did not answer leaves the count not known"
  start=$(date +%s)
  STUB_SLEEP=70 env JG_HOME="$d" "$HB" rows >/dev/null
  [ $(( $(date +%s) - start )) -lt 5 ] || fail "the heartbeat waited on the store"
  pass "a slow store ends the read at its limit and the heartbeat answers in its normal time"
}
test_a_slow_store_ends_the_read_at_its_limit_and_the_heartbeat_stays_fast

test_rows_give_every_home_one_verdict
test_an_open_wait_is_a_gap_and_filled_lanes_are_moving
test_a_paused_wait_is_named_as_paused_and_is_no_gap
test_a_lane_list_never_pauses_a_home_and_is_named
test_check_wakes_on_a_gap_refires_and_reports_recovery_once
test_arm_registers_a_check_the_watcher_trusts_only_on_a_primary_home
