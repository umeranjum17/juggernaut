#!/usr/bin/env bash
# tests/jg-captain-say-chat.test.sh - Main's outcome reaches the owner's chat, proved end to end.
#
# The real path, with only Telegram faked: bin/jg-captain-say.sh -> bin/jg-bus.sh publish -> a real
# Dapr sidecar -> a real NATS JetStream stream -> the real `jg-bus gateway serve` consumer
# `captain-gateway` -> a fake Bot API that records what the owner would read. The sidecar wraps the
# event in a CloudEvent envelope; before the fix the consumer read the envelope flat, found no
# kind, acknowledged the event and sent nothing (2026-11-04: 67 outcomes, none in the chat).
# It also proves the script's refusals: a secret, a raw status line and an internal id are never
# published. Skipped without go, python3, nats-server, nats or daprd.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
for tool in go python3 nats-server nats daprd curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'skip: needs %s\n' "$tool"; exit 0; }
done
TMP_ROOT=$(jg_test_tmproot jg-captain-say-chat)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
PIDS=()
cleanup() { local p; for p in "${PIDS[@]:-}"; do [ -z "$p" ] || kill "$p" 2>/dev/null; done; jg_test_cleanup; }
trap cleanup EXIT

if [ -z "${JG_BUS_BIN:-}" ] || [ ! -x "${JG_BUS_BIN:-}" ]; then
  ( cd "$ROOT/core/bus" && go build -o "$TMP_ROOT/bin/jg-bus" ./cmd/jg-bus ) || fail "the bus command did not build"
  JG_BUS_BIN=$TMP_ROOT/bin/jg-bus
fi
export JG_BUS_BIN

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
NATS_PORT=$(free_port); DAPR_HTTP=$(free_port); DAPR_GRPC=$(free_port)

# The bus: a JetStream server and the CAPTAIN stream the shipped stream.json describes.
mkdir -p "$TMP_ROOT/js"
nats-server -js -a 127.0.0.1 -p "$NATS_PORT" -sd "$TMP_ROOT/js" >"$TMP_ROOT/nats.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 100); do nats -s "nats://127.0.0.1:$NATS_PORT" server check connection >/dev/null 2>&1 && break; sleep 0.1; done
nats -s "nats://127.0.0.1:$NATS_PORT" stream add CAPTAIN --config "$ROOT/core/bus/stream.json" >/dev/null 2>&1 || fail "no CAPTAIN stream"

# The sidecar, on the shipped component with this server's address.
mkdir -p "$TMP_ROOT/dapr"
sed "s#nats://127.0.0.1:4222#nats://127.0.0.1:$NATS_PORT#" "$ROOT/core/bus/dapr/components/pubsub.yaml" >"$TMP_ROOT/dapr/pubsub.yaml"
daprd --app-id jg-captain-say-test --dapr-http-port "$DAPR_HTTP" --dapr-grpc-port "$DAPR_GRPC" \
  --enable-metrics=false --resources-path "$TMP_ROOT/dapr" >"$TMP_ROOT/dapr.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 200); do curl -fs "http://127.0.0.1:$DAPR_HTTP/v1.0/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
curl -fs "http://127.0.0.1:$DAPR_HTTP/v1.0/healthz" >/dev/null 2>&1 || { cat "$TMP_ROOT/dapr.log" >&2; fail "the sidecar never became healthy"; }

# The fake Bot API: it answers every call and records each sendMessage body.
BOT_OUT=$TMP_ROOT/sends.jsonl
python3 - "$BOT_OUT" "$TMP_ROOT/bot.port" >/dev/null 2>&1 <<'PY' &
import http.server, json, sys, time
out, portfile = sys.argv[1], sys.argv[2]
n = [100]
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, result):
        b = json.dumps({'ok': True, 'result': result}).encode()
        self.send_response(200); self.send_header('content-length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('content-length') or 0)) or b'{}')
        if self.path.endswith('/getUpdates'):
            time.sleep(1); return self.reply([])
        if self.path.endswith('/sendMessage'):
            n[0] += 1
            open(out, 'a').write(json.dumps(body) + '\n')
            return self.reply({'message_id': n[0]})
        self.reply(True)
    do_GET = do_POST
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
open(portfile, 'w').write(str(s.server_address[1]))
s.serve_forever()
PY
PIDS+=($!)
for _ in $(seq 100); do [ -s "$TMP_ROOT/bot.port" ] && break; sleep 0.1; done
BOT_PORT=$(cat "$TMP_ROOT/bot.port")

# The home: the owner is chat 42 and the channel is live on this bus.
HOME_DIR=$TMP_ROOT/home
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf '123456789:AAFakeTokenForTheTestBotOnly_0123456789\n' >"$HOME_DIR/config/tg.token"; chmod 600 "$HOME_DIR/config/tg.token"
cat >"$HOME_DIR/config/captain-channel" <<EOF
set mode live
set stream CAPTAIN
set subject-prefix jg.captain
set dapr-pubsub captain-channel
set nats-url nats://127.0.0.1:$NATS_PORT
set dapr-http-url http://127.0.0.1:$DAPR_HTTP
set telegram-token-file $HOME_DIR/config/tg.token
set telegram-allow-user 42
set telegram-api-url http://127.0.0.1:$BOT_PORT
EOF
export JG_HOME=$HOME_DIR JG_STATE_OVERRIDE=$HOME_DIR/state JG_BUS_ROOT=$ROOT

"$JG_BUS_BIN" gateway serve >"$TMP_ROOT/gateway.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 200); do nats -s "nats://127.0.0.1:$NATS_PORT" consumer info CAPTAIN captain-gateway >/dev/null 2>&1 && break; sleep 0.1; done
nats -s "nats://127.0.0.1:$NATS_PORT" consumer info CAPTAIN captain-gateway >/dev/null 2>&1 || { cat "$TMP_ROOT/gateway.log" >&2; fail "the captain-gateway consumer never started"; }

SAY=$ROOT/bin/jg-captain-say.sh
PR=https://github.com/umeranjum17/juggernaut/pull/616

"$SAY" --key main-turn --link "$PR" "The chat fix is merged and checked." || fail "the summary was refused: $?"
for _ in $(seq 300); do [ -s "$BOT_OUT" ] && break; sleep 0.1; done
[ -s "$BOT_OUT" ] || { cat "$TMP_ROOT/gateway.log" "$HOME_DIR/state/captain-channel.log" "$TMP_ROOT/dapr.log" >&2; nats -s "nats://127.0.0.1:$NATS_PORT" stream ls >&2; fail "no outcome reached the chat: the consumer acknowledged the event and sent nothing"; }
got=$(jq -rs '.[0] | "\(.chat_id)|\(.text)"' "$BOT_OUT")
want="42|The chat fix is merged and checked."$'\n'"$PR"
[ "$got" = "$want" ] || fail "the chat received '$got', want '$want'"
pass "the summary reached chat 42 through Dapr, NATS and the captain-gateway consumer: $(jq -r '.text' "$BOT_OUT" | tr '\n' ' ')"

# The text may come on stdin, and a second summary is its own message.
printf '%s\n' "Checks are green on the second change." | "$SAY" --key main-turn-2 || fail "a summary on stdin was refused: $?"
for _ in $(seq 300); do [ "$(wc -l <"$BOT_OUT")" -ge 2 ] && break; sleep 0.1; done
[ "$(jq -rs '.[1].text' "$BOT_OUT")" = "Checks are green on the second change." ] || fail "the stdin summary did not reach the chat: $(cat "$BOT_OUT")"
pass "a summary read from stdin reaches the chat as its own message"

# The stream holds the envelope that the consumer had to read through.
env=$(nats -s "nats://127.0.0.1:$NATS_PORT" stream get CAPTAIN --last-for jg.captain.summary 2>/dev/null || true)
case "$env" in *'"specversion":"1.0"'*) pass "the stream message is a CloudEvent envelope" ;; *) fail "the stream message is no envelope: $env" ;; esac

# Nothing unsafe is published, and a refusal says why.
before=$(wc -l <"$BOT_OUT")
for bad in "working [at=1793763937]: root cause found" \
           "token: 123456789:AAFakeTokenForTheTestBotOnly_0123456789" \
           "The fix is in lane jg-bus-fix." \
           "The worktree is clean."; do
  if err=$("$SAY" "$bad" 2>&1); then fail "this was published: $bad"; fi
  case "$err" in *refused*) ;; *) fail "no reason given for: $bad ($err)" ;; esac
done
sleep 2
[ "$(wc -l <"$BOT_OUT")" = "$before" ] || fail "a refused summary reached the chat"
! grep -q 123456789 "$HOME_DIR/state/captain-channel.jsonl" || fail "a refused secret reached the record"
pass "a status line, a secret, an internal id and jargon are refused and never reach the record or the chat"

# A sealed proof run keeps what the owner's chat received.
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || jq -c '{chat_id, text}' "$BOT_OUT" >"$DONE_DONE_EVIDENCE_ROOT/chat-received.jsonl"
