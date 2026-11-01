#!/usr/bin/env bash
# tests/jg-comms-feed.test.sh - the fleet comms feed carries a steer and its
# reply, in order, once each, and never a credential (bin/jg-comms-feed.sh).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-comms-feed)
FEED_SH="$ROOT/bin/jg-comms-feed.sh"
# Fixed epochs keep the ordering assertion about the sources, not the clock.
STEER_AT=2026-10-30T05:00:00Z
STEER_EPOCH=1793336400
REPLY_EPOCH=1793336460
PENDING_EPOCH=1793336520

setup() {  # <name> -> echoes the case dir: one ship task w1 in a home of its own
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state/w1.inbox/handled" \
    "$d/so/.sign-off"
  printf '{"schema":2,"items":[]}\n' > "$d/so/.sign-off/decisions.json"
  : > "$d/so/.sign-off/decisions.answers.jsonl"
  printf 'kind=ship\nhome=%s/home\n' "$d" > "$d/home/state/w1.meta"
  printf '%s\n' "$d"
}

run() {  # <case-dir> <command> args...
  local d=$1
  shift
  env JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" SIGN_OFF_HOME="$d/so" "$@" 2>&1
}

feed() { cat "$1/home/state/comms-feed.jsonl" 2>/dev/null; }

feed_row() {  # <case-dir> <kind> -> the first feed line of that kind
  feed "$1" | jq -c "select(.kind == \"$2\")" | head -n1
}

test_a_steer_and_its_reply_land_in_order_once_each() {
  local d steer reply out second
  d=$(setup ordered)
  printf 'at=%s\nfrom=main\n--\nMainNNN [key=fix-parser] Fix the parser and report.\n' \
    "$STEER_AT" > "$d/home/state/w1.inbox/001.msg"
  printf 'working [at=%s]: parser reproduced\n' "$REPLY_EPOCH" > "$d/home/state/w1.status"
  printf 'schema=jg-pending-reply.v1\ncorr_id=corr-1\nphase=open\ntask_id=w1\ncreated_epoch=%s\nrequest_summary=which parser mode?\n\n' \
    "$PENDING_EPOCH" > "$d/home/state/reply-state.tsv"
  # The ledger is read last but carries the oldest exchange, so the feed is in
  # time order only if the pass sorts across sources.
  printf '{"event":"task.pr_ready","ts":1793330000,"task":"w1","kind":"ship","project":"demo","pr":"https://example.test/pr/1"}\n' \
    > "$d/home/state/fleet-ledger.jsonl"

  out=$(run "$d" "$FEED_SH" sync) || fail "sync failed: $out"
  [ "$(wc -l < "$d/home/state/comms-feed.jsonl")" = 4 ] \
    || fail "the feed did not carry the ledger line, steer, status and reply:"$'\n'"$(feed "$d")"

  steer=$(feed_row "$d" steer)
  reply=$(feed_row "$d" reply)
  assert_contains "$steer" '"from":"main"' "the steer is not from Main"
  assert_contains "$steer" '"to":"w1"' "the steer is not addressed to the task"
  assert_contains "$steer" '"state":"unread"' "an unread steer is not marked unread"
  assert_contains "$steer" '"tag":"MainNNN"' "the steer lost its order tag"
  assert_contains "$steer" '"key":"fix-parser"' "the steer lost its decision key"
  assert_contains "$reply" '"to":"main"' "the reply does not answer Main"
  assert_contains "$reply" '"state":"unread"' "an open reply is not marked unread"

  # Order: time across sources, and the reply after the steer it answers.
  [ "$(feed "$d" | jq -r '.kind' | tr '\n' ' ')" = 'status steer status reply ' ] \
    || fail "the exchanges are not in the order they happened:"$'\n'"$(feed "$d")"
  [ "$(feed "$d" | jq -r '.ts' | tr '\n' ' ')" = "1793330000 $STEER_EPOCH $REPLY_EPOCH $PENDING_EPOCH " ] \
    || fail "the feed is not in time order, so a reader cannot tail it:"$'\n'"$(feed "$d")"

  # Append-only and incremental: a second pass rewrites nothing and repeats nothing.
  second=$(run "$d" "$FEED_SH" sync) || fail "second sync failed: $second"
  [ "$(wc -l < "$d/home/state/comms-feed.jsonl")" = 4 ] \
    || fail "a second pass repeated messages:"$'\n'"$(feed "$d")"

  # A newly answered exchange appends after the existing lines without rewriting them.
  before=$(feed "$d")
  printf 'working [at=1793336600]: second pass\n' >> "$d/home/state/w1.status"
  run "$d" "$FEED_SH" sync > /dev/null || fail "third sync failed"
  case "$(feed "$d")" in
    "$before"*) : ;;
    *) fail "the feed rewrote or reordered earlier lines" ;;
  esac
  # A pass that carries prior state and emits one new message must not lose a
  # cursor key: the NEXT unchanged pass is where a lost key re-emits what the
  # feed already recorded, so run one and hold the line count.
  run "$d" "$FEED_SH" sync > /dev/null || fail "fourth sync failed"
  [ "$(wc -l < "$d/home/state/comms-feed.jsonl")" = 5 ] \
    || fail "an incremental pass repeated messages:"$'\n'"$(feed "$d")"
  [ -z "$(feed "$d" | jq -r '[.ts, .from, .kind, .text] | @tsv' | sort | uniq -d)" ] \
    || fail "the feed holds the same message twice:"$'\n'"$(feed "$d")"
  # The cursor is one "key<TAB>value" per line. A value that swallowed another
  # key (a newline lost between passes) shows up here as an extra field, which is
  # what silently re-emits already-recorded messages two passes later.
  awk -F'\t' 'NF != 2 { print "malformed cursor line: " $0; bad = 1 } END { exit (bad ? 1 : 0) }' \
    "$d/home/state/.comms-feed-cursor" || fail "the cursor lost a key onto another line"
  pass "a steer and its reply land in the feed in order, once each, append-only"
}

test_the_feed_carries_no_credential_and_opens_no_auth_file() {
  local d secret body
  d=$(setup redacted)
  secret=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
  # A credential store beside the state, plus a secret-shaped message.
  printf 'AUTH_FILE_MARKER=%s\n' "$secret" > "$d/home/.env"
  printf '{"token":"%s"}\n' "$secret" > "$d/home/auth.json"
  printf 'working [at=%s]: used token=%s for the API_KEY=%s\n' \
    "$REPLY_EPOCH" "$secret" "$secret" > "$d/home/state/w1.status"

  run "$d" "$FEED_SH" sync > /dev/null || fail "sync failed"
  body=$(feed "$d")
  [ -n "$body" ] || fail "the feed carried nothing"
  assert_not_contains "$body" "$secret" "the feed wrote a credential verbatim"
  assert_not_contains "$body" 'AUTH_FILE_MARKER' "the feed read a credential store"
  assert_contains "$body" '[redacted]' "the credential was dropped instead of redacted"
  assert_contains "$body" 'used token' "redaction destroyed the readable message"
  pass "secret-shaped values are redacted and no auth file or .env is read"
}

test_a_lead_home_feeds_its_own_room_through_the_parent_home() {
  local d out
  d=$(setup lead-room)
  mkdir -p "$d/mate/state"
  printf 'kind=squad_lead\nhome=%s/mate\n' "$d" > "$d/home/state/mate.meta"
  printf 'MainNNN [key=room] ship the room view\n' > "$d/mate/state/parent-replies.status"

  out=$(run "$d" "$FEED_SH" sync) || fail "sync failed: $out"
  out=$(feed_row "$d" parent-channel)
  assert_contains "$out" "\"home\":\"$d/mate\"" "the lead home is not the recording home"
  assert_contains "$out" '"channel":"mate"' "the lead's own room is not the channel"
  assert_contains "$out" '"from":"mate"' "the lead's line is not from the lead"
  assert_contains "$out" '"to":"main"' "the lead's line does not go to Main"
  pass "a recorded lead home reports into its own room with a parent-channel kind"
}

test_a_steer_and_its_reply_land_in_order_once_each
test_the_feed_carries_no_credential_and_opens_no_auth_file
test_a_lead_home_feeds_its_own_room_through_the_parent_home
