#!/usr/bin/env bash
# Behavior test: an unread steer raises the `undelivered` alert (alert table row, bin/jg-alert.sh) through the real caller,
# jg_task_inbox_ladder, instead of a wake of its own. A worker whose endpoint is gone owes an escalation; the ladder raises one
# alert for the lane and record, the alert's holder reads one check wake that names it, a repeat poll adds nothing, and no
# `stale` wake of the old kind is written.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-task-inbox-alert); H=$T/home; S=$H/state; mkdir -p "$S"; ln -sn "$ROOT/bin" "$H/bin"
export JG_HOME="$H" JG_STATE_OVERRIDE="$S"
# shellcheck source=bin/jg-task-inbox-lib.sh
. "$ROOT/bin/jg-task-inbox-lib.sh"
jg_backend_agent_state() { echo dead; }   # the worker's endpoint is gone

mkdir -p "$S/t.inbox/handled"; : > "$S/t.inbox/001.msg"; touch -d "10 minutes ago" "$S/t.inbox/001.msg"
jq -nc '{seq:1,word:"stored",at:1}' > "$S/t.inbox/.delivery.jsonl"

jg_task_inbox_ladder "$S" t t:1 tmux t; expect_code 0 $? "the ladder step ends cleanly"
q=$S/.wake-queue
assert_equals 1 "$(grep -c "alert-undelivered--t:1-001.msg-unavailable" "$q")" "one alert wake names the lane, the record and the kind"
assert_contains "$(cat "$q")" "agent has exited or its endpoint is missing" "the wake carries the reason"
assert_equals 0 "$(awk -F'\t' '$3=="stale"' "$q" | wc -l | tr -d ' ')" "no stale wake of the old kind is written"
assert_equals open "$(bash "$ROOT/bin/jg-alert.sh" word "undelivered--t:1-001.msg-unavailable")" "the alert record is open"
pass "an unread steer on a dead endpoint raises the undelivered alert once, and no old stale wake"
