#!/usr/bin/env bash
# jg-wake-bus-probe.sh - measure, on this machine, that the wake queue and the task
# inboxes run on the bus: one real wake and one real steer go through the same
# producers the fleet uses, and the stream counts are printed before and after.
#
# WHY THIS EXISTS. "Are we running the event architecture?" is a measurement. A
# switch that is configured on can still leave every raise in the home's outbox, which
# looks like a queue while the bus holds nothing. This prints what the server holds.
#
# Usage: jg-wake-bus-probe.sh
#
# CONTRACT.
#   before/after  JG_WAKE and JG_INBOX: message count, last sequence and consumer
#                 count, read from the server this home's wake bus names.
#   real events   one wake raised and withdrawn through jg_wake_append and
#                 jg_wake_withdraw, and one steer written and moved to handled/ the
#                 way a worker does, through jg_task_inbox_write and inbox-settle.
#   absence       state/.wake-queue.seq (the file queue's sequence file) keeps its
#                 mtime, and no queue lock appears.
#   processes     the server and the Go parts that run here, from ps.
#   exit          0 when both streams rose by a raise and an acknowledgement each, the
#                 home's outbox did not grow, and nothing wrote the file queue's
#                 sequence file; 1 otherwise, with the failed check named.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-task-inbox-lib.sh
. "$SCRIPT_DIR/jg-task-inbox-lib.sh"

HOME_DIR=${JG_HOME:-$JG_ROOT}
WB="$SCRIPT_DIR/jg-wake-bus.sh"
URL=${JG_WAKE_BUS_URL:-$(awk '$1 == "nats-url" { print $2; exit }' "$HOME_DIR/config/wake-bus" 2>/dev/null)}
URL=${URL:-nats://127.0.0.1:4222}
NATS=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
[ -n "$NATS" ] || { echo "probe: nats client not found (set JG_NATS_BIN)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "probe: jq not found" >&2; exit 2; }
TASK=jg-bus-probe

# stream_line <stream>: "<messages> <last-sequence> <consumers>".
stream_line() {
  "$NATS" -s "$URL" --timeout 10s stream info "$1" --json 2>/dev/null \
    | jq -r '[.state.messages, .state.last_seq, .state.consumer_count] | join(" ")' 2>/dev/null
}

outbox_rows() { [ -f "$STATE/.wake-bus.outbox.jsonl" ] || { echo 0; return; }; awk 'END { print NR + 0 }' "$STATE/.wake-bus.outbox.jsonl"; }

seq_mtime() { stat -c %Y "$STATE/.wake-queue.seq" 2>/dev/null || echo none; }

snapshot() { # <label>
  local w i
  w=$(stream_line JG_WAKE) i=$(stream_line JG_INBOX)
  [ -n "$w" ] && [ -n "$i" ] || { echo "probe: no JG_WAKE/JG_INBOX at $URL" >&2; exit 1; }
  # shellcheck disable=SC2086 # $w and $i are three words each, on purpose
  printf '%s\tJG_WAKE msgs=%s last_seq=%s consumers=%s\tJG_INBOX msgs=%s last_seq=%s consumers=%s\toutbox_rows=%s\n' \
    "$1" $w $i "$(outbox_rows)"
}

echo "== processes"
ps -eo pid=,comm=,args= | awk '$2 ~ /^(nats-server|jg-bus|jg-wake-engine|jg-router|ntfy|daprd)$/' \
  | cut -c1-150 || true
echo "== server $URL, home $HOME_DIR"
before=$(snapshot before); echo "$before"
seq_before=$(seq_mtime); out_before=$(outbox_rows)
read -r w0 i0 < <(printf '%s\n' "$before" | sed -n 's/.*JG_WAKE msgs=\([0-9]*\).*JG_INBOX msgs=\([0-9]*\).*/\1 \2/p')

jg_wake_append check "$TASK" "check: bus probe" || { echo "probe: the wake raise failed" >&2; exit 1; }
rec=$(jg_task_inbox_write "$STATE" "$TASK" "bus probe steer") || { echo "probe: the steer write failed" >&2; exit 1; }
snapshot mid-event
jg_wake_withdraw check "$TASK" || true
mv -f -- "$rec" "$STATE/$TASK.inbox/handled/" || true
"$WB" inbox-settle >/dev/null 2>&1 || true

after=$(snapshot after); echo "$after"
read -r w1 i1 < <(printf '%s\n' "$after" | sed -n 's/.*JG_WAKE msgs=\([0-9]*\).*JG_INBOX msgs=\([0-9]*\).*/\1 \2/p')
echo "== file queue writes: .wake-queue.seq mtime $seq_before -> $(seq_mtime)"
echo "== rise: JG_WAKE +$((w1 - w0)) JG_INBOX +$((i1 - i0)) outbox $out_before -> $(outbox_rows)"

rc=0
[ $((w1 - w0)) -ge 2 ] || { echo "FAIL: JG_WAKE did not rise by a raise and an acknowledgement"; rc=1; }
[ $((i1 - i0)) -ge 2 ] || { echo "FAIL: JG_INBOX did not rise by a raise and an acknowledgement"; rc=1; }
[ "$(outbox_rows)" -le "$out_before" ] || { echo "FAIL: the outbox grew, so the bus refused an event"; rc=1; }
[ "$seq_before" = "$(seq_mtime)" ] || { echo "FAIL: something wrote the file queue's sequence file"; rc=1; }
[ "$rc" -ne 0 ] || echo "PASS: the wake queue and the inbox run on the bus"
exit "$rc"
