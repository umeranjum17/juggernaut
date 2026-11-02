#!/usr/bin/env bash
# Behavioral regressions for the Overwatch KPI (bin/jg-overwatch-kpi.sh): each
# typed captain message is recorded, the turn-end guard refuses once to end a
# turn while the newest one is untagged, and a feedback or micromanagement tag
# needs a link to code work on this Juggernaut repository.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KPI="$ROOT/bin/jg-overwatch-kpi.sh"
GUARD="$ROOT/bin/jg-turnend-guard.sh"
SCRIPT_DIR_TASKS="$ROOT/bin/jg-tasks-axi.sh"
TMP_ROOT=$(jg_test_tmproot jg-overwatch-kpi)
jg_git_identity fmtest fmtest@example.invalid

make_home() {  # <dir>
  mkdir -p "$1/bin" "$1/state" "$1/config"
  git init -q -b main "$1"
  git -C "$1" remote add origin https://github.com/acme/juggernaut.git
  : > "$1/AGENTS.md"
}

in_home() {  # <dir> <command...>
  local home=$1
  shift
  JG_ROOT_OVERRIDE="$home" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" "$@"
}

submit() {  # <dir> <prompt>
  jq -cn --arg p "$2" '{hook_event_name: "UserPromptSubmit", prompt_id: "p", prompt: $p}' \
    | in_home "$1" "$KPI" hook claude
}

stop() {  # <dir> -> the guard's exit status
  printf '{"session_id":"s"}' | in_home "$1" "$GUARD" >/dev/null 2>"$1/guard.err"
}

test_hook_records_only_typed_captain_messages() {
  local home="$TMP_ROOT/hook" off="$TMP_ROOT/hook-off"
  make_home "$home"
  submit "$home" "why is the export PR still not open?"
  submit "$home" "$(printf '\342\201\243JUGGERNAUT_OP: v1 watcher: signal: demo.status')"
  submit "$home" '<task-notification>rewake</task-notification>'
  assert_equals 1 "$(wc -l < "$home/data/overwatch-kpi.jsonl" | tr -d ' ')" \
    "the hook recorded fleet machinery as a captain message"
  assert_equals "1	why is the export PR still not open?" "$(in_home "$home" "$KPI" pending)" \
    "the typed message is not the pending one"
  make_home "$off"
  printf 'off\n' > "$off/config/overwatch-kpi"
  submit "$off" "scripted lab prompt"
  [ ! -e "$off/data/overwatch-kpi.jsonl" ] || fail "a home with the KPI off still recorded a prompt"
  pass "the hook records a typed captain message and drops fleet machinery and opted-out homes"
}

test_a_doorbell_is_not_a_captain_message() {
  local home="$TMP_ROOT/doorbell" doorbell
  make_home "$home"
  # The doorbell the Claude record carrier types into the prompt box. It carries
  # no operational marker, so only its shape tells it apart from typed text.
  doorbell=$(in_home "$home" "$ROOT/bin/jg-operational-input.sh" record turn-end-guard \
    <<<'signal: demo.status') || fail "the operational-input protocol produced no doorbell"
  assert_equals 1 "$(printf '%s' "$doorbell" | grep -c '^: Juggernaut operational input waiting: read ')" \
    "the doorbell does not carry its documented prefix: $doorbell"
  submit "$home" "$doorbell"
  [ ! -e "$home/data/overwatch-kpi.jsonl" ] || fail "the hook counted a doorbell as a captain message"
  # A reworded doorbell must not leak through the exact-line check either.
  submit "$home" ": Juggernaut operational input waiting: read '/tmp/x/operational-inbox/1-aa.msg' now."
  [ ! -e "$home/data/overwatch-kpi.jsonl" ] || fail "a reworded doorbell was counted as a captain message"
  # The steering-inbox doorbell, with and without its leading colon, for any inbox name.
  local steer
  # shellcheck disable=SC2016 # the doorbell carries a literal $JG_TASK_INBOX
  for steer in ': Juggernaut instruction waiting: list "$JG_TASK_INBOX"/*.msg in your '"'"'a-b.inbox'"'"' steering inbox, read and act on each in numeric order, then mv each into its handled/.' \
    'Juggernaut instruction waiting: list "$JG_TASK_INBOX"/*.msg in your '"'"'other.inbox'"'"' steering inbox, read and act on each in numeric order, then mv each into its handled/.'; do
    submit "$home" "$steer"
    [ ! -e "$home/data/overwatch-kpi.jsonl" ] || fail "a steering doorbell was counted as a captain message"
  done
  submit "$home" "why is the export PR still not open?"
  assert_equals "$(printf '1\twhy is the export PR still not open?')" "$(in_home "$home" "$KPI" pending)" \
    "the real captain message is not the pending one"
  pass "a doorbell is skipped while the captain message beside it is counted"
}

test_guard_refuses_an_untagged_message_once() {
  local home="$TMP_ROOT/guard" rc
  make_home "$home"
  stop "$home"; rc=$?
  assert_equals 0 "$rc" "a home with no captain message was blocked"
  submit "$home" "status?"
  stop "$home"; rc=$?
  assert_equals 2 "$rc" "an untagged captain message let the turn end"
  grep -q 'CAPTAIN MESSAGE NOT TAGGED' "$home/guard.err" || fail "the block did not name the rule: $(cat "$home/guard.err")"
  grep -q 'Message: status?' "$home/guard.err" || fail "the block did not quote the message"
  stop "$home"; rc=$?
  assert_equals 0 "$rc" "the same message was charged twice, which can wedge a harness"
  submit "$home" "file a ticket to add CSV export"
  stop "$home"; rc=$?
  assert_equals 2 "$rc" "a second untagged message was not flagged"
  in_home "$home" "$KPI" tag new-work >/dev/null || fail "tagging new work failed"
  in_home "$home" "$KPI" pending >/dev/null && fail "a tagged message is still pending"
  submit "$home" "yes, merge it"
  in_home "$home" "$KPI" tag decision-answer >/dev/null || fail "tagging a decision answer failed"
  stop "$home"; rc=$?
  assert_equals 0 "$rc" "a tagged message still blocked the turn end"
  pass "the guard refuses once per untagged captain message and clears once it is tagged"
}

test_a_miss_needs_a_link_to_code_work() {
  local home="$TMP_ROOT/link" rc link
  make_home "$home"
  submit "$home" "stop asking me to merge red PRs"
  in_home "$home" "$KPI" tag praise >/dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "an unknown kind was accepted"
  for link in '' data/learnings.md learnings.md https://github.com/acme/other/pull/4 \
    https://github.com/acme/juggernaut/pull/4abc; do
    in_home "$home" "$KPI" tag feedback "$link" >/dev/null 2>&1; rc=$?
    assert_equals 2 "$rc" "feedback linked to '$link' was accepted"
  done
  in_home "$home" "$KPI" pending >/dev/null || fail "a refused tag still cleared the message"
  in_home "$home" "$KPI" tag feedback https://github.com/acme/juggernaut/pull/41 >/dev/null \
    || fail "feedback linked to a PR on this repository was refused"
  in_home "$home" "$KPI" pending >/dev/null && fail "a linked miss is still pending"
  git -C "$home" remote add lab git@gitlab.example:team/tools/jug.git
  submit "$home" "is it done yet?"
  in_home "$home" "$KPI" tag micromanagement https://gitlab.example/team/tools/jug/-/merge_requests/7 >/dev/null \
    || fail "micromanagement linked to a merge request on an ssh remote was refused"
  assert_equals micromanagement "$(jq -rs 'map(select(.tag == 2)) | last | .kind' "$home/data/overwatch-kpi.jsonl")" \
    "the tag did not land on the newest message"
  pass "a miss is refused without a code link and accepted with a PR or MR on this repository"
}

test_scorecard_counts_misses_and_excludes_the_old_ones() {
  local home="$TMP_ROOT/score" now day ago_week ago_old
  make_home "$home"
  now=$(date +%s)
  day=$(date -u -d "@$now" +%F 2>/dev/null || date -u -r "$now" +%F)
  # One miss two days back is inside the trailing week; one ten days back is
  # outside it, so the scorecard must leave the older one out entirely.
  ago_week=$((now - 2 * 86400))
  ago_old=$((now - 10 * 86400))
  submit "$home" "why is the export PR still not open?"
  in_home "$home" "$KPI" tag feedback https://github.com/acme/juggernaut/pull/41 >/dev/null \
    || fail "tagging a miss failed"
  submit "$home" "is it merged yet?"
  in_home "$home" "$KPI" tag micromanagement https://github.com/acme/juggernaut/pull/42 >/dev/null \
    || fail "tagging a miss failed"
  # Two misses this week but not today, and one older than the week, which the
  # scorecard must leave out of the live counts entirely.
  jq -cn --argjson week "$ago_week" --argjson old "$ago_old" '{seq: 3, epoch: $week, text: "chased again"}, {tag: 3, epoch: $week, kind: "feedback", link: "https://github.com/acme/juggernaut/pull/43"}, {seq: 4, epoch: $old, text: "old chase"}, {tag: 4, epoch: $old, kind: "feedback", link: "https://github.com/acme/juggernaut/pull/44"}' \
    >> "$home/data/overwatch-kpi.jsonl"
  local card
  card=$(in_home "$home" "$KPI" scorecard --json) || fail "the scorecard refused to run"
  assert_equals "$day 1 1 2" "$(printf '%s' "$card" | jq -r '.day | "\(.date) \(.feedback) \(.micromanagement) \(.total)"')" \
    "the day scorecard is wrong: $card"
  assert_equals "1 2 3" "$(printf '%s' "$card" | jq -r '.week | "\(.micromanagement) \(.feedback) \(.total)"')" \
    "the week scorecard is wrong: $card"
  assert_equals "3" "$(printf '%s' "$card" | jq -r '.misses | length')" \
    "the scorecard listed a miss older than its week"
  assert_contains "$(in_home "$home" "$KPI" scorecard)" "target 0" "the scorecard does not name the target"
  pass "the scorecard counts the day and the week against the target and leaves older misses out"
}

test_landed_asks_the_forge_and_the_backlog() {
  local home="$TMP_ROOT/landed" fakebin
  make_home "$home"
  jg_test_tasks_toml "$home/.tasks.toml"
  mkdir -p "$home/data" "$TMP_ROOT/fakebin"
  fakebin="$TMP_ROOT/fakebin"
  printf '#!/bin/sh\nprintf "number: 41\\nmerged: yes\\n"\n' > "$fakebin/gh-axi"
  chmod +x "$fakebin/gh-axi"
  in_home "$home" "$SCRIPT_DIR_TASKS" add export-fix-q1 "[feature] add CSV export" --body "users cannot export their data without it" >/dev/null 2>&1 \
    || fail "creating the backlog ticket failed"
  in_home "$home" "$SCRIPT_DIR_TASKS" 'done' export-fix-q1 >/dev/null 2>&1 \
    || fail "closing the backlog ticket failed"
  submit "$home" "stop shipping the export without the CSV column"
  in_home "$home" "$KPI" tag feedback https://github.com/acme/juggernaut/pull/41 >/dev/null \
    || fail "tagging a PR-linked miss failed"
  submit "$home" "and the export ticket is still open?"
  in_home "$home" "$KPI" tag micromanagement export-fix-q1 >/dev/null \
    || fail "tagging a backlog-linked miss failed"
  local card
  card=$(PATH="$fakebin:$PATH" in_home "$home" "$KPI" scorecard --landed) \
    || fail "the landed scorecard refused to run"
  assert_contains "$card" "pull/41  landed: yes" "the merged PR was not reported as landed"
  assert_contains "$card" "export-fix-q1  landed: yes" "the done backlog ticket was not reported as landed"
  pass "a miss reports whether its linked PR merged or its backlog ticket closed"
}

test_hook_records_only_typed_captain_messages
test_a_doorbell_is_not_a_captain_message
test_guard_refuses_an_untagged_message_once
test_a_miss_needs_a_link_to_code_work
test_scorecard_counts_misses_and_excludes_the_old_ones
test_landed_asks_the_forge_and_the_backlog
