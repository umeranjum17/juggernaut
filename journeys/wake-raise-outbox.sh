#!/usr/bin/env bash
# done-done journey: a wake raise the wake engine cannot serve still queues, and the
# watcher keeps running. The incident this pins: bin/jg-watch.sh exited 1 at its own
# raise site while the wake store was being rebuilt under load, and the arm read five
# such exits in a row as a broken supervision cycle.
#
# Steps, all on the real commands in a throwaway home:
#   1. the wake engine cannot run at all (no binary, no toolchain): the production
#      producer in bin/jg-wake-lib.sh answers success and the raise is owed in
#      state/.wake-bus.outbox.jsonl with its kind, key, payload, home and identity;
#   2. the engine runs but refuses every raise (a corrupt row-number record, the
#      allocator's own refusal): the real bin/jg-watch.sh runs one cycle over a changed
#      status log and names the wake it raised, exits 0, and that raise is owed too.
#      Before this change the same cycle exits 1 at its raise site and raises nothing;
#   3. the engine and the store come back (a throwaway JetStream server, a real build):
#      the owed rows publish, the outbox empties, and the read model every other reader
#      opens holds the watcher's wake.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-wake-raise-outbox}.log
T=$(mktemp -d)
: > "$LOG"
trap 'kill "${srv:-0}" 2>/dev/null; rm -rf -- "$T"' EXIT
hm=$T/home
st=$hm/state
outbox=$st/.wake-bus.outbox.jsonl
fails=0
say() { printf '%s\n' "$1"; printf '%s\n' "$1" >> "$LOG"; }
bad() { say "FAIL: $1"; fails=$((fails + 1)); }
owed() { # <expected rows>: the outbox row count
  n=$(awk 'END { print NR + 0 }' "$outbox" 2>/dev/null)
  say "  outbox rows: ${n:-0} (expected $1)"
  [ "${n:-0}" = "$1" ] || bad "the outbox holds ${n:-0} rows, expected $1"
}

mkdir -p "$st" "$hm/config" "$hm/data"
printf 'now * * * *\n' > "$hm/config/wake-routing"
export JG_HOME=$hm JG_STATE_OVERRIDE=$st JG_DATA_OVERRIDE=$hm/data \
  JG_ROOT_OVERRIDE=$REPO JG_WAKE_ROUTING=$hm/config/wake-routing
# The wake engine cannot run: bin/jg-bus.sh owns that verdict, and it is exactly what a
# checkout mid-rebuild hands a producer - no runnable binary and no way to build one.
export JG_BUS_BIN=$T/no-such-jg-bus JG_BUS_GO=/bin/false
unset JG_WAKE_BUS_URL JG_NATS_BIN

say "== 1. the producer queues a raise the engine cannot serve"
( . "$REPO/bin/jg-wake-lib.sh"
  jg_wake_append signal alpha-one.status 'signal: alpha-one blocked on the store' ) 2> "$T/raise.err"
raise_rc=$?
say "  jg_wake_append rc=$raise_rc"
[ "$raise_rc" -eq 0 ] || bad "a raise the engine cannot serve still failed the producer"
sed -n '1,2p' "$T/raise.err" | sed 's/^/  stderr: /'
owed 1
jq -c '{kind,key,payload,home,where,subject}' "$outbox" 2>/dev/null | sed 's/^/  row: /'
jq -e 'select(.kind == "signal" and .key == "alpha-one.status" and .where == "queue"
        and (.payload | startswith("signal: alpha-one blocked")) and (.id | test("^wake/"))
        and (.rseq > 0) and (.subject | endswith(".wake.raise")))' "$outbox" > /dev/null 2>&1 \
  || bad "the owed row is not a queue row for this event"

say "== 2. the watcher keeps running while every raise is refused"
mkdir -p "$st/bus" "$T/fakebin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/fakebin/tmux"; chmod +x "$T/fakebin/tmux"
unset JG_BUS_BIN JG_BUS_GO
( cd "$REPO/core/bus" && go build -o "$T/jg-bus" ./cmd/jg-bus ) || bad "the bus command did not build"
export JG_BUS_BIN=$T/jg-bus
printf 'not-a-number\n' > "$st/bus/wake-order"
printf 'blocked [at=%s]: the wake store is being rebuilt, waiting on it\n' "$(date +%s)" \
  > "$st/alpha-one.status"
PATH="$T/fakebin:$PATH" JG_POLL=0.2 JG_SIGNAL_GRACE=0 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 \
  "$REPO/bin/jg-watch.sh" > "$T/watch.out" 2> "$T/watch.err"
watch_rc=$?
say "  watcher exit=$watch_rc"
say "  watcher raised: $(head -n 1 "$T/watch.out")"
sed -n '1,2p' "$T/watch.err" | sed 's/^/  watcher stderr: /'
[ "$watch_rc" -eq 0 ] || bad "the watcher exited $watch_rc on a raise it could not publish"
grep -q 'alpha-one.status' "$T/watch.out" || bad "the cycle did not name the wake it raised"
grep -q 'cannot assign row sequence' "$T/watch.err" || bad "the refused raise did not keep the engine's cause"
n=$(jq -c 'select(.key == "alpha-one.status")' "$outbox" 2>/dev/null | awk 'END { print NR + 0 }')
say "  owed rows for alpha-one.status: $n (expected 2: the producer's and the watcher's)"
[ "$n" = 2 ] || bad "the watcher's own raise was not owed"

say "== 3. the owed rows publish and reach the read model once the store answers"
SERVER=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
CLIENT=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
if [ -z "$SERVER" ] || [ -z "$CLIENT" ]; then
  say "  skip: nats-server or the nats client is not installed, so publication stays unverified"
else
  mkdir -p "$T/store"
  "$SERVER" -js -a 127.0.0.1 -p -1 -sd "$T/store" > "$T/nats.log" 2>&1 & srv=$!
  port=
  for _ in $(seq 200); do
    port=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$T/nats.log" 2>/dev/null | head -n 1)
    [ -n "$port" ] && break
    sleep 0.05
  done
  if [ -z "$port" ]; then
    bad "the throwaway server never listened"
  else
    printf '1\n' > "$st/bus/wake-order"
    export JG_WAKE_BUS_URL=nats://127.0.0.1:$port JG_NATS_BIN=$CLIENT
    "$REPO/bin/jg-wake-bus.sh" render > "$T/render.log" 2>&1
    say "  render rc=$?"
    sed -n '1,3p' "$T/render.log" | sed 's/^/  render: /'
    owed 0
    say "  read model rows: $(awk 'END { print NR + 0 }' "$st/.wake-queue" 2>/dev/null)"
    say "  read model rows naming alpha-one.status: $(grep -c 'alpha-one.status' "$st/.wake-queue" 2>/dev/null)"
    [ "$(grep -c 'alpha-one.status' "$st/.wake-queue" 2>/dev/null)" = 2 ] \
      || bad "the published rows are not both in the read model"
    "$CLIENT" -s "nats://127.0.0.1:$port" --timeout 5s stream info JG_WAKE 2>/dev/null \
      | sed -n 's/^ *\(State:\|Messages:\).*/  stream \1/p' | sort -u | head -3
  fi
fi
say "journey failures=$fails"
exit "$([ "$fails" -eq 0 ] && echo 0 || echo 1)"
