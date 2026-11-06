#!/usr/bin/env bash
# The ticket rule: every captain-facing reply names the board ticket its work
# belongs to, so the captain can open it from the reply.
# The first case is a real captain-facing reply with no ticket behind it - the
# shape this rule exists to stop. Every other case drives a real command: the
# guard itself, the report helper a lead reports through, and the supervision
# branch's captain outcome.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/jg-ticket-link-guard.sh"
REPORT="$ROOT/bin/jg-squad-lead-report.sh"
BRANCH_REPORT="$ROOT/bin/jg-branch-report.sh"
TMP_ROOT=$(jg_test_tmproot jg-ticket-link-guard)

# A real report that reached the captain with no ticket behind it.
UNTICKETED='Captain, the release holds on your sign-in; the build is green.'

guard() {  # <text> -> RC, ERR
  printf '%s\n' "$1" | bash "$GUARD" 2>"$TMP_ROOT/stderr"
  RC=$?
  ERR=$(cat "$TMP_ROOT/stderr")
}

test_a_reply_with_no_ticket_is_refused() {
  guard "$UNTICKETED"
  [ "$RC" -eq 1 ] || fail "a captain reply with no ticket link must be refused, got exit $RC"
  assert_contains "$ERR" 'ticket link refused' 'the refusal names the ticket rule'
  assert_contains "$ERR" 'bin/jg-ticket.sh id <task-id>' 'the refusal names the one-line fix'
  pass 'a captain reply with no ticket link is refused, and the refusal names the fix'
}

test_replies_naming_a_ticket_pass() {
  local text
  for text in \
    'Captain, PR ready for review: https://github.com/umeranjum17/juggernaut/pull/310 #tickets/jg-abc' \
    'Captain, merged: http://100.64.0.1:4420/?token=SECRET#tickets/jg-4f2a now live' \
    '#tickets/JG-101'; do
    guard "$text"
    [ "$RC" -eq 0 ] || fail "a reply naming its ticket link was refused: $text"
  done
  pass 'a bare ticket link, a fully linked board URL, and a keyed ticket id all pass'
}

test_a_reply_naming_something_else_is_refused() {
  local text
  for text in \
    '' \
    'Captain, checks are green and the digest is current.' \
    'Captain, the checksum SHA-256 is in the log.' \
    'Captain, the decision card is up: http://100.64.0.1:4420/?token=SECRET#decide/abc'; do
    guard "$text"
    [ "$RC" -eq 1 ] || fail "a reply with no ticket link must be refused: $text"
  done
  pass 'an empty reply, a bare PR notice, a checksum, and a decision card link are all refused'
}

test_the_lead_report_helper_refuses_before_append() {
  local dir="$TMP_ROOT/report"
  mkdir -p "$dir/state" "$dir/parent/state"
  printf 'umer\n' > "$dir/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" \
    > "$dir/.jg-squad-lead-parent"
  JG_HOME="$dir" bash "$REPORT" 'done' abcdef0123456789 "$UNTICKETED" 2>"$dir/stderr" \
    && fail 'the report helper accepted a captain report with no ticket link'
  assert_contains "$(cat "$dir/stderr")" 'bin/jg-ticket.sh id <task-id>' \
    'the report helper surfaces the ticket fix'
  assert_absent "$dir/parent/state/umer.status" 'a refused report wrote nothing to the parent channel'
  JG_HOME="$dir" bash "$REPORT" 'done' abcdef0123456789 \
    'merged #tickets/jg-abc' 2>>"$dir/stderr" \
    || fail 'the report helper refused a report that names its ticket'
  assert_grep 'merged #tickets/jg-abc' "$dir/parent/state/umer.status" \
    'the ticketed report reaches the parent channel'
  pass 'the report helper refuses before append and accepts the ticketed report'
}

test_the_branch_report_refuses_a_captain_outcome_with_no_ticket() {
  local home="$TMP_ROOT/home" state="$TMP_ROOT/home/state"
  mkdir -p "$state"
  printf 'turn=t1\nrows=4\ntasks=alpha\nunscoped=0\nwake=signal: alpha.status\n' \
    > "$state/.supervision-host-turn"
  JG_HOME="$home" JG_SUPERVISION_ACTOR=branch JG_BRANCH_REPORT_TURN=t1 \
    "$BRANCH_REPORT" --task alpha --verdict captain --summary "$UNTICKETED" 2>"$TMP_ROOT/branch.stderr"
  local rc=$?
  expect_code 3 "$rc" 'a captain outcome with no ticket link must be refused'
  assert_contains "$(cat "$TMP_ROOT/branch.stderr")" 'bin/jg-ticket.sh id <task-id>' \
    'the branch report surfaces the ticket fix'
  [ ! -s "$state/branch-outcomes.jsonl" ] || fail 'a refused captain outcome was stored'
  JG_HOME="$home" JG_SUPERVISION_ACTOR=branch JG_BRANCH_REPORT_TURN=t1 \
    "$BRANCH_REPORT" --task alpha --verdict captain \
    --summary 'PR ready for review #tickets/jg-abc' >"$TMP_ROOT/branch.out" 2>&1 \
    || fail "the branch report refused a captain outcome that names its ticket: $(cat "$TMP_ROOT/branch.out")"
  assert_grep '#tickets/jg-abc' "$state/branch-outcomes.jsonl" \
    'the ticketed captain outcome is stored'
  pass 'the branch report refuses an unticketed captain outcome before storing it'
}

test_a_routine_branch_outcome_needs_no_ticket() {
  local home="$TMP_ROOT/home-routine" state="$TMP_ROOT/home-routine/state"
  mkdir -p "$state"
  printf 'turn=r1\nrows=2\ntasks=beta\nunscoped=0\nwake=signal: beta.status\n' \
    > "$state/.supervision-host-turn"
  JG_HOME="$home" JG_SUPERVISION_ACTOR=branch JG_BRANCH_REPORT_TURN=r1 \
    "$BRANCH_REPORT" --task beta --verdict routine --summary 'worker recovered automatically' \
    >"$TMP_ROOT/routine.out" 2>&1 \
    || fail "a routine supervision outcome must not need a ticket: $(cat "$TMP_ROOT/routine.out")"
  pass 'a routine supervision outcome stays unchecked, because it is not a captain reply'
}

test_a_reply_with_no_ticket_is_refused
test_replies_naming_a_ticket_pass
test_a_reply_naming_something_else_is_refused
test_the_lead_report_helper_refuses_before_append
test_the_branch_report_refuses_a_captain_outcome_with_no_ticket
test_a_routine_branch_outcome_needs_no_ticket
printf 'jg-ticket-link-guard: ok\n'
