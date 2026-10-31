#!/usr/bin/env bash
# tests/jg-bus.test.sh - the captain channel's shadow tee, proved end to end.
#
# What it proves, in order: an event the fleet emits is recorded and published
# while the path that emitted it does what it always did; ntfy delivery targets
# the local server while the relay switch is off, and only the relay when it is
# on; a reply event from the captain routes to the lead the board's own route
# sends board answers to; and nothing about the shadow can fail its emitter -
# with the bus unreachable the record still holds every event and the emitter
# still exits 0. Skipped when python3 is absent, because the delivery proof needs
# a local HTTP sink rather than a real ntfy.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v python3 >/dev/null 2>&1 || { printf 'skip: no python3; the local delivery sink needs it\n'; exit 0; }

TMP_ROOT=$(jg_test_tmproot jg-bus)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
BUS="$ROOT/bin/jg-bus.sh"
CARD="$ROOT/bin/jg-question-card.sh"
OUTCOME="$ROOT/bin/jg-branch-outcome.sh"
SINK_OUT=$TMP_ROOT/requests.jsonl
SINK_PID=
cleanup_sink() { [ -z "$SINK_PID" ] || kill "$SINK_PID" 2>/dev/null; }
trap cleanup_sink EXIT

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
  local i
  for i in $(seq 100); do [ -s "$portfile" ] && { cat "$portfile"; return 0; }; sleep 0.1; done
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
  # The one home override: point both surfaces at the sink and let ntfy deliver.
  cat >"$d/home/config/captain-channel" <<EOF
set dapr-http-url http://127.0.0.1:$PORT
set ntfy-server http://127.0.0.1:$PORT
set ntfy-relay-server http://127.0.0.1:$PORT/relay
set ntfy-deliver on
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

# --- a captain outcome is teed, a routine one is not --------------------------
d=$(setup outcome)
seq=$(run_quiet "$d" "$OUTCOME" append --task muxr --verdict routine --summary "no change")
assert_equals "0" "$(events "$d" | wc -l | tr -d ' ')" "a routine outcome is not captain-facing, so it is not teed"
seq=$(run_quiet "$d" "$OUTCOME" append --task muxr --verdict captain --summary "The key is fixed and released in 0.4.1")
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

# --- shadow off, and an unreachable bus, both leave the emitter alone ---------
d=$(setup shadow-off)
printf 'set shadow off\n' >>"$d/home/config/captain-channel"
: >"$SINK_OUT"
run_quiet "$d" "$BUS" publish card k3 "Nobody sees this."
assert_equals "0" "$(events "$d" | wc -l | tr -d ' ')" "shadow off records nothing"
assert_equals "" "$(requests)" "shadow off publishes nothing"

d=$(setup dead-bus)
printf 'set dapr-http-url http://127.0.0.1:1\nset ntfy-deliver off\n' >"$d/home/config/captain-channel"
out=$(run "$d" "$BUS" publish card k4 "Recorded even with no bus.")
assert_equals "0" "$?" "an unreachable bus never fails the emitter"
assert_equals "1" "$(events "$d" | wc -l | tr -d ' ')" "the record holds the event the bus never saw"
assert_grep "bus jg.captain.card failed" "$d/home/state/captain-channel.log" "the failure is logged once for the shadow run"

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

printf 'jg-bus: tee, local delivery with the relay off, and reply routing proved\n'
