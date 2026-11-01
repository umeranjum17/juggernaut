#!/usr/bin/env bash
# A home comes up with JetStream actually running (docs/bus-service.md): the one
# command a bootstrap step runs starts the pinned server, creates the stream from
# its file, and says so in one line - and a second run changes nothing.
#
# The test uses its own throwaway home, its own port and its own store, so it
# never touches this machine's real bus or a real home. It gate-skips when the
# server or the client is missing; the CI bus lane installs both, so there the
# test runs for real instead of skipping.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NATS_SERVER=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
NATS_BIN=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
if [ -z "$NATS_SERVER" ]; then
  echo "skip: nats-server not found (set JG_NATS_SERVER)"
  exit 0
fi
if [ -z "$NATS_BIN" ]; then
  echo "skip: nats client not found (set JG_NATS_BIN)"
  exit 0
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOME_DIR=$(jg_test_tmproot jg-bus-service)
STATE_DIR="$HOME_DIR/state"
BUS="$ROOT/bin/jg-bus.sh"

# free_port: an unused local port, so a real bus on the default port never
# collides with this fixture and two runs never collide with each other.
free_port() {
  local p
  for p in $(seq 45800 45899); do
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && continue
    printf '%s\n' "$p"
    return 0
  done
  return 1
}

# A pinned binary may arrive by path, and bin/jg-bus.sh resolves both tools on
# PATH, so the fixture's own bin directory names them and goes first.
BIN_DIR="$HOME_DIR/bin"
mkdir -p "$BIN_DIR" "$STATE_DIR" "$HOME_DIR/config/bus"
ln -sf "$NATS_SERVER" "$BIN_DIR/nats-server"
ln -sf "$NATS_BIN" "$BIN_DIR/nats"
PATH="$BIN_DIR:$PATH"
export PATH

PORT=$(free_port) || { echo "skip: no free local port for the fixture"; exit 0; }

bus() { JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" "$BUS" "$@"; }
client() { nats -s "nats://127.0.0.1:$PORT" "$@"; }

# stop_fixture: stop only the server this test started, through the bus command
# that owns it, and never by name or pattern.
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
stop_fixture() {
  bus stop >/dev/null 2>&1 || true
}
trap stop_fixture EXIT

# The home owns both files the server reads: its own port and store, so the test
# proves the override path a real home uses.
printf 'set nats-url nats://127.0.0.1:%s\n' "$PORT" > "$HOME_DIR/config/captain-channel"
cat > "$HOME_DIR/config/bus/nats.conf" <<EOF
host: "127.0.0.1"
port: $PORT
server_name: jg-bus-service-test

jetstream {
  store_dir: "./jetstream"
  max_mem_store: 64Mb
  max_file_store: 64Mb
}
EOF

test_ensure_brings_the_bus_up() {
  local out name
  name=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/core/bus/stream.json" | head -1)
  out=$(bus ensure 2>&1)
  assert_contains "$out" "bus: up nats://127.0.0.1:$PORT stream $name" \
    "ensure must report the server address and the stream it made present"
  assert_equals "$name" "$(client stream info "$name" --json | jq -r '.config.name')" \
    "the stream the home runs must be the one core/bus/stream.json names"
  assert_equals "jg.captain.>" "$(client stream info "$name" --json | jq -r '.config.subjects[0]')" \
    "the stream must carry the subjects its file names"
  pass "ensure starts the server and makes the stream present"
}

test_ensure_is_idempotent() {
  local before after out
  before=$(client stream info CAPTAIN --json | jq -r '.created')
  out=$(bus ensure 2>&1)
  after=$(client stream info CAPTAIN --json | jq -r '.created')
  assert_contains "$out" "bus: up" "a second run must still report the bus up"
  assert_equals "$before" "$after" "a second run must not recreate the stream"
  pass "a second ensure changes nothing"
}

test_the_stream_holds_a_published_event() {
  client pub --jetstream -H 'Nats-Msg-Id:bus-service-test' jg.captain.card '{"kind":"card"}' >/dev/null 2>&1 \
    || fail "the home's bus refused a published event"
  assert_equals 1 "$(client stream info CAPTAIN --json | jq -r '.state.messages')" \
    "the stream must keep the event it accepted"
  pass "the stream stores what a producer publishes"
}

test_stop_takes_only_the_server_down() {
  local out
  bus stop >/dev/null 2>&1
  out=$(bus ensure 2>&1)
  assert_contains "$out" "bus: up" "a home must come back up after its server stopped"
  pass "the bus comes up again after a stop"
}

result=0
test_ensure_brings_the_bus_up || result=1
test_ensure_is_idempotent || result=1
test_the_stream_holds_a_published_event || result=1
test_stop_takes_only_the_server_down || result=1
exit "$result"
