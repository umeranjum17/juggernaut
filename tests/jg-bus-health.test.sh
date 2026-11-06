#!/usr/bin/env bash
# The bus health run, against a real lab bus away from any live account file: a reload that adds
# accounts past the server's JetStream cap fails with error 10028 and leaves the server up with
# JetStream off. The run must notice (two failed runs open one outage), say so once per service,
# stay quiet while it lasts, and say once when the bus works again, with one history row.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRV=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
CLI=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
[ -n "$SRV" ] && [ -n "$CLI" ] || { echo "skip: nats-server or nats client not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
[ -n "${JG_BUS_GO:-}" ] || JG_BUS_GO=$(command -v go 2>/dev/null || true)
[ -n "$JG_BUS_GO" ] || { echo "skip: no Go toolchain (set JG_BUS_GO)"; exit 0; }
export JG_BUS_GO
D=$(jg_test_tmproot jg-bus-health)
H=$D/home; B=$H/state/bus; CALLS=$D/bot-calls.jsonl
mkdir -p "$B/store" "$H/config/captain-chat" "$H/data"
port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
NP=$(port); BP=$(port)
cat > "$D/fake-bot.py" <<'F'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        open(sys.argv[2], "a").write(self.path.split("/")[-1] + " " + body.decode() + "\n")
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{"ok":true,"result":{"message_id":501}}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
F
python3 "$D/fake-bot.py" "$BP" "$CALLS" & BOT=$!
: > "$CALLS"
accounts() { # accounts <names...>: each reserves 64Mb memory and 64Mb storage
  printf 'system_account: SYS\naccounts {\n  SYS { users: [ { user: sys, password: "s" } ] }\n' > "$B/accounts.conf"
  local n; for n in "$@"; do
    printf '  %s {\n    jetstream: { max_mem: 64Mb, max_file: 64Mb }\n    users: [ { user: %s, password: "pw-%s" } ]\n  }\n' "$n" "$n" "$n" >> "$B/accounts.conf"
  done
  printf '}\n' >> "$B/accounts.conf"
}
printf 'host: "127.0.0.1"\nport: %s\njetstream { store_dir: "%s"\n max_mem_store: 256Mb\n max_file_store: 512Mb }\ninclude accounts.conf\n' "$NP" "$B/store" > "$B/bus.conf"
accounts a b
printf 'set mode live\nset telegram-allow-user 4242\nset telegram-api-url http://127.0.0.1:%s\nset nats-url nats://127.0.0.1:%s\n' "$BP" "$NP" > "$H/config/captain-channel"
printf '123456:FAKE-token\n' > "$H/config/captain-chat/telegram.token"; chmod 600 "$H/config/captain-chat/telegram.token"
"$SRV" -c "$B/bus.conf" > "$D/server.log" 2>&1 & NATS=$!
# shellcheck disable=SC2329
cleanup() { kill "$NATS" "$BOT" 2>/dev/null || true; }
trap cleanup EXIT
for _ in $(seq 50); do grep -q 'Server is ready' "$D/server.log" && break; sleep 0.2; done
health() { JG_HEALTH_SKIP=wake,disk,bus-budget JG_CAPTAIN_CHANNEL=$H/config/captain-channel JG_HOME=$H JG_STATE_OVERRIDE=$H/state JG_HEALTH_NOW=$1 timeout 240 bash "$ROOT/bin/jg-bus.sh" health run; }
sent() { grep -c '^sendMessage ' "$CALLS"; }
T0=1000000000
health "$T0" > "$D/run.out" 2>&1 || fail "a healthy bus failed the run: $(cat "$D/run.out")"
assert_equals 0 "$(sent)" "a healthy bus sends nothing"
reload() { "$SRV" --signal "reload=$NATS"; sleep 1; }
# Five accounts reserve 320Mb of memory under a 256Mb cap: the reload fails and JetStream goes off.
accounts a b c d e; reload
grep -q '10028' "$D/server.log" || fail "the lab did not reproduce error 10028"
health "$((T0 + 60))" > "$D/run.out" 2>&1 || fail "the first failed run exited non-zero: $(cat "$D/run.out")"
assert_equals 0 "$(sent)" "one failed run opens no outage"
health "$((T0 + 120))" > "$D/run.out" 2>&1 || fail "the second failed run exited non-zero: $(cat "$D/run.out")"
assert_equals 1 "$(sent)" "two failed runs send one start message"
assert_contains "$(cat "$CALLS")" "Outage started: the event system." "the start message names the service"
assert_contains "$(cat "$CALLS")" "JetStream is off for the account" "the start message names the cause"
assert_contains "$(cat "$CALLS")" "To repair:" "the start message says how to repair"
health "$((T0 + 180))" > "$D/run.out" 2>&1
assert_equals 1 "$(sent)" "a continuing outage sends nothing more"
# Back to two accounts: the next reload works. Two passing runs close the outage.
accounts a b; reload
health "$((T0 + 240))" > "$D/run.out" 2>&1
assert_equals 1 "$(sent)" "one passing run does not close the outage"
health "$((T0 + 300))" > "$D/run.out" 2>&1 || fail "a recovered bus failed the run: $(cat "$D/run.out")"
assert_equals 2 "$(sent)" "two passing runs send one end message"
assert_contains "$(cat "$CALLS")" "Outage ended: the event system works again." "the end message says the bus works again"
assert_equals 1 "$(wc -l < "$H/state/outage-history.jsonl")" "each closed outage adds one history row"
health "$((T0 + 360))" > "$D/run.out" 2>&1
assert_equals 2 "$(sent)" "a healthy bus after recovery sends nothing"
# A chat that refuses the message is a logged failure, and the message is sent by the next run.
kill "$BOT"; wait "$BOT" 2>/dev/null || true
accounts a b c d e; reload
health "$((T0 + 420))" > "$D/run.out" 2>&1
if health "$((T0 + 480))" > "$D/run.out" 2>&1; then fail "a refused alert exited 0"; fi
assert_contains "$(cat "$D/run.out")" "did not get the outage message" "a refused alert is named on stderr"
pass "the bus health run opens and closes one outage per service and tells the owner once each way"
