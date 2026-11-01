#!/usr/bin/env bash
# tests/jg-reply-engine.test.sh - the pending-reply workflow engine in shadow.
#
# What it proves, in order: the fold reads one state per waiter out of the event
# log and keeps the last event per key; the decision binds a stage's activity to
# the deadline its timer derives, not to the instant a poll noticed it; the two
# delivery failures (a repost that could not be delivered, an escalation with no
# turn to bound it) are decided by the same rule the record path uses; the shadow
# tick records what it would do and acts on nothing - no status line, no record
# write, no repost; and the replay over a recorded log compares the decisions the
# two paths take at every instant, reports zero differences on a faithful
# recording, and reports differences when the replayed grace is moved, so a green
# replay is never vacuous.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENGINE="$ROOT/bin/jg-reply-engine.sh"
TMP_ROOT=$(jg_test_tmproot jg-reply-engine)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
mkdir -p "$STATE_DIR"
LOG="$TMP_ROOT/events.jsonl"

# put_event <kind> <id> <stage|-> <json-extra>: append one event in the shipped
# line format, <key>\t<digest>\t<json>.
put_event() {
  local kind=$1 id=$2 stage=$3 extra=$4 key json digest
  if [ "$stage" = - ]; then key="$kind/$id"; stage=''; else key="$kind/$id/$stage"; stage=",\"stage\":\"$stage\""; fi
  json="{\"v\":1,\"kind\":\"$kind\",\"id\":\"$id\",\"home\":\"h\"$stage$extra}"
  digest=$(printf '%s' "$json" | cksum | awk '{ print $1 }')
  printf '%s\t%s\t%s\n' "$key" "$digest" "$json" >> "$LOG"
}

engine() {
  JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" JG_REPLY_BUS_LOG="$LOG" \
    JG_REPLY_ENGINE_NOW=${NOW:-} "$ENGINE" "$@" 2>&1
}

# --- the fold ---------------------------------------------------------------
: > "$LOG"
put_event waiter a1 - ', "task":"mate", "grace":120, "at":1000, "state":"confirmed", "delivered":1010'
put_event timer a1 request ', "anchor":1020, "grace":120, "seen":true, "at":1020'
put_event fire a1 request ', "epoch":1150, "outcome":"confirmed", "at":1150'
put_event answer a1 - ', "epoch":1200, "via":"status", "at":1200'
put_event waiter a2 - ', "task":"mate", "grace":60, "at":2000, "state":"sent"'
# A superseding event must win: this second waiter event replaces the first.
put_event waiter a2 - ', "task":"mate", "grace":60, "at":2000, "state":"confirmed", "delivered":2010'

docs=$(engine docs)
assert_equals "2" "$(printf '%s\n' "$docs" | awk 'END { print NR + 0 }')" \
  "the fold keeps one state per waiter"
doc1=$(printf '%s\n' "$docs" | awk -F'\t' '$1 == "a1"')
assert_equals "confirmed" "$(awk -F'\t' '{ print $5 }' <<<"$doc1")" \
  "the fold carries the delivery state"
assert_equals "1020" "$(awk -F'\t' '{ print $8 }' <<<"$doc1")" \
  "the fold carries the request timer anchor"
assert_equals "1150" "$(awk -F'\t' '{ print $10 }' <<<"$doc1")" \
  "the fold carries the fired repost"
assert_equals "1200 status" "$(awk -F'\t' '{ print $16, $17 }' <<<"$doc1")" \
  "the fold carries the answer and how it came"
doc2=$(printf '%s\n' "$docs" | awk -F'\t' '$1 == "a2"')
assert_equals "confirmed" "$(awk -F'\t' '{ print $5 }' <<<"$doc2")" \
  "a superseding event replaces the earlier fact"
assert_equals "2010" "$(awk -F'\t' '{ print $6 }' <<<"$doc2")" \
  "a superseding event replaces the earlier delivery epoch"

# --- the decision -----------------------------------------------------------
: > "$LOG"
put_event waiter d1 - ', "task":"mate", "grace":120, "at":1000, "state":"confirmed", "delivered":1010'
put_event timer d1 request ', "anchor":1020, "grace":120, "seen":true, "at":1020'
assert_equals "$(printf 'arm\td1\trequest\t1140')" "$(engine decide "$LOG" 1100)" \
  "before the deadline the stage is armed on that deadline"
assert_equals "$(printf 'repost\td1\t1140')" "$(engine decide "$LOG" 1140)" \
  "at the deadline the request stage reposts, bound to the deadline"
put_event fire d1 request ', "epoch":1150, "outcome":"confirmed", "at":1150'
put_event timer d1 recovery ', "anchor":1200, "grace":120, "seen":true, "at":1200'
assert_equals "$(printf 'arm\td1\trecovery\t1320')" "$(engine decide "$LOG" 1300)" \
  "the recovery stage arms on its own turn and grace"
assert_equals "$(printf 'escalate\td1\tmissed\t1320')" "$(engine decide "$LOG" 1320)" \
  "at the recovery deadline the missed-report escalation fires"

# A repost that could not be delivered escalates at once, with no timeout.
: > "$LOG"
put_event waiter d2 - ', "task":"mate", "grace":120, "at":1000, "state":"confirmed", "delivered":1010'
put_event timer d2 request ', "anchor":1020, "grace":120, "seen":true, "at":1020'
put_event fire d2 request ', "epoch":1140, "outcome":"failed", "at":1140'
assert_equals "$(printf 'escalate\td2\trecovery-delivery\t-')" "$(engine decide "$LOG" 1140)" \
  "a failed repost escalates as a delivery failure, not as a timeout"

# A delivery attempt that outlived its grace is unknown, and unknown escalates.
: > "$LOG"
put_event waiter d3 - ', "task":"mate", "grace":120, "at":1000, "state":"attempted", "attempted":1000'
assert_equals "" "$(engine decide "$LOG" 1100)" "an attempt still inside its grace decides nothing"
assert_equals "$(printf 'delivery-unknown\td3\t1120')" "$(engine decide "$LOG" 1120)" \
  "an attempt past its grace is an unknown delivery"

# A settled waiter is terminal whatever its timers said.
: > "$LOG"
put_event waiter d4 - ', "task":"mate", "grace":120, "at":1000, "state":"confirmed", "delivered":1010'
put_event answer d4 - ', "epoch":1030, "via":"document", "at":1030'
assert_equals "$(printf 'answer\td4\t1030\tdocument')" "$(engine decide "$LOG" 5000)" \
  "the reply is the definition's terminal answer, not a timeout"

# --- the shadow tick acts on nothing ---------------------------------------
: > "$LOG"
put_event waiter t1 - ', "task":"mate", "grace":120, "at":1000, "state":"confirmed", "delivered":1010'
put_event timer t1 request ', "anchor":1020, "grace":120, "seen":true, "at":1020'
NOW=1140 engine tick >/dev/null
assert_contains "$(cat "$STATE_DIR/reply-bus-decisions.jsonl")" "$(printf '1140\trepost\tt1\t1140')" \
  "the shadow tick records the decision it would take"
assert_absent "$STATE_DIR/t1.status" "the shadow tick writes no status line"
assert_absent "$STATE_DIR/reply-state.tsv" "the shadow tick writes no cache block"
for entry in "$STATE_DIR"/*; do
  case "${entry##*/}" in
    reply-bus-decisions.jsonl) ;;
    *) fail "the shadow tick wrote something it does not own: $entry" ;;
  esac
done

# --- the replay -------------------------------------------------------------
: > "$LOG"
put_event waiter r1 - ', "task":"mate", "grace":120, "at":1000, "state":"confirmed", "delivered":1010'
put_event timer r1 request ', "anchor":1020, "grace":120, "seen":true, "at":1020'
put_event fire r1 request ', "epoch":1160, "outcome":"confirmed", "at":1160'
put_event timer r1 recovery ', "anchor":1200, "grace":120, "seen":true, "at":1200'
put_event fire r1 recovery ', "epoch":1330, "reason":"missed", "at":1330'
put_event waiter r2 - ', "task":"mate", "grace":120, "at":1000, "state":"confirmed", "delivered":1010'
put_event timer r2 request ', "anchor":1020, "grace":120, "seen":true, "at":1020'
put_event fire r2 request ', "epoch":1140, "outcome":"failed", "at":1140'
put_event waiter r3 - ', "task":"mate", "grace":120, "at":1000, "state":"confirmed", "delivered":1010'
put_event timer r3 request ', "anchor":1020, "grace":120, "seen":true, "at":1020'
put_event answer r3 - ', "epoch":1100, "via":"status", "at":1100'

out=$(engine replay "$LOG")
assert_contains "$out" "waiters=3" "the replay folds every waiter in the log"
assert_contains "$out" "differences=0" "a faithful recording replays with zero differences"
assert_contains "$out" "decisions_compared=8" "the replay compares every decision, not just the last"
bad=$(engine replay "$LOG" --corrupt)
assert_contains "$bad" "differences=" "the replay reports its differences"
assert_not_contains "$bad" "differences=0" "moving the replayed grace must change the decisions"
