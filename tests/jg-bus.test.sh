#!/usr/bin/env bash
# tests/jg-bus.test.sh - the captain channel, live, proved end to end.
#
# What it proves, in order: an event the fleet emits is recorded, published and
# delivered to the captain while the path that emitted it does what it always
# did; the shipped mode is live, and `mode shadow` is the one line that reverses
# it; ntfy delivery targets the local server while the relay switch is off, and
# only the relay when it is on; a live delivery that does not arrive is named in
# the undelivered record; the parity replay reports what is sent against every
# recorded event with zero differences, and its tampered run reports a difference
# so a green run is never vacuous; a reply event from the captain routes to the
# lead the board's own route sends board answers to; and no failure of this path
# can fail its emitter. Skipped when python3 is absent, because the delivery proof
# needs a local HTTP sink rather than a real ntfy, and skipped when the Go toolchain or
# the two bus binaries are absent, because the command is Go and the reply leg settles a
# task lease on a bus of its own.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v python3 >/dev/null 2>&1 || { printf 'skip: no python3; the local delivery sink needs it\n'; exit 0; }

# The command is Go now, per the stack decision that new long-running parts are Go, so
# this test builds the command at this head and runs the real dispatcher in front of
# it: every assertion below drives the Go binary, and no shell fallback can make it pass.
# A caller that already built the binary (CI does, once per lane) names it in JG_BUS_BIN
# and the build is skipped.
NATS_SERVER=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
NATS_BIN=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
[ -n "$NATS_SERVER" ] && [ -n "$NATS_BIN" ] || {
  printf 'skip: nats-server and nats are needed for the reply leg, which settles a task lease on the bus\n'
  exit 0
}

TMP_ROOT=$(jg_test_tmproot jg-bus)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
if [ -z "${JG_BUS_BIN:-}" ] || [ ! -x "${JG_BUS_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { printf 'skip: no go toolchain to build the bus command\n'; exit 0; }
  ( cd "$ROOT/core/bus" && go build -o "$TMP_ROOT/bin/jg-bus" ./cmd/jg-bus ) ||
    fail "the bus command did not build"
  JG_BUS_BIN=$TMP_ROOT/bin/jg-bus
fi
# The dispatcher must hand every command to that binary, so it is named for the run.
export JG_BUS_BIN
BUS="$ROOT/bin/jg-bus.sh"
CARD="$ROOT/bin/jg-question-card.sh"
OUTCOME="$ROOT/bin/jg-branch-outcome.sh"
SINK_OUT=$TMP_ROOT/requests.jsonl
SINK_PID=
BUS_PID=
cleanup_sink() {
  [ -z "$SINK_PID" ] || kill "$SINK_PID" 2>/dev/null
  [ -z "$BUS_PID" ] || kill "$BUS_PID" 2>/dev/null
}
trap cleanup_sink EXIT

# start_bus: the reply leg settles a task lease on the home's bus, so the test runs
# its own JetStream server on a free port and points the lease store at it, instead
# of assuming a bus this machine happens to have.
start_bus() {
  local store=$TMP_ROOT/bus-store log=$TMP_ROOT/bus.log port
  mkdir -p "$store"
  "$NATS_SERVER" -js -a 127.0.0.1 -p -1 -sd "$store" >"$log" 2>&1 &
  BUS_PID=$!
  for _ in $(seq 200); do
    port=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$log" 2>/dev/null | head -n 1)
    [ -n "$port" ] && break
    sleep 0.05
  done
  [ -n "${port:-}" ] || fail "the test bus never reported a listen port"
  export JG_KV_URL="nats://127.0.0.1:$port"
}
start_bus

# The sink stands in for the Dapr sidecar and for ntfy: it records the path,
# title and body of every POST so the test can see where each event went.
start_sink() {
  local portfile=$TMP_ROOT/port
  python3 - "$SINK_OUT" "$portfile" >/dev/null 2>&1 <<'PY' &
import http.server, json, sys
out, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length') or 0)
        body = self.rfile.read(n).decode('utf-8', 'replace')
        with open(out, 'a') as f:
            f.write(json.dumps({'path': self.path, 'title': self.headers.get('Title'), 'body': body}) + '\n')
        self.send_response(204)
        self.end_headers()
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
open(portfile, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
  SINK_PID=$!
  local _
  for _ in $(seq 100); do [ -s "$portfile" ] && { cat "$portfile"; return 0; }; sleep 0.1; done
  fail "the delivery sink never started"
}
PORT=$(start_sink)
[ -n "$PORT" ] || fail "no sink port"

# A home with the two captain-facing paths' fakes and one card route.
setup() {  # <name> -> echoes the case dir
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state" "$d/home/config" "$d/fakebin" "$d/so/.sign-off"
  printf '{"schema":2,"items":[]}\n' >"$d/so/.sign-off/decisions.json"
  printf '#!/usr/bin/env bash\nexit 0\n' | tee "$d/fakebin/tmux" >"$d/fakebin/sleep"
  cat >"$d/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1; shift
board=$SIGN_OFF_HOME/.sign-off/decisions.json
case "$cmd" in
  answers) jq -s 'reduce .[] as $a ({}; .[$a.key] = ($a | del(.key)))' "${board%.json}.answers.jsonl" ;;
  dismiss|status) exit 0 ;;
  list) jq -c '{decisions: [.items[] | {key}]}' "$board" ;;
  raise) jq '.items += [{key: "put-the-key-into-muxr"}]' "$board" > "$board.tmp" && mv "$board.tmp" "$board" ;;
esac
SH
  chmod +x "$d/fakebin/sign-off-axi" "$d/fakebin/tmux" "$d/fakebin/sleep"
  jg_write_squad_lead_meta "$d/home/state/muxr.meta" "$d/home" "sess:jg-muxr"
  printf 'needs-decision [key=put-the-key-into-muxr]: use the key?\n' >"$d/home/state/muxr.status"
  : >"$d/so/.sign-off/decisions.answers.jsonl"
  # The one home override: point both surfaces at the sink. The mode comes from
  # the shipped defaults, so nothing here turns delivery on.
  cat >"$d/home/config/captain-channel" <<EOF
set dapr-http-url http://127.0.0.1:$PORT
set ntfy-server http://127.0.0.1:$PORT
set ntfy-relay-server http://127.0.0.1:$PORT/relay
EOF
  : >"$SINK_OUT"
  printf '%s\n' "$d"
}

run() {  # <case-dir> <command...>
  local d=$1
  shift
  env PATH="$d/fakebin:$PATH" JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" SIGN_OFF_HOME="$d/so" \
    JG_SEND_SETTLE=0 "$@" 2>&1
}
run_quiet() { run "$@" 2>/dev/null; }
requests() { cat "$SINK_OUT" 2>/dev/null; }
events() { cat "$1/home/state/captain-channel.jsonl" 2>/dev/null; }

# --- the tee records and publishes, and the live path is untouched -------------
d=$(setup tee)
key=$(run_quiet "$d" "$CARD" post --title "Which key should the muxr use?" --option "Key it" --option "Rename it" --must money --record https://board.example/records/card-1 --ask-ref 'card[1]')
assert_equals "put-the-key-into-muxr" "$key" "post still prints the card key alone"
assert_equals "1" "$(events "$d" | wc -l | tr -d ' ')" "the card post is teed once"
assert_contains "$(events "$d")" '"kind":"card"' "the teed event names the card"
assert_contains "$(events "$d")" '"key":"put-the-key-into-muxr"' "the teed event carries the card key"
assert_contains "$(requests)" '/v1.0/publish/captain-channel/jg.captain.card' "the event reached the bus transport"
assert_contains "$(requests)" 'Which key should the muxr use?' "the bus event carries the captain's text"
assert_contains "$(requests)" '/juggernaut-captain' "ntfy delivered to the local topic"
assert_equals "1" "$(jq -s 'length' "$d/so/.sign-off/decisions.json")" "the board gained exactly the one card, as before"

# --- the shipped mode is live, so a home needs no delivery key at all ----------
d=$(setup live-default)
printf 'set dapr-http-url http://127.0.0.1:%s\nset ntfy-server http://127.0.0.1:%s\n' "$PORT" "$PORT" \
  >"$d/home/config/captain-channel"
: >"$SINK_OUT"
run_quiet "$d" "$BUS" publish card k-live "A decision waits for you."
assert_equals "live" "$(run_quiet "$d" "$BUS" config mode)" "the shipped mode is live"
assert_contains "$(requests)" '"path": "/juggernaut-captain"' "a live event reaches the captain with no delivery key set"
assert_equals "0" "$(cat "$d/home/state/captain-channel-undelivered.jsonl" 2>/dev/null | wc -l | tr -d ' ')" "nothing is undelivered when the delivery arrives"

# --- one line reverses it, and off still means nothing at all -----------------
d=$(setup reversed)
printf 'set mode shadow\nset dapr-http-url http://127.0.0.1:%s\nset ntfy-server http://127.0.0.1:%s\n' "$PORT" "$PORT" \
  >"$d/home/config/captain-channel"
: >"$SINK_OUT"
run_quiet "$d" "$BUS" publish card k-shadow "Recorded, not delivered."
assert_equals "1" "$(events "$d" | wc -l | tr -d ' ')" "the reversal still records the event"
assert_equals "0" "$(grep -c '"path": "/juggernaut-captain"' <<<"$(requests)" || true)" "the reversal delivers nothing"
assert_equals "0" "$(run_quiet "$d" "$BUS" parity | head -1 | sed -n 's/.* deliveries=\([0-9]*\).*/\1/p')" "shadow parity reports no delivery"
assert_equals "0" "$(run_quiet "$d" "$BUS" parity | head -1 | sed -n 's/.* differences=\([0-9]*\)/\1/p')" "the reversal changes nothing that is sent"

# --- a live delivery that does not arrive is named, never lost quietly -------
d=$(setup undelivered)
printf 'set dapr-http-url http://127.0.0.1:%s\nset ntfy-server http://127.0.0.1:1\n' "$PORT" \
  >"$d/home/config/captain-channel"
run_quiet "$d" "$BUS" publish card k-lost "This one does not arrive."
assert_equals "1" "$(wc -l <"$d/home/state/captain-channel-undelivered.jsonl" | tr -d ' ')" "a failed live delivery is recorded as undelivered"
assert_contains "$(run_quiet "$d" "$BUS" status)" "1 event(s), 1 undelivered" "status counts what did not arrive"

# --- parity replays what is sent against every recorded event ----------------
d=$(setup parity)
run_quiet "$d" "$BUS" publish card k-parity "A decision waits for you." >/dev/null
run_quiet "$d" "$BUS" publish outcome muxr "The key is fixed and released in 0.4.1" >/dev/null
line=$(run_quiet "$d" "$BUS" parity | head -1)
assert_contains "$line" "events=2 instants=" "parity replays both recorded events, at their recorded instants"
assert_contains "$line" "decisions=4 deliveries=2 differences=0" "parity finds zero differences between what is sent and what was recorded"
out=$(run "$d" "$BUS" parity --corrupt; printf 'exit=%s' "$?")
assert_contains "$out" "differences=4 (must be non-zero)" "a tampered replay reports a difference, so green is not vacuous"
assert_contains "$out" "exit=0" "the tampered run succeeds by reporting its difference"

# --- a captain outcome is teed, a routine one is not --------------------------
d=$(setup outcome)
run_quiet "$d" "$OUTCOME" append --task muxr --verdict routine --summary "no change" >/dev/null
assert_equals "0" "$(events "$d" | wc -l | tr -d ' ')" "a routine outcome is not captain-facing, so it is not teed"
run_quiet "$d" "$OUTCOME" append --task muxr --verdict captain --summary "The key is fixed and released in 0.4.1" >/dev/null
assert_equals "1" "$(events "$d" | wc -l | tr -d ' ')" "a captain outcome is teed once"
assert_contains "$(events "$d")" '"kind":"outcome"' "the teed event names the outcome"
assert_equals "2" "$(wc -l <"$d/home/state/branch-outcomes.jsonl" | tr -d ' ')" "the outcome store still holds both rows"

# --- the relay switch is off, and turning it on is the only way it is used ----
d=$(setup relay)
run_quiet "$d" "$BUS" publish card k1 "A decision waits."
assert_equals "http://127.0.0.1:$PORT/juggernaut-captain" "$(run_quiet "$d" "$BUS" config | awk '$1 == "ntfy-server" {print $2}')/juggernaut-captain" "relay off targets the local server"
assert_equals "0" "$(grep -c '"path": "/relay/' <<<"$(requests)" || true)" "relay off never touches the relay host"
printf 'set ntfy-relay on\n' >>"$d/home/config/captain-channel"
: >"$SINK_OUT"
run_quiet "$d" "$BUS" publish card k2 "A decision waits."
assert_contains "$(requests)" '"path": "/relay/juggernaut-captain"' "relay on is the only thing that sends through the relay"

# --- off, and an unreachable bus, both leave the emitter alone ----------------
d=$(setup off)
printf 'set mode off\n' >>"$d/home/config/captain-channel"
: >"$SINK_OUT"
run_quiet "$d" "$BUS" publish card k3 "Nobody sees this."
assert_equals "0" "$(events "$d" | wc -l | tr -d ' ')" "mode off records nothing"
assert_equals "" "$(requests)" "mode off publishes nothing"

d=$(setup dead-bus)
printf 'set dapr-http-url http://127.0.0.1:1\nset mode shadow\n' >"$d/home/config/captain-channel"
out=$(run "$d" "$BUS" publish card k4 "Recorded even with no bus.")
assert_equals "0" "$?" "an unreachable bus never fails the emitter"
assert_equals "1" "$(events "$d" | wc -l | tr -d ' ')" "the record holds the event the bus never saw"
assert_grep "bus jg.captain.card failed" "$d/home/state/captain-channel.log" "the failure is logged once"

# --- a reply event routes to the lead the board's own route names -------------
d=$(setup reply)
run_quiet "$d" "$CARD" post --title "Which key should the muxr use?" --option "Key it" --option "Rename it" --must money --record https://board.example/records/card-1 --ask-ref 'card[1]' --route muxr >/dev/null
printf '{"key":"put-the-key-into-muxr","at":"2026-11-01T00:00:00Z","answer":"yes, key it","label":"Answered in chat"}\n' \
  >"$TMP_ROOT/reply.json"
out=$(run "$d" "$BUS" reply "$TMP_ROOT/reply.json")
assert_equals "routed: put-the-key-into-muxr -> muxr" "$out" "the reply names the lead it routed to"
assert_contains "$(cat "$d/home/state/muxr.inbox/001.msg" 2>/dev/null)" \
  'board-answer [key=put-the-key-into-muxr at=2026-11-01T00:00:00Z]: the captain answered "yes, key it"' \
  "the lead got the same marked answer line a board answer sends"
assert_grep "resolved [key=put-the-key-into-muxr]" "$d/home/state/muxr.status" "the lead's decision closed, as a board answer closes it"
out=$(printf '{"key":"not-routed","at":"2026-11-01T00:00:00Z","answer":"yes"}\n' | run "$d" "$BUS" reply; printf 'exit=%s' "$?")
assert_contains "$out" "not routed to a lead" "an unrouted card's reply stays with Main, as today"
assert_contains "$out" "exit=3" "the unrouted reply is refused"
assert_equals "muxr.inbox" "$(cd "$d/home/state" && for f in ./*.inbox; do printf '%s\n' "${f#./}"; done | paste -sd' ' -)" "the unrouted answer reached no lead"

# --- the dispatcher hands every command to the Go binary, and a build failure
# --- never breaks an emitter

d=$(setup dispatch)
assert_equals "live" "$(run_quiet "$d" "$BUS" config mode)" "the dispatcher runs the built Go command"
out=$(env JG_HOME="$d/home" JG_BUS_BIN="$d/missing" JG_BUS_GO="$d/no-go" "$BUS" config mode 2>&1; printf 'exit=%s' "$?")
assert_contains "$out" "exit=2" "a command that can neither run nor build refuses instead of pretending"
out=$(env JG_HOME="$d/home" JG_BUS_BIN="$d/missing" JG_BUS_GO="$d/no-go" "$BUS" publish card k-tee "text" 2>&1; printf 'exit=%s' "$?")
assert_contains "$out" "exit=0" "publish still exits 0, so no emitter is broken by a missing command"

printf 'jg-bus: live delivery, the one-line reversal, undelivered records, and parity proved\n'
