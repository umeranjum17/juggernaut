#!/usr/bin/env bash
# done-done journey: a wake bus render killed part-way through reading the bus loses
# and repeats no wake. A throwaway JetStream server and home; the real bin/jg-wake-bus.sh
# raises a wake while a client shim parks the render, the render is killed (kill -9 on its
# own process group), then restarted. The transcript prints the queue after each step:
# the killed wake must appear exactly once, an earlier wake still once, and an ordinary
# run once each, and a wake raised after the server made the stream again once too.
# Last, a cursor far past both stream ends (JG_WAKE 6347, JG_INBOX 1630, as a home whose
# streams were remade holds) reads both streams again from the start: every wake stays
# once, steers this home never read come back, a waiting steer stays and a handled one
# settles. Fails on any count other than the one printed as expected.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-wake-cursor-kill}.log
T=$(mktemp -d)
trap 'kill "${srv:-0}" 2>/dev/null; rm -rf -- "$T"' EXIT
NATS=$(command -v nats 2>/dev/null || true)
command -v nats-server >/dev/null 2>&1 && [ -n "$NATS" ] || { echo "skip: nats-server or nats not installed" | tee "$LOG"; exit 0; }
mkdir -p "$T/store" "$T/home/state" "$T/home/config"
printf 'now * * * *\n' > "$T/home/config/wake-routing"
nats-server -js -a 127.0.0.1 -p -1 -sd "$T/store" > "$T/nats.log" 2>&1 & srv=$!
port=
for _ in $(seq 200); do
  port=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$T/nats.log" | head -n 1)
  [ -n "$port" ] && break; sleep 0.05
done
[ -n "$port" ] || { echo "the throwaway server never listened" | tee "$LOG"; exit 1; }
export JG_HOME=$T/home JG_STATE_OVERRIDE=$T/home/state JG_WAKE_BUS_URL=nats://127.0.0.1:$port JG_WAKE_ROUTING=$T/home/config/wake-routing JG_NATS_BIN=$NATS
BUS=$REPO/bin/jg-wake-bus.sh
Q=$T/home/state/.wake-queue
rc=0
once() { # <word>
  n=$(grep -c "check: $1" "$Q" 2>/dev/null); echo "  wake '$1' delivered $n time(s)"
  [ "$n" = 1 ] || { echo "  FAIL: expected exactly 1"; rc=1; }
}
steers() { # <task> <expected>: unsettled inbox records of this task in the replica
  n=$(jq -c --arg t "$1" 'select(.task == $t)' "$T/home/state/.wake-bus.events.jsonl" | awk 'END { print NR + 0 }')
  echo "  steers for '$1' waiting on the bus: $n (expected $2)"
  [ "$n" = "$2" ] || { echo "  FAIL: expected $2"; rc=1; }
}
# shellcheck source=bin/jg-task-inbox-lib.sh
. "$REPO/bin/jg-task-inbox-lib.sh"
cat > "$T/shim" <<SHIM
#!/usr/bin/env bash
if [ -s "$T/arm" ] && case " \$* " in *" stream info JG_INBOX "*) true;; *) false;; esac; then
  n=\$(( \$(cat "$T/count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/count"
  if [ "\$n" = 2 ]; then : > "$T/reached"; exec sleep 60; fi
fi
exec "$NATS" "\$@"
SHIM
chmod +x "$T/shim"
{
  echo "== ordinary wake"
  "$BUS" raise check before "check: before" now; once before
  echo "== raise a wake, kill its render after it read the wake stream"
  echo 1 > "$T/arm"; rm -f "$T/count" "$T/reached"
  JG_NATS_BIN=$T/shim setsid "$BUS" raise check killed "check: killed" now >/dev/null 2>&1 & pid=$!
  for _ in $(seq 200); do [ -e "$T/reached" ] && break; sleep 0.05; done
  if [ -e "$T/reached" ]; then echo "  render parked mid-read; killing it (kill -9)"; else echo "  FAIL: render never parked"; rc=1; fi
  kill -9 -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$T/arm"
  echo "  cursor after the kill: $(cat "$T/home/state/.wake-bus.cursor" 2>/dev/null | tr '\t\n' ' ')"
  echo "== restart the reader"
  "$BUS" render; once before; once killed
  echo "== render again, then raise one more wake"
  "$BUS" render; once killed
  "$BUS" raise check after "check: after" now; once before; once killed; once after
  echo "== ordinary run of three wakes"
  for w in ord1 ord2 ord3; do "$BUS" raise check "$w" "check: $w" now; done
  "$BUS" render; once ord1; once ord2; once ord3
  echo "== the server makes the wake stream again, then one more wake"
  "$NATS" -s "$JG_WAKE_BUS_URL" stream rm -f JG_WAKE >/dev/null
  "$BUS" raise check remade "check: remade" now; once remade
  echo "  cursor on the remade stream: $(tr '\t\n' '  ' < "$T/home/state/.wake-bus.cursor")"
  echo "== two steers, a home that never read them, and a cursor past both stream ends"
  jg_task_inbox_write "$T/home/state" task-x "first steer" >/dev/null
  rec=$(jg_task_inbox_write "$T/home/state" task-y "second steer")
  jq -c 'select(.task == null)' "$T/home/state/.wake-bus.events.jsonl" > "$T/replica" && mv "$T/replica" "$T/home/state/.wake-bus.events.jsonl"
  printf 'JG_WAKE\t6347\nJG_INBOX\t1630\n' > "$T/home/state/.wake-bus.cursor"
  echo "  cursor before the render: $(tr '\t\n' '  ' < "$T/home/state/.wake-bus.cursor")"
  "$BUS" render; once before; once killed; once ord1; once remade; steers task-x 1; steers task-y 1
  echo "  cursor after the render: $(tr '\t\n' '  ' < "$T/home/state/.wake-bus.cursor")"
  "$BUS" inbox-settle; echo "  settle pass with both steers still waiting"; steers task-x 1; steers task-y 1
  mv "$rec" "$T/home/state/task-y.inbox/handled/"; "$BUS" inbox-settle
  echo "  settle pass after task-y's steer moved to handled"; steers task-x 1; steers task-y 0
  echo "journey rc=$rc"
} > "$LOG" 2>&1
cat > "$OUT/steps.json" <<JSON
{"target": {"version": "jg-wake-bus.sh at $(git -C "$REPO" rev-parse --short HEAD)"},
 "start": "a throwaway home and JetStream server with one wake already delivered",
 "steps": ["raise a wake whose render is parked after reading the wake stream", "kill that render with kill -9", "restart the reader with a render", "render again and raise one more wake", "raise three wakes in an ordinary run and render", "remove and remake the wake stream on the server, then raise one more wake", "write two steers, drop them from the replica and set the cursor to JG_WAKE 6347 and JG_INBOX 1630, then render", "run a settle pass, move one steer to handled and run another"],
 "result": "every wake, including the one whose render was killed and the one raised on the remade stream, appears in the queue exactly once: no gap and no repeat; a cursor past both stream ends reads both again from the start, the steers come back, a waiting steer stays and a handled one settles (journey rc=$rc)"}
JSON
cat "$LOG"
exit "$rc"
