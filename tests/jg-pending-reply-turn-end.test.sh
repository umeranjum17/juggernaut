#!/usr/bin/env bash
# A marked steer whose turn ends with no correlated reply is answered by the
# parent itself: one correlated `note` line naming the lead's last status, the
# record resolved, no repost and no second lead turn. When the parent cannot say
# honestly what the lead last reported, the repost stays the fallback.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DIR=$(jg_test_tmproot jg-pending-reply-turn-end)
HOME_DIR="$DIR/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$HOME_DIR/config"
trap 'rm -rf -- "$DIR"' EXIT

export JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE" JG_PENDING_REPLY_GRACE_SECS=0
BASE=$(( $(date +%s) - 600 ))
export JG_PENDING_REPLY_NOW=$((BASE + 100))
HOOK_LOG="$DIR/hook.log"
: > "$HOOK_LOG"
# shellcheck disable=SC2016 # the hook body keeps a literal $1 for the generated script
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s"\n' "$HOOK_LOG" > "$DIR/hook.sh"
chmod +x "$DIR/hook.sh"
export JG_PENDING_REPLY_SEND_HOOK="$DIR/hook.sh"

# shellcheck source=bin/jg-pending-reply-lib.sh
. "$ROOT/bin/jg-pending-reply-lib.sh"

# new_request <task>: a delivered request whose turn has ended, grace elapsed.
new_request() {
  local task=$1 corr
  corr=$(jg_pending_reply_create "$HOME_DIR" "$STATE" "$task" "please report on the build") || fail "no record for $task"
  JG_PENDING_REPLY_NOW=$BASE jg_pending_reply_mark_delivered "$STATE" "$corr" || fail "no delivery for $task"
  jg_pending_reply_set "$(jg_pending_reply_path "$STATE" "$corr")" request_turn_completed_epoch $((BASE + 10)) \
    || fail "no turn end for $task"
  printf '%s' "$corr"
}

rec_of() { jg_pending_reply_path "$STATE" "$1"; }

test_turn_end_without_the_token_posts_one_correlated_line() {
  local corr line
  corr=$(new_request lane-a)
  printf 'working [at=%s]: wiring the retry path\n' "$((BASE + 50))" >> "$STATE/lane-a.status"
  jg_pending_reply_send_recovery "$STATE" "$corr" || fail "the turn-end post did not complete"
  [ ! -s "$HOOK_LOG" ] || fail "a repost was sent although the line was posted"
  assert_equals resolved "$(jg_pending_reply_get "$(rec_of "$corr")" phase)" "the request was not recorded as answered"
  assert_equals turn-end "$(jg_pending_reply_get "$(rec_of "$corr")" resolved_via)" "the answer was not marked as the turn-end post"
  assert_equals "" "$(jg_pending_reply_get "$(rec_of "$corr")" recovery_attempted_epoch)" "a recovery was recorded as attempted"
  assert_equals 1 "$(grep -c "corr=$corr" "$STATE/lane-a.status")" "exactly one correlated line is expected"
  line=$(grep "corr=$corr" "$STATE/lane-a.status")
  assert_contains "$line" "note [" "the posted line is not a non-captain note"
  assert_contains "$line" "turn ended" "the line does not say the turn ended"
  assert_contains "$line" "working: wiring the retry path" "the line does not name the lead's last status"
  # Nothing else may happen on a later tick: no repost, no escalation line.
  jg_pending_reply_tick "$STATE" || true
  [ ! -s "$HOOK_LOG" ] || fail "a later tick sent a repost"
  assert_no_grep "pending-reply-missed" "$STATE/lane-a.status" "a resolved request escalated"
  pass "a turn that ends without the token gets one posted correlated line and no repost"
}

test_a_turn_that_already_replied_posts_nothing_extra() {
  local corr
  corr=$(new_request lane-b)
  printf 'done [at=%s]: corr=%s the build is green\n' "$((BASE + 60))" "$corr" >> "$STATE/lane-b.status"
  jg_pending_reply_try_resolve "$STATE" "$corr" || fail "the lead's own reply did not resolve"
  jg_pending_reply_send_recovery "$STATE" "$corr" && fail "a resolved request reached recovery"
  [ ! -s "$HOOK_LOG" ] || fail "a repost was sent after the reply"
  assert_equals 1 "$(wc -l < "$STATE/lane-b.status" | tr -d ' ')" "an extra line was posted after the lead replied"
  assert_equals status "$(jg_pending_reply_get "$(rec_of "$corr")" resolved_via)" "the lead's reply lost its own resolution"
  pass "a turn that already replied posts nothing extra"
}

test_no_honest_note_keeps_the_repost() {
  local corr
  corr=$(new_request lane-c)
  jg_pending_reply_send_recovery "$STATE" "$corr" || fail "the fallback repost was not sent"
  assert_contains "$(cat "$HOOK_LOG")" lane-c "the repost did not go to the lead"
  assert_equals recovery_sent "$(jg_pending_reply_get "$(rec_of "$corr")" phase)" "the fallback did not record the repost"
  [ ! -f "$STATE/lane-c.status" ] || fail "a line was posted with nothing honest to say"
  : > "$HOOK_LOG"
  corr=$(new_request lane-d)
  # Only an unplaced line, an older line and the parent's own escalation exist.
  {
    printf 'working: no stamp, so it cannot be placed in this turn\n'
    printf 'done [at=%s]: finished before the request\n' "$((BASE - 30))"
    printf 'blocked [key=pending-reply-%s]: pending-reply-missed\n' "$corr"
  } >> "$STATE/lane-d.status"
  jg_pending_reply_send_recovery "$STATE" "$corr" || fail "the fallback repost was not sent for an unplaceable log"
  assert_contains "$(cat "$HOOK_LOG")" lane-d "the repost did not go to the lead"
  assert_equals recovery_sent "$(jg_pending_reply_get "$(rec_of "$corr")" phase)" "the fallback did not record the repost"
  assert_no_grep "turn ended" "$STATE/lane-d.status" "a line was invented from nothing the lead reported"
  pass "the fallback still sends a repost when no note can be built"
}

test_turn_end_without_the_token_posts_one_correlated_line
test_a_turn_that_already_replied_posts_nothing_extra
test_no_honest_note_keeps_the_repost
