#!/usr/bin/env bash
# tests/jg-squad-lead-dormant.test.sh - a Squad Lead with no open work is stopped
# persist-first and marked dormant, the fleet heartbeat reads it dormant, and any
# routed work records the message before it wakes the lead (bin/jg-squad-lead-dormant.sh).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(jg_test_tmproot jg-squad-lead-dormant)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
DORMANT="$ROOT/bin/jg-squad-lead-dormant.sh"
HB="$ROOT/bin/jg-fleet-heartbeat.sh"
LOG="$TMP_ROOT/control.log"
SENDLOG="$TMP_ROOT/send.log"
export JG_BACKEND=tmux JG_ROOT_OVERRIDE="$TMP_ROOT/fakeroot"
# This test owns the lead's side of both planes: each fake logs its call.
fake_planes() {
  mkdir -p "$1/bin"
  cat > "$1/bin/jg-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$FAKE_CONTROL_LOG"
SH
  cat > "$1/bin/jg-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FAKE_SEND_LOG"
SH
  chmod +x "$1/bin/"*.sh
}
setup() {  # <name> -> a main home with one local lead home that has no open work
  local d=$TMP_ROOT/$1
  fake_planes "$TMP_ROOT/fakeroot"
  : > "$LOG"
  : > "$SENDLOG"
  mkdir -p "$d/main/state" "$d/main/config" "$d/main/data" "$d/lead/data" "$d/lead/state"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$d/lead/data/backlog.md"
  touch -d '2 hours ago' "$d/lead/data/backlog.md"
  printf 'kind=squad_lead\nhome=%s\nharness=claude\nbackend=tmux\nwindow=jg-lead\n' "$d/lead" > "$d/main/state/lead.meta"
  printf -- '- lead - a local lead (home: %s; scope: l; projects: l; added 2026-10-30)\n' "$d/lead" > "$d/main/data/squad_leads.md"
  printf '1\n' > "$d/main/config/squad-lead-dormant-secs"
  printf '%s\n' "$d"
}
sweep() {  # <case-dir> -> the sweep's reported lines
  env JG_HOME="$1/main" JG_STATE_OVERRIDE="$1/main/state" FAKE_CONTROL_LOG="$LOG" \
    FAKE_SEND_LOG="$SENDLOG" "$DORMANT" sweep 2>&1
}
rec_word() { awk 'NR == 1 { print $1 }' "$1/main/state/.squad-lead-dormant-lead" 2>/dev/null; }
test_idle_lead_is_asked_then_stopped_and_marked_dormant() {
  local d out
  d=$(setup asked)
  out=$(sweep "$d")
  assert_contains "$out" "asked: lead - persist first, then stop" "an idle lead is asked to persist first"
  assert_equals "$(rec_word "$d")" asked "the record holds the asked step"
  assert_equals "$(cat "$SENDLOG")" "lead" "the request reaches the lead through the data plane"
  assert_equals "$(cat "$LOG" 2>/dev/null)" "" "nothing is stopped before the lead answers"
  printf 'answered %s\n' "$(date +%s)" > "$d/main/state/.squad-lead-dormant-lead"
  out=$(sweep "$d")
  assert_contains "$out" "dormant: lead - stopped, wakes on routed work" "the answered lead is stopped"
  assert_equals "$(rec_word "$d")" dormant "the record says it is dormant"
  assert_equals "$(cat "$LOG")" "lead exit" "the stop goes through the control plane"
  pass "an idle lead is asked, answered, then stopped and marked dormant"
}
test_dormant_lead_reads_dormant_and_routed_work_wakes_it() {
  local d
  d=$(setup wake)
  printf 'dormant 1\n' > "$d/main/state/.squad-lead-dormant-lead"
  assert_contains "$(env JG_HOME="$d/main" "$HB" rows)" "lead	DORMANT" "the fleet dashboard shows a dormant lead"
  assert_not_contains "$(env JG_HOME="$d/main" "$HB" check)" "lead" "a dormant lead raises no gap or stall alarm"
  assert_equals "$(sweep "$d")" "" "a dormant lead with no work is left alone"
  printf '## In flight\n- [ ] fresh-work - something to do\n\n## Queued\n\n## Done\n' > "$d/lead/data/backlog.md"
  sweep "$d" > /dev/null
  assert_equals "$(cat "$LOG")" "lead relaunch" "routed work relaunches the lead"
  assert_equals "$(rec_word "$d")" "" "the dormant record drops when the lead wakes"
  pass "a dormant lead reads dormant and routed work wakes it"
}
test_routed_send_records_then_wakes_the_lead() {
  local d rec i=0
  d=$(setup send)
  printf 'dormant 1\n' > "$d/main/state/.squad-lead-dormant-lead"
  env JG_HOME="$d/main" JG_STATE_OVERRIDE="$d/main/state" FAKE_CONTROL_LOG="$LOG" \
    "$ROOT/bin/jg-send.sh" lead "hello lead" > /dev/null 2>&1 \
    || fail "a routed send to a dormant lead should record the message and exit 0"
  set -- "$d"/main/state/lead.inbox/*.msg
  rec=''
  [ -f "$1" ] && rec=$1
  [ -n "$rec" ] || fail "the routed send did not record the message in the lead's inbox"
  # The relaunch waits for the replacement agent to come up, so the send detaches
  # it: the record above is the delivery, and the wake lands in the background.
  while [ "$i" -lt 100 ] && [ "$(rec_word "$d")" = dormant ]; do sleep 0.1; i=$((i + 1)); done
  assert_equals "$(cat "$LOG")" "lead relaunch" "a routed send relaunches the dormant lead"
  assert_equals "$(rec_word "$d")" "" "the wake clears the dormant record"
  pass "a routed send records the message first and wakes the lead in the background"
}
test_a_lead_with_open_work_or_recent_activity_is_left_alone() {
  local d
  d=$(setup busy)
  printf '## In flight\n- [ ] wip - in progress\n\n## Queued\n\n## Done\n' > "$d/lead/data/backlog.md"
  assert_equals "$(sweep "$d")" "" "a lead with an open item is not touched"
  assert_equals "$(rec_word "$d")" "" "no record is written for a working lead"
  printf '0\n' > "$d/main/config/squad-lead-dormant-secs"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$d/lead/data/backlog.md"
  touch -d '2 hours ago' "$d/lead/data/backlog.md"
  assert_equals "$(sweep "$d")" "" "an idle time of 0 turns the rule off"
  # The rule compares whole-second mtimes (bin/jg-squad-lead-dormant.sh
  # quiet_secs), so a one-second threshold is met by the fraction of a second a
  # touch takes to cross a boundary and the case flips on the wall clock alone.
  # Three seconds keeps the case clear of that granularity: a record touched a
  # moment ago still reads well under the threshold.
  printf '3\n' > "$d/main/config/squad-lead-dormant-secs"
  touch "$d/lead/data/backlog.md"
  assert_equals "$(sweep "$d")" "" "a lead whose records just changed is not idle yet"
  pass "a lead with open work or recent activity is left alone"
}
test_idle_lead_is_asked_then_stopped_and_marked_dormant
test_dormant_lead_reads_dormant_and_routed_work_wakes_it
test_routed_send_records_then_wakes_the_lead
test_a_lead_with_open_work_or_recent_activity_is_left_alone
