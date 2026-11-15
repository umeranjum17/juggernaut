#!/usr/bin/env bash
# Integration: wiring.sh's spare-port probe through the real script with fake systemd, tailscale and a server that
# starts late. A slow start inside PROBE_WAIT passes; a silent port and a dead unit each stop the install, naming why.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'kill $(cat "$t"/*.pid 2>/dev/null) 2>/dev/null || true; rm -rf -- "$t"' EXIT
mkdir -p "$t/bin" "$t/home"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
cat > "$t/server.py" <<'PY'
import http.server, sys, time
time.sleep(float(sys.argv[2]))
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/fleet":
            body = b'{"fleet":{"lanes":[1]}}'; self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(301); self.send_header("Location", "/"); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
printf '#!/bin/sh\necho 127.0.0.1\n' > "$t/bin/tailscale"
# systemd-run starts the "unit" as SERVER_DELAY seconds late (or never, for MODE=silent, or dead at once for MODE=dead).
cat > "$t/bin/systemd-run" <<E2
#!/bin/sh
case "\$MODE" in
  dead) : > "$t/dead" ;;
  silent) sleep 600 & echo \$! > "$t/unit.pid" ;;
  *) python3 "$t/server.py" $port "\$SERVER_DELAY" & echo \$! > "$t/unit.pid" ;;
esac
E2
cat > "$t/bin/systemctl" <<E2
#!/bin/sh
case "\$*" in
  *is-active*) [ ! -e "$t/dead" ] && kill -0 "\$(cat "$t/unit.pid")" 2>/dev/null ;;
  *stop*) [ -e "$t/unit.pid" ] && kill "\$(cat "$t/unit.pid")" 2>/dev/null; true ;;
  *) true ;;
esac
E2
chmod +x "$t"/bin/*
run() { # MODE DELAY WAIT -> log in $t/log, status in $?
  rm -f "$t/dead" "$t/unit.pid"
  MODE=$1 SERVER_DELAY=$2 PROBE_WAIT=$3 PATH="$t/bin:$PATH" JG_HOME="$t/home" XDG_CONFIG_HOME="$t/cfg" BIND=127.0.0.1 SPARE_PORT=$port \
    bash "$here/wiring.sh" >"$t/log" 2>&1
}
fail() { echo "FAIL: $1"; cat "$t/log"; exit 1; }

run serve 3 30 || fail "a slow start inside PROBE_WAIT was refused"
grep -q '== 2. swap' "$t/log" || fail "the slow start passed the probe but did not reach the swap"
echo "ok: a late-answering spare port passes within PROBE_WAIT"

run silent 0 2 && fail "a silent port passed"
grep -q "no answer from 127.0.0.1:$port within 2s" "$t/log" || fail "the silent port was refused without the reason"
echo "ok: a silent port stops the install and names the deadline"

run dead 0 30 && fail "a dead unit passed"
grep -q 'the probe unit stopped before it answered' "$t/log" || fail "the dead unit was refused without the reason"
echo "ok: a dead unit stops the install at once and names it"
