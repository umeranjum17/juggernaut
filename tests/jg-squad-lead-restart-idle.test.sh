#!/usr/bin/env bash
# tests/jg-squad-lead-restart-idle.test.sh - a restart pass starts no agent for a
# local Squad Lead that has nothing to resume, the first routed steer starts it
# with the message already recorded, and a lead with work relaunches at once
# (bin/jg-squad-lead-restart.sh, bin/jg-squad-lead-dormant.sh stop-idle).
set -u
# shellcheck source=tests/squad-lead-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/squad-lead-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-squad-lead-restart-idle)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
LOG="$TMP_ROOT/control.log"
FAKEROOT="$TMP_ROOT/fakeroot"
export JG_BACKEND=tmux JG_ROOT_OVERRIDE="$FAKEROOT"
export JG_FAKE_TMUX_LOG="$TMP_ROOT/tmux.log" JG_FAKE_TMUX_CAPTURE="$TMP_ROOT/pane.txt"
FAKEBIN=$(make_fake_tmux "$TMP_ROOT")
export PATH="$FAKEBIN:$PATH"

# The restart pass resolves every helper beside itself, so its copy runs from a
# bin/ of links to the real scripts, with the control plane and the data plane
# replaced by fakes that log their calls. The fake send answers a persist request
# the way a lead does: it confirms delivery and posts the correlated reply.
mkdir -p "$FAKEROOT/bin"
for f in "$ROOT"/bin/*; do ln -s "$f" "$FAKEROOT/bin/${f##*/}"; done
ln -s "$ROOT/toolchain.versions" "$FAKEROOT/toolchain.versions"
rm -f "$FAKEROOT/bin/jg-control.sh" "$FAKEROOT/bin/jg-send.sh"
cat > "$FAKEROOT/bin/jg-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$FAKE_CONTROL_LOG"
SH
cat > "$FAKEROOT/bin/jg-send.sh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/jg-pending-reply-lib.sh"
corr=${JG_PENDING_REPLY_EXISTING_CORR:-}
[ -n "$corr" ] || exit 0
jg_pending_reply_mark_delivered "$JG_STATE_OVERRIDE" "$corr" || exit 1
jg_pending_reply_corr_token "$corr" token
printf 'done [at=%s]: persisted %s\n' "$(date +%s)" "$token" >> "$JG_STATE_OVERRIDE/$1.status"
SH
chmod +x "$FAKEROOT/bin/jg-control.sh" "$FAKEROOT/bin/jg-send.sh"

setup() {  # <name> -> a main home with one local lead whose own home has no open work
  local d=$TMP_ROOT/$1
  : > "$LOG"
  mkdir -p "$d/main/state" "$d/main/config" "$d/main/data" "$d/lead/data" "$d/lead/state"
  jg_test_beads_home "$d/lead"
  touch -d "2 hours ago" "$(cat "$d/lead/config/beads-dir")"
  printf 'kind=squad_lead\nhome=%s\nworktree=%s\nproject=%s\nendpoint_task_id=lead\nharness=claude\nbackend=tmux\nwindow=juggernaut:jg-lead\n' "$d/lead" "$d/lead" "$d/lead" > "$d/main/state/lead.meta"
  printf -- '- lead - a local lead (home: %s; scope: l; projects: l; added 2026-10-30)\n' "$d/lead" > "$d/main/data/squad_leads.md"
  printf '❯\n' > "$JG_FAKE_TMUX_CAPTURE"
  printf '%s\n' "$d"
}
restart() {  # <case-dir> -> the restart pass's report
  env JG_HOME="$1/main" JG_STATE_OVERRIDE="$1/main/state" FAKE_CONTROL_LOG="$LOG" \
    JG_FAKE_TMUX_WINDOW="juggernaut:jg-lead" JG_SQUAD_LEAD_PERSIST_WAIT=30 \
    JG_SQUAD_LEAD_IDLE_WAIT=5 JG_SQUAD_LEAD_PERSIST_POLL=1 \
    "$FAKEROOT/bin/jg-squad-lead-restart.sh" lead 2>&1
}
rec_word() { awk 'NR == 1 { print $1 }' "$1/main/state/.squad-lead-dormant-lead" 2>/dev/null; }

test_idle_lead_restart_starts_nothing_and_first_steer_starts_it() {
  local d out i=0 msgs
  d=$(setup idle)
  out=$(restart "$d")
  assert_contains "$out" "restarted: lead (idle: stopped, starts on its first routed work)" "an idle lead is reported restarted but stopped"
  assert_contains "$out" "summary: 1 of 1 restarted, 0 nudged, 0 unreached" "the pass counts it restarted"
  assert_equals "$(cat "$LOG")" "lead exit" "the idle lead is stopped and no agent is started"
  assert_equals "$(rec_word "$d")" dormant "the stop leaves it marked dormant"
  # The first routed message records itself, then starts the lead in the background.
  env JG_HOME="$d/main" JG_STATE_OVERRIDE="$d/main/state" FAKE_CONTROL_LOG="$LOG" \
    JG_FAKE_TMUX_WINDOW="juggernaut:jg-lead" "$ROOT/bin/jg-send.sh" lead "first routed work" > /dev/null 2>&1 \
    || fail "a steer to a restarted idle lead should record the message and exit 0"
  while [ "$i" -lt 100 ] && [ "$(rec_word "$d")" = dormant ]; do sleep 0.1; i=$((i + 1)); done
  assert_equals "$(cat "$LOG")" "lead exit
lead relaunch" "the first steer starts the lead"
  assert_equals "$(rec_word "$d")" "" "the start clears the dormant record"
  msgs=$(cat "$d"/main/state/lead.inbox/*.msg 2>/dev/null)
  assert_contains "$msgs" "first routed work" "the steer is waiting in the lead's inbox"
  pass "an idle lead restart starts nothing and the first steer starts it with the message delivered"
}

test_lead_with_work_or_an_open_request_relaunches_at_once() {
  local d out
  d=$(setup busy)
  jg_test_add "$d/lead" jg-wip "[feature] in progress"
  out=$(restart "$d")
  assert_contains "$out" "restarted: lead (claude) at" "a lead with an open item is relaunched"
  assert_equals "$(cat "$LOG")" "lead relaunch" "only the relaunch runs for a lead with work"
  assert_equals "$(rec_word "$d")" "" "a lead with work is not marked dormant"
  d=$(setup request)
  mkdir -p "$d/main/state/pending-replies"
  printf 'task_id=lead\nphase=awaiting_report\n' > "$d/main/state/pending-replies/0123456789abcdef"
  out=$(restart "$d")
  assert_contains "$out" "restarted: lead (claude) at" "a lead with an open request is relaunched"
  assert_equals "$(cat "$LOG")" "lead relaunch" "only the relaunch runs for a lead with an open request"
  d=$(setup unread)
  mkdir -p "$d/main/state/lead.inbox"
  printf 'queued steer\n' > "$d/main/state/lead.inbox/001.msg"
  out=$(restart "$d")
  assert_contains "$out" "restarted: lead (claude) at" "a lead with an unread message is relaunched"
  assert_equals "$(cat "$LOG")" "lead relaunch" "only the relaunch runs for a lead with a queued message"
  pass "a lead with work, an open request or a queued message relaunches at once"
}

test_idle_lead_restart_starts_nothing_and_first_steer_starts_it
test_lead_with_work_or_an_open_request_relaunches_at_once
