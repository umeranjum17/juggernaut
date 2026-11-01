#!/usr/bin/env bash
# Behavioral regressions for owner-correction capture (bin/jg-owner-correction.sh
# and the turn-end rule that reads it, docs/turnend-guard.md "Owner-correction
# capture rule"), built from the real case: the owner said "I don't want these
# feedbacks as one time fix ... so it doesn't repeat again". A turn that follows
# that correction with neither an owner rule nor an enforcement ticket is refused
# once; a turn that writes either artefact ends. The trigger is the recorded
# captain message's KPI kind, never a reading of his tone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-owner-correction)
jg_git_identity fmtest fmtest@example.invalid

CORRECTION="I don't want these feedbacks as one time fix this need to go into juggernaut as feedback so it doesn't repeat again"

# A primary-shaped home holding its own copy of bin/, so the guard and the check
# resolve that home's state, data, and backlog exactly as a real one would.
make_home() {  # <dir>
  mkdir -p "$1/state" "$1/config"
  cp -R "$ROOT/bin" "$1/bin"
  chmod +x "$1/bin/jg-turnend-guard.sh" "$1/bin/jg-owner-correction.sh"
  git init -q -b main "$1"
  git -C "$1" remote add origin https://github.com/acme/juggernaut.git
  : > "$1/AGENTS.md"
  jg_test_tasks_toml "$1/.tasks.toml"
}

in_home() {  # <dir> <command...>
  local home=$1
  shift
  JG_ROOT_OVERRIDE="$home" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" "$@"
}

kpi() { in_home "$1" "$1/bin/jg-overwatch-kpi.sh" "${@:2}"; }

submit() {  # <dir> <prompt>
  jq -cn --arg p "$2" '{hook_event_name: "UserPromptSubmit", prompt_id: "p", prompt: $p}' | kpi "$1" hook claude
}

pending() { in_home "$1" bash "$1/bin/jg-owner-correction.sh" pending; }

stop() {  # <dir> -> the guard's exit status
  printf '{"session_id":"s"}' | in_home "$1" bash "$1/bin/jg-turnend-guard.sh" >/dev/null 2>"$1/guard.err"
}

test_a_correction_with_no_artefact_is_flagged() {
  local home="$TMP_ROOT/uncaptured" rc out
  make_home "$home"
  submit "$home" "$CORRECTION"
  pending "$home" >/dev/null && fail "an untagged message was read as a recorded correction"
  kpi "$home" tag feedback https://github.com/acme/juggernaut/pull/41 >/dev/null \
    || fail "tagging the correction as feedback failed"
  out=$(pending "$home"); rc=$?
  assert_equals 0 "$rc" "a recorded correction with no artefact is not pending"
  assert_contains "$out" "feedback" "the pending line does not carry the recorded kind"
  stop "$home"; rc=$?
  assert_equals 2 "$rc" "a turn that followed an owner correction with neither artefact ended"
  for want in 'HE CORRECTED THE FLEET, AND NOTHING CAPTURED IT' 'jg-owner-rules.sh add --kind owner --words' \
    'jg-tasks-axi.sh add' 'one time fix'; do
    grep -qF "$want" "$home/guard.err" || fail "the block did not name '$want': $(cat "$home/guard.err")"
  done
  stop "$home"; rc=$?
  assert_equals 0 "$rc" "the same correction was charged twice, which can wedge a harness"
  submit "$home" "file a ticket to add CSV export"
  kpi "$home" tag new-work >/dev/null || fail "tagging new work failed"
  stop "$home"; rc=$?
  assert_equals 0 "$rc" "new work was refused for a missing correction capture"
  pass "the guard refuses a turn that follows an owner correction with no rule and no ticket, once, and never for new work"
}

test_an_owner_rule_captures_the_correction() {
  local home="$TMP_ROOT/rule" rc
  make_home "$home"
  submit "$home" "$CORRECTION"
  kpi "$home" tag feedback https://github.com/acme/juggernaut/pull/41 >/dev/null || fail "tagging failed"
  in_home "$home" bash "$home/bin/jg-owner-rules.sh" add --kind owner --words "$CORRECTION" \
    --scope "every owner correction" --enforce "bin/jg-turnend-guard.sh" >/dev/null \
    || fail "adding the owner rule failed"
  pending "$home" >/dev/null && fail "a recorded rule still reads as pending"
  stop "$home"; rc=$?
  assert_equals 0 "$rc" "a turn that wrote the owner rule was still refused"
  [ ! -s "$home/guard.err" ] || fail "the allowed turn printed: $(cat "$home/guard.err")"
  pass "an owner-rules entry captures the correction and the turn ends"
}

test_an_enforcement_ticket_captures_the_correction() {
  local home="$TMP_ROOT/ticket" rc
  make_home "$home"
  submit "$home" "$CORRECTION"
  kpi "$home" tag feedback https://github.com/acme/juggernaut/pull/41 >/dev/null || fail "tagging failed"
  in_home "$home" bash "$home/bin/jg-tasks-axi.sh" add capture-the-correction \
    "[feature] flag a turn that ends after an owner correction" \
    --body "an owner correction must become a rule or an enforcement ticket" >/dev/null \
    || fail "filing the enforcement ticket failed"
  pending "$home" >/dev/null && fail "a recorded ticket still reads as pending"
  stop "$home"; rc=$?
  assert_equals 0 "$rc" "a turn that filed the enforcement ticket was still refused"
  [ ! -s "$home/guard.err" ] || fail "the allowed turn printed: $(cat "$home/guard.err")"
  pass "an enforcement ticket captures the correction and the turn ends"
}

test_a_home_without_the_shared_check_says_so() {
  local home="$TMP_ROOT/not-picked-up" rc
  make_home "$home"
  rm -f "$home/bin/jg-owner-correction.sh"
  stop "$home"; rc=$?
  assert_equals 2 "$rc" "a home missing the shared check pretended it ran"
  grep -q 'THIS HOME HAS NOT PICKED UP OWNER-CORRECTION CAPTURE' "$home/guard.err" \
    || fail "the guard did not say the check is missing: $(cat "$home/guard.err")"
  stop "$home"; rc=$?
  assert_equals 0 "$rc" "the missing-check report repeated instead of saying it once"
  pass "a home that has not picked the check up says so once instead of pretending it ran"
}

test_a_correction_with_no_artefact_is_flagged
test_an_owner_rule_captures_the_correction
test_an_enforcement_ticket_captures_the_correction
test_a_home_without_the_shared_check_says_so
