#!/usr/bin/env bash
# One server, one account per home: home B must not read home A. The accounts come
# from the Go bus command, which is the only owner of that file.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRV=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
CLI=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
[ -n "$SRV" ] || { echo "skip: nats-server not found"; exit 0; }
[ -n "$CLI" ] || { echo "skip: nats client not found"; exit 0; }
D=$(jg_test_tmproot jg-bus-isolation); A="$D/homeA"; B="$D/homeB"
mkdir -p "$A/state" "$B/state" "$D/store"
# The bus command is Go; without a toolchain there is nothing to prove here.
if [ -z "${JG_BUS_GO:-}" ]; then
  JG_BUS_GO=$(command -v go 2>/dev/null || true)
  [ -n "$JG_BUS_GO" ] || { echo "skip: no Go toolchain (set JG_BUS_GO)"; exit 0; }
fi
export JG_BUS_GO
JG_HOME="$A" JG_STATE_OVERRIDE="$A/state" timeout 240 bash "$ROOT/bin/jg-bus.sh" accounts "$A" "$B" > "$D/accounts.conf" 2>/dev/null \
  || fail "the bus command did not produce the accounts file"
grep -q 'system_account' "$D/accounts.conf" || fail "no system account"
# The permission rule: an account block must never carry a bare wildcard or a
# subject that is not the home's own prefix, which is what widening would look like.
if grep -Eq '^\s+(allow|exports|imports)' "$D/accounts.conf"; then fail "the accounts file exports or imports subjects"; fi
"$SRV" -js -a 127.0.0.1 -p -1 -sd "$D/store" -c "$D/accounts.conf" > "$D/nats.log" 2>&1 &
PID=$!
# shellcheck disable=SC2329
cleanup() { kill "$PID" 2>/dev/null || true; }
trap cleanup EXIT
port=
for _ in $(seq 200); do port=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$D/nats.log" | head -1); [ -n "$port" ] && break; sleep 0.05; done
[ -n "$port" ] || { cat "$D/nats.log"; fail "the server did not listen"; }
url="nats://127.0.0.1:$port"; ra=$(basename "$A"); rb=$(basename "$B")
pa="$A/state/bus/$ra.pass"; pb="$A/state/bus/$rb.pass"
[ -n "$pa" ] && [ -n "$pb" ] || fail "no credentials file per home"
timeout 20 "$CLI" -s "$url" --user "$ra" --password "$(cat "$pa")" pub "jg.$ra.wake.raise" hi >/dev/null 2>&1 \
  || fail "home A could not publish on its own prefix"
if timeout 10 "$CLI" -s "$url" --user "$rb" --password "$(cat "$pb")" sub "jg.$ra.wake.>" --count 1 --timeout 3s >/dev/null 2>&1; then
  fail "home B read home A's subjects"
fi
timeout 20 "$CLI" -s "$url" --user "$rb" --password "$(cat "$pb")" pub "jg.$rb.wake.raise" hi >/dev/null 2>&1 \
  || fail "home B could not publish on its own prefix"
pass "one server, one account per home: home B cannot read home A"
