#!/usr/bin/env bash
# The wake engine and the reply router, the two Go consumers the stack installs as services
# (core/bus/cmd/jg-bus/engine.go): a real wake raised through bin/jg-wake-bus.sh reaches the
# engine's durable consumer and its handled counter rises, a wake raised while the engine was
# down is handled when it returns and the counter continues, and a captain reply published on
# the bus reaches the router, which routes it by the board's own rule.
#
# The test starts a throwaway server on a free port with its own store and runs both consumers
# as plain processes, so it never touches this machine's real bus or a real home. It gate-skips
# when the server, the client or a Go toolchain is missing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v go >/dev/null 2>&1 || [ -n "${JG_BUS_BIN:-}" ] || { echo "skip: no Go toolchain to build the bus command"; exit 0; }
DIR=$(jg_test_tmproot jg-wake-engine)
SERVER=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
JG_NATS_BIN=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
[ -n "$SERVER" ] && [ -n "$JG_NATS_BIN" ] || { echo "skip: nats-server and the nats client are needed"; exit 0; }
export JG_NATS_BIN

# The server is the one the stack's unit runs: this machine's accounts file included, so the
# home logs in as its own account and an anonymous client is refused.
HOME_DIR="$DIR/home"
mkdir -p "$HOME_DIR/state/bus" "$HOME_DIR/config/bus" "$HOME_DIR/data"
port=$(( 47100 + RANDOM % 800 ))
sed "s/4222/$port/" "$ROOT/core/bus/nats.conf" > "$HOME_DIR/config/bus/nats.conf"
printf 'set nats-url nats://127.0.0.1:%s\n' "$port" > "$HOME_DIR/config/captain-channel"
printf 'now * * * *\n' > "$HOME_DIR/config/wake-routing"
# tests/lib.sh points every bus client at a dead address so a test never reaches the machine bus; this
# test runs its own lab server, so it names that one for the wake bus.
# A failing event is tried again after a short delay; the lab shortens the 5s default.
export JG_BUS_RETRY_DELAY=2s
export JG_WAKE_BUS_URL="nats://127.0.0.1:$port"
export JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" JG_WAKE_ROUTING="$HOME_DIR/config/wake-routing"
# `unit nats` is not used here: it resolves the machine unit's owner and, from any other home, registers
# itself with that owner. The accounts file and the config that includes it are written for this lab home only.
"$ROOT/bin/jg-bus.sh" accounts "$HOME_DIR" > "$HOME_DIR/state/bus/accounts.conf" 2>"$DIR/accounts.err" || fail "the accounts file was not generated: $(cat "$DIR/accounts.err")"
printf 'include "../../config/bus/nats.conf"\ninclude "accounts.conf"\n' > "$HOME_DIR/state/bus/bus.conf"
( cd "$HOME_DIR/state/bus" && exec "$SERVER" -c bus.conf > "$DIR/nats.log" 2>&1 ) &
printf '%s\n' "$!" >> "$JG_TEST_BUS_REGISTRY"
for _ in $(seq 1 200); do grep -q 'Server is ready' "$DIR/nats.log" 2>/dev/null && break; sleep 0.05; done
grep -q 'Server is ready' "$DIR/nats.log" || { echo "skip: the throwaway server never became ready"; exit 0; }
if "$JG_NATS_BIN" -s "nats://127.0.0.1:$port" stream ls >/dev/null 2>&1; then fail "an anonymous client was accepted: this test must run on the accounts server"; fi
BUS="$ROOT/bin/jg-bus.sh"
WAKE="$ROOT/bin/jg-wake-bus.sh"
ENGINE_PID='' ROUTER_PID=''
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  [ -z "$ENGINE_PID" ] || kill "$ENGINE_PID" 2>/dev/null || true
  [ -z "$ROUTER_PID" ] || kill "$ROUTER_PID" 2>/dev/null || true
  jg_test_cleanup
}
trap cleanup EXIT

# field <part> <name>: one value out of the probe line.
field() { "$BUS" probe "$1" 2>/dev/null | tr ' ' '\n' | sed -n "s/^$2=//p"; }
# wait_field <part> <name> <want>: the probe line reaches the value; bounded, no fixed sleep.
wait_field() {
  for _ in $(seq 1 400); do
    [ "$(field "$1" "$2")" = "$3" ] && return 0
    sleep 0.05
  done
  return 1
}
# wait_ready <part>: the part's consumer exists on the server (the probe exits 0); bounded, no fixed sleep.
wait_ready() {
  for _ in $(seq 1 400); do
    "$BUS" probe "$1" >/dev/null 2>&1 && return 0
    sleep 0.05
  done
  return 1
}
start_engine() { "$BUS" wake-engine >> "$DIR/engine.log" 2>&1 & ENGINE_PID=$!; }

# The account's JetStream can lag the server's ready line, so creating the stream is retried (bounded).
for _ in $(seq 1 40); do "$BUS" bootstrap >/dev/null 2>&1; "$BUS" stream >/dev/null 2>&1 && break; sleep 0.25; done
"$BUS" stream || fail "the captain stream was not created"
start_engine
"$BUS" router >> "$DIR/router.log" 2>&1 & ROUTER_PID=$!
wait_ready wake-engine || fail "the wake engine never created its consumer: $(cat "$DIR/engine.log") server: $(tail -n 3 "$DIR/nats.log")"
wait_ready router || fail "the router never created its consumer: $(cat "$DIR/router.log")"
pass "both consumers are running and have a durable consumer on the server"

before=$("$BUS" probe wake-engine)
[ "$(field wake-engine handled)" = 0 ] || fail "the handled counter does not start at 0: $before"
"$WAKE" raise check startup "check: probe one" now || fail "the raise did not publish"
wait_field wake-engine handled 1 || fail "a real wake was not handled by the engine: $("$BUS" probe wake-engine) $(cat "$DIR/engine.log")"
after=$("$BUS" probe wake-engine)
[ "$(field wake-engine delivered)" = 1 ] && [ "$(field wake-engine pending)" = 0 ] || fail "the consumer counts did not move: $after"
grep -q 'probe one' "$HOME_DIR/state/.wake-queue" || fail "the read model does not hold the wake"
pass "a raised wake is handled: $before -> $after"

# The engine is a service that can stop: a wake raised while it is down waits on the server and is
# handled when it returns, and the counter continues from where it was.
kill "$ENGINE_PID"; wait "$ENGINE_PID" 2>/dev/null
"$WAKE" raise check startup "check: probe two" now || fail "the raise while the engine was down did not publish"
start_engine
wait_ready wake-engine || fail "the restarted engine never found its consumer"
wait_field wake-engine handled 2 || fail "the wake raised while down was not handled after the restart: $("$BUS" probe wake-engine) $(cat "$DIR/engine.log")"
[ "$(field wake-engine failed)" = 0 ] || fail "a handle failed: $(cat "$DIR/engine.log")"
pass "a restart continues the counter and handles what arrived while down"

# The router consumes a captain reply and routes it by the board's own rule: a card with no route
# stays with Main, which the router reports and counts as not routed.
[ "$(field router handled)" = 0 ] || fail "the router counter does not start at 0"
acct=$("$BUS" account); NATS_USER=${acct%%$'\t'*} NATS_PASSWORD=$(cat "${acct#*$'\t'}") \
  "$JG_NATS_BIN" -s "nats://127.0.0.1:$port" pub --jetstream -q jg.captain.reply \
  '{"key":"not-routed","at":"2026-11-01T00:00:00Z","answer":"yes"}' >/dev/null 2>&1 || fail "the reply did not publish"
wait_field router delivered 1 || fail "the router never received the reply: $("$BUS" probe router) $(cat "$DIR/router.log")"
# Ack after handling: while the handler's failure is still being retried the server has not been told
# the event is done, so the ack floor stays at 0 and the event is not counted failed or handled.
wait_field router retried 1 || fail "the failed handle was not sent back for another try: $("$BUS" probe router) $(cat "$DIR/router.log")"
[ "$(field router acked)" = 0 ] && [ "$(field router failed)" = 0 ] && [ "$(field router handled)" = 0 ] \
  || fail "the event was acknowledged before its handler succeeded: $("$BUS" probe router)"
pass "a failing handle leaves the event unacknowledged and is retried: $("$BUS" probe router)"
# After its last try the event is on the dead list with the cause, and only then is it closed.
wait_field router failed 1 || fail "the unrouted reply was not counted: $("$BUS" probe router) $(cat "$DIR/router.log")"
[ "$(field router retried)" = 2 ] && [ "$(field router acked)" = 1 ] || fail "the tries or the close are wrong: $("$BUS" probe router)"
grep -q 'not routed to a lead' "$DIR/router.log" || fail "the router did not report the refusal: $(cat "$DIR/router.log")"
dead=$(find "$HOME_DIR/state" -name 'router.dead.jsonl' | head -1)
if [ -z "$dead" ] || [ "$(wc -l < "$dead")" != 1 ] || ! grep -q 'not-routed' "$dead" || ! grep -q '"tries":3' "$dead"; then
  fail "the dead list does not hold the failed reply once: ${dead:-none} $(cat "${dead:-/dev/null}" 2>/dev/null)"
fi
pass "after its last try the reply is on the dead list and closed: $(cat "$dead")"
pass "a captain reply reaches the router and is routed by the board's rule: $("$BUS" probe router)"
