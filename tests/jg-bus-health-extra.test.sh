#!/usr/bin/env bash
# The health run's other tests and its units, in a lab home with no server: the memory budget
# warning (reservations past 80% of the caps), a degraded watcher, and the systemd units.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
[ -n "${JG_BUS_GO:-}" ] || JG_BUS_GO=$(command -v go 2>/dev/null || true)
[ -n "$JG_BUS_GO" ] || { echo "skip: no Go toolchain (set JG_BUS_GO)"; exit 0; }
export JG_BUS_GO
D=$(jg_test_tmproot jg-bus-health-extra)
H=$D/home; B=$H/state/bus; CALLS=$D/bot-calls.jsonl
mkdir -p "$B" "$H/config/captain-chat" "$D/fakebin" "$D/userhome"
BP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
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
# shellcheck disable=SC2329
cleanup() { kill "$BOT" 2>/dev/null || true; }
trap cleanup EXIT
: > "$CALLS"
printf 'system_account: SYS\naccounts {\n  SYS { users: [ { user: sys, password: "s" } ] }\n' > "$B/accounts.conf"
for n in a b c d e; do
  printf '  %s {\n    jetstream: { max_mem: 64Mb, max_file: 64Mb }\n    users: [ { user: %s, password: "pw" } ]\n  }\n' "$n" "$n" >> "$B/accounts.conf"
done
printf '}\n' >> "$B/accounts.conf"
printf 'host: "127.0.0.1"\nport: 1\njetstream { store_dir: "%s/store"\n max_mem_store: 384Mb\n max_file_store: 1024Mb }\ninclude accounts.conf\n' "$B" > "$B/bus.conf"
printf 'set mode live\nset telegram-allow-user 4242\nset telegram-api-url http://127.0.0.1:%s\n' "$BP" > "$H/config/captain-channel"
printf '123456:FAKE-token\n' > "$H/config/captain-chat/telegram.token"; chmod 600 "$H/config/captain-chat/telegram.token"
jg() { XDG_CONFIG_HOME=$D/userhome/.config JG_STACK_UNIT_PREFIX=jgtest JG_CAPTAIN_CHANNEL=$H/config/captain-channel JG_HOME=$H JG_STATE_OVERRIDE=$H/state HOME=$D/userhome PATH=$D/fakebin:$PATH timeout 240 bash "$ROOT/bin/jg-bus.sh" "$@"; }
sent() { grep -c '^sendMessage ' "$CALLS"; }
export JG_HEALTH_SKIP=bus,wake,disk
# 320Mb reserved of 384Mb is 83%: past the warning line, though the caps still hold.
jg health run > /dev/null 2>&1; assert_equals 0 "$(sent)" "one failed run opens no outage"
jg health run > "$D/run.out" 2>&1 || fail "the budget run failed: $(cat "$D/run.out")"
assert_equals 1 "$(sent)" "two runs over 80% send one message"
assert_contains "$(cat "$CALLS")" "memory budget" "the message names the budget"
assert_contains "$(cat "$CALLS")" "reserve 83%" "the message gives the percentage"
# A degraded watcher fails the wake service whether or not its endpoint answers.
: > "$H/state/.wake-watcher-degraded"
export JG_HEALTH_SKIP=bus,bus-budget,disk
jg health run > "$D/wake1.out" 2>&1; jg health run > "$D/wake2.out" 2>&1; cat "$D/wake2.out" >&2
assert_contains "$(cat "$CALLS")" "the notification services" "a degraded monitoring loop opens an outage"
# The units: a oneshot that runs the check and a 60 second timer, and an install that enables the timer.
unit=$(jg health unit); timer=$(jg health unit timer)
assert_contains "$unit" "Type=oneshot" "the service runs once per start"
assert_contains "$unit" " health run" "the service runs the health check"
assert_contains "$timer" "OnUnitActiveSec=60s" "the timer fires every 60 seconds"
printf '#!/bin/sh\necho "$@" >> "%s/systemctl.log"\n' "$D" > "$D/fakebin/systemctl"; chmod +x "$D/fakebin/systemctl"
jg health install > "$D/install.out" 2>&1 || fail "install failed: $(cat "$D/install.out")"
assert_contains "$(cat "$D/systemctl.log")" "enable --now" "install starts the timer"
set -- "$D"/userhome/.config/systemd/user/*.timer; [ -f "$1" ] || fail "no timer unit file written"
pass "the health run tests the memory budget and the watcher, and ships its units"
