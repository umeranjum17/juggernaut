#!/usr/bin/env bash
# tests/jg-squad-lead-dormant.test.sh - a Squad Lead with no startable work is stopped
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
export JG_BACKEND=tmux JG_ROOT_OVERRIDE="$TMP_ROOT/fakeroot" FAKE_PENDING_LIB="$ROOT/bin/jg-pending-reply-lib.sh"
# shellcheck source=bin/jg-pending-reply-lib.sh
. "$FAKE_PENDING_LIB"
# This test owns the lead's side of both planes: each fake logs its call, and the
# send marks a correlated request delivered, as the real data plane does.
fake_planes() {
  mkdir -p "$1/bin"
  cat > "$1/bin/jg-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$FAKE_CONTROL_LOG"
SH
  cat > "$1/bin/jg-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FAKE_SEND_LOG"
. "$FAKE_PENDING_LIB"
[ -z "${JG_PENDING_REPLY_EXISTING_CORR:-}" ] || jg_pending_reply_mark_delivered "$JG_STATE_OVERRIDE" "$JG_PENDING_REPLY_EXISTING_CORR"
SH
  chmod +x "$1/bin/"*.sh
}
setup() {  # <name> -> a main home with one local lead home that has no open work
  local d=$TMP_ROOT/$1
  fake_planes "$TMP_ROOT/fakeroot"
  : > "$LOG"
  : > "$SENDLOG"
  mkdir -p "$d/main/state" "$d/main/config" "$d/main/data" "$d/lead/data" "$d/lead/state"
  jg_test_beads_home "$d/lead"
  printf -- '- demo - the fixture project\n' > "$d/lead/data/projects.md"
  touch -d '2 hours ago' "$d/lead/state/.wake-queue"
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
answer_persist() {  # <case-dir>: the lead reports on its parent channel with the persist request's token
  local token
  jg_pending_reply_corr_token "$(awk 'NR == 1 { print $3 }' "$1/main/state/.squad-lead-dormant-lead")" token
  printf 'done [at=%s]: persisted %s\n' "$(date +%s)" "$token" >> "$1/main/state/lead.status"
}
test_idle_lead_is_asked_then_stopped_and_marked_dormant() {
  local d out
  d=$(setup asked)
  out=$(sweep "$d")
  assert_contains "$out" "asked: lead - persist first, then stop" "an idle lead is asked to persist first"
  assert_equals "$(rec_word "$d")" asked "the record holds the asked step"
  assert_equals "$(cat "$SENDLOG")" "lead" "the request reaches the lead through the data plane"
  assert_equals "$(cat "$LOG" 2>/dev/null)" "" "nothing is stopped before the lead answers"
  answer_persist "$d"
  sweep "$d" > /dev/null
  assert_equals "$(rec_word "$d")" answered "the persist report is read as the answer"
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
  jg_test_add "$d/lead" jg-fresh-work "[feature] something to do"
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
test_idle_lead_with_only_held_work_sleeps_after_the_window_stays_silent_and_resumes() {
  local d out i=0
  d=$(setup journey)
  # Work it cannot start: a held ticket and a ticket blocked by it. Before this
  # rule counted only startable work, either kept the lead awake for good.
  jg_test_add "$d/lead" jg-held "[feature] waits for the owner"
  jg_test_backlog "$d/lead" hold jg-held --reason "owner decides" >/dev/null 2>&1 || fail "could not hold jg-held"
  jg_test_add "$d/lead" jg-after "[feature] after the held one" --blocked-by jg-held
  printf '3\n' > "$d/main/config/squad-lead-dormant-secs"
  touch "$d/lead/state/.wake-queue"
  assert_equals "$(sweep "$d")" "" "inside the idle window the lead is left alone"
  touch -d '1 minute ago' "$d/lead/state/.wake-queue"
  out=$(sweep "$d")
  assert_contains "$out" "asked: lead - persist first, then stop" "after the window an idle lead with only held work is asked to persist"
  answer_persist "$d"
  sweep "$d" > /dev/null
  assert_equals "$(rec_word "$d")" answered "the persist report is read as the answer"
  out=$(sweep "$d")
  assert_contains "$out" "dormant: lead - stopped, wakes on routed work" "the answered lead is stopped"
  assert_equals "$(cat "$LOG")" "lead exit" "the stop goes through the control plane"
  : > "$LOG"
  : > "$SENDLOG"
  while [ "$i" -lt 3 ]; do
    assert_equals "$(sweep "$d")" "" "a dormant sweep reports nothing"
    i=$((i + 1))
  done
  assert_equals "$(cat "$SENDLOG" "$LOG")" "" "a dormant lead gets no message and no relaunch: zero wakes"
  assert_equals "$(rec_word "$d")" dormant "the lead stays dormant across sweeps"
  env JG_HOME="$d/main" JG_STATE_OVERRIDE="$d/main/state" FAKE_CONTROL_LOG="$LOG" \
    "$ROOT/bin/jg-send.sh" lead "routed work" > /dev/null 2>&1 \
    || fail "a routed send to a dormant lead should record the message and exit 0"
  i=0
  while [ "$i" -lt 100 ] && [ "$(rec_word "$d")" = dormant ]; do sleep 0.1; i=$((i + 1)); done
  assert_equals "$(cat "$LOG")" "lead relaunch" "the routed message relaunches the lead"
  assert_contains "$(cat "$d"/main/state/lead.inbox/*.msg 2>/dev/null)" "routed work" "the routed message waits in the lead's inbox"
  assert_contains "$(jg_test_backlog "$d/lead" list 2>/dev/null)" "jg-held" "the lead's backlog survives the stop"
  pass "an idle lead with only held work sleeps after the window, gets no wakes, and resumes on a routed message"
}
test_a_lead_with_open_work_or_recent_activity_is_left_alone() {
  local d
  d=$(setup busy)
  jg_test_add "$d/lead" jg-wip "[feature] in progress"
  assert_equals "$(sweep "$d")" "" "a lead with a startable ticket is not touched"
  assert_equals "$(rec_word "$d")" "" "no record is written for a working lead"
  jg_test_backlog "$d/lead" "done" jg-wip >/dev/null
  mkdir -p "$d/main/state/pending-replies"
  printf 'task_id=lead\nphase=awaiting_report\n' > "$d/main/state/pending-replies/0123456789abcdef"
  assert_equals "$(sweep "$d")" "" "a lead that owes a report to its parent is not touched"
  rm -f -- "$d/main/state/pending-replies/0123456789abcdef"
  printf '0\n' > "$d/main/config/squad-lead-dormant-secs"
  touch -d '2 hours ago' "$d/lead/state/.wake-queue"
  assert_equals "$(sweep "$d")" "" "an idle time of 0 turns the rule off"
  # The rule compares whole-second mtimes (bin/jg-squad-lead-dormant.sh
  # quiet_secs), so a one-second threshold is met by the fraction of a second a
  # touch takes to cross a boundary and the case flips on the wall clock alone.
  # Three seconds keeps the case clear of that granularity: a record touched a
  # moment ago still reads well under the threshold.
  printf '3\n' > "$d/main/config/squad-lead-dormant-secs"
  touch "$d/lead/state/.wake-queue"
  assert_equals "$(sweep "$d")" "" "a lead whose records just changed is not idle yet"
  pass "a lead with open work or recent activity is left alone"
}
test_idle_lead_is_asked_then_stopped_and_marked_dormant
test_dormant_lead_reads_dormant_and_routed_work_wakes_it
test_routed_send_records_then_wakes_the_lead
test_idle_lead_with_only_held_work_sleeps_after_the_window_stays_silent_and_resumes
test_a_lead_with_open_work_or_recent_activity_is_left_alone
