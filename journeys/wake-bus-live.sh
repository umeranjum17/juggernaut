#!/usr/bin/env bash
# done-done journey: the wake queue and the task inboxes run on the bus. A throwaway
# JetStream server and two throwaway homes; the real producers raise a wake and write a
# steer in each home, and bin/jg-wake-bus-probe.sh must show JG_WAKE and JG_INBOX rising
# in the server for both homes, an empty outbox and no write to the file queue. The
# live-machine run is the same probe against the real server: JG_HOME=<home> bin/jg-wake-bus-probe.sh.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-wake-bus-live}.log
T=$(mktemp -d)
trap 'kill "${srv:-0}" 2>/dev/null; rm -rf -- "$T"' EXIT
if ! command -v nats-server >/dev/null 2>&1 || ! command -v nats >/dev/null 2>&1; then
  echo "skip: nats-server or nats not installed" | tee "$LOG"
  exit 0
fi
mkdir -p "$T/store"
printf 'now * * * *\n' > "$T/routing"
nats-server -js -a 127.0.0.1 -p -1 -sd "$T/store" > "$T/nats.log" 2>&1 & srv=$!
port=
for _ in $(seq 200); do
  port=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$T/nats.log" | head -n 1)
  [ -n "$port" ] && break
  sleep 0.05
done
[ -n "$port" ] || { echo "the throwaway server never listened" | tee "$LOG"; exit 1; }
rc=0
{
  for h in first second; do
    mkdir -p "$T/$h/state" "$T/$h/config"
    echo "== home $h"
    JG_HOME=$T/$h JG_STATE_OVERRIDE=$T/$h/state JG_WAKE_BUS_URL=nats://127.0.0.1:$port JG_WAKE_ROUTING=$T/routing \
      bash "$REPO/bin/jg-wake-bus-probe.sh" || rc=1
  done
  echo "== streams"
  nats -s "nats://127.0.0.1:$port" stream ls -n
  echo "journey rc=$rc"
} > "$LOG" 2>&1
cat "$LOG"
exit "$rc"
