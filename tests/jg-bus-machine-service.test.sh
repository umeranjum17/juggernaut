#!/usr/bin/env bash
# The machine's one bus comes up from the generated config and every home logs in:
#
#   1. install-service for TWO homes on one lab server: the account the server loads and
#      the login each home's client uses come from one function, so after the account
#      rename (#415) both homes pass `ensure` (stream created, authentication ok), and a
#      third home added later is loaded by a restart.
#   2. the JetStream limits arithmetic with 21 accounts: the generated caps cover what the
#      21 accounts reserve plus headroom, and a real server starts on them. The 384Mb cap
#      the incident wrote (insufficient memory resources, 10028) is refused by
#      `check-limits` and by the generator, and the server itself refuses it.
#
# Everything runs in a lab: its own free random port, its own store directory, a fake
# systemctl that stands in for the user manager, and a unit name of its own. It never
# touches port 4222, the machine's service or the machine's state/bus files.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NATS_SERVER=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
NATS_BIN=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
[ -n "$NATS_SERVER" ] || { echo "skip: nats-server not found (set JG_NATS_SERVER)"; exit 0; }
[ -n "$NATS_BIN" ] || { echo "skip: nats client not found (set JG_NATS_BIN)"; exit 0; }
if [ -z "${JG_BUS_BIN:-}" ] && ! command -v go >/dev/null 2>&1; then
  echo "skip: no go toolchain to build the bus command (set JG_BUS_BIN)"
  exit 0
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
D=$(jg_test_tmproot jg-bus-machine)
BUS="$ROOT/bin/jg-bus.sh"

free_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()' 2>/dev/null
}
PORT=$(free_port) || { echo "skip: no free local port for the lab"; exit 0; }
[ "$PORT" != 4222 ] || fail "the lab drew the machine's own bus port"

# The lab's tools: the real server and client, and a systemctl of its own, so the unit
# path runs end to end without the machine's user manager ever hearing of it.
LAB_BIN="$D/bin"; mkdir -p "$LAB_BIN" "$D/xdg" "$D/store" "$D/homes"
ln -sf "$NATS_SERVER" "$LAB_BIN/nats-server"
ln -sf "$NATS_BIN" "$LAB_BIN/nats"
cat > "$LAB_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
# Lab systemctl: only the verbs install-service uses, over one unit, run as a plain process.
unit="$XDG_CONFIG_HOME/systemd/user/$JG_BUS_UNIT"
pidfile="$LAB_DIR/service.pid"
alive() { [ -s "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }
start() {
  local cwd
  cwd=$(sed -n 's/^WorkingDirectory=//p' "$unit")
  cd "$cwd" || exit 1
  eval "set -- $(sed -n 's/^ExecStart=//p' "$unit")"
  setsid "$@" > "$LAB_DIR/server.log" 2>&1 < /dev/null &
  echo $! > "$pidfile"
  for _ in $(seq 100); do (: < "/dev/tcp/127.0.0.1/$LAB_PORT") 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
stop() { alive && kill "$(cat "$pidfile")"; for _ in $(seq 50); do alive || return 0; sleep 0.1; done; }
[ "${1:-}" != --user ] || shift
case "${1:-}" in
  show-environment|daemon-reload|enable-only) exit 0 ;;
  enable) alive || start ;;
  is-active) alive ;;
  restart) stop; start ;;
  *) echo "lab systemctl: unsupported: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$LAB_BIN/systemctl"
export LAB_DIR="$D" LAB_PORT="$PORT" XDG_CONFIG_HOME="$D/xdg" JG_BUS_UNIT="jg-bus-lab-$$.service"
PATH="$LAB_BIN:$PATH"; export PATH

# stop_lab: stop only the server this lab's systemctl started, by the pid it recorded.
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
stop_lab() {
  if [ -s "$D/service.pid" ]; then kill "$(cat "$D/service.pid")" 2>/dev/null || true; fi
  if [ -s "$D/solo.pid" ]; then kill "$(cat "$D/solo.pid")" 2>/dev/null || true; fi
}
trap stop_lab EXIT

make_home() { # <dir>
  mkdir -p "$1/state" "$1/data" "$1/config/bus"
  printf 'set nats-url nats://127.0.0.1:%s\n' "$PORT" > "$1/config/captain-channel"
  cat > "$1/config/bus/nats.conf" <<EOF
host: "127.0.0.1"
port: $PORT
server_name: jg-bus-machine-test
jetstream {
  store_dir: "$D/store"
  max_mem_store: 8Mb
  max_file_store: 8Mb
}
EOF
}
bus() { local h=$1; shift; JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$h/data" timeout 120 "$BUS" "$@"; }

# --- 1. two homes, one server ------------------------------------------------------
H1="$D/homes/one"; H2="$D/homes/two"; H3="$D/homes/three"
make_home "$H1"; make_home "$H2"

out1=$(bus "$H1" install-service 2>&1)
assert_contains "$out1" "bus: installed and started" "the first home must install and start the service: $out1"
out2=$(bus "$H2" install-service 2>&1)
assert_contains "$out2" "bus: " "the second home must report on the service: $out2"
case "$out2" in *"cannot"*) fail "the second home could not start the service: $out2" ;; esac

for h in "$H1" "$H2"; do
  one=$(bus "$h" ensure 2>&1)
  assert_contains "$one" "bus: up nats://127.0.0.1:$PORT stream CAPTAIN" "$h must pass ensure: $one"
  bus "$h" stream || fail "the stream is not on the server for $h"
done
a1=$(bus "$H1" account | cut -f1); a2=$(bus "$H2" account | cut -f1)
case "$a1" in home-????????????) ;; *) fail "home one is not named by its unique id: $a1" ;; esac
[ "$a1" != "$a2" ] || fail "two homes share the account $a1"
for n in "$a1" "$a2"; do grep -q "user: $n," "$H1/state/bus/bus.conf" || fail "the server config has no account $n"; done
! grep -Eq 'authentication error|Authorization Violation|insufficient' "$D/server.log" \
  || { cat "$D/server.log"; fail "the server logged an authentication or resource refusal"; }

# A home added later changes the accounts, so the install restarts the lab server once and
# the new home passes ensure too. An install that changes nothing never restarts it.
pid_before=$(cat "$D/service.pid")
bus "$H1" install-service >/dev/null 2>&1
[ "$(cat "$D/service.pid")" = "$pid_before" ] || fail "an unchanged install restarted the shared bus"
make_home "$H3"
out3=$(bus "$H3" install-service 2>&1)
case "$out3" in *"cannot"*) fail "the third home could not install: $out3" ;; esac
[ "$(cat "$D/service.pid")" != "$pid_before" ] || fail "a new account did not reach the running server"
three=$(bus "$H3" ensure 2>&1)
assert_contains "$three" "bus: up nats://127.0.0.1:$PORT stream CAPTAIN" "the third home must pass ensure: $three"
bus "$H1" stream || fail "the first home lost its stream across the restart"
pass "install-service for two homes: both authenticate and create their stream; a later home is loaded by one restart"
stop_lab

# --- 2. the limits arithmetic with 21 accounts -------------------------------------
H21="$D/solo/many"; make_home "$H21"
: > "$H21/data/squad_leads.md"
for i in $(seq 20); do
  printf -- '- lead-%02d - Lead %s (home: %s/leads/lead-%02d; scope: s; projects: none; added 2026-11-01)\n' "$i" "$i" "$D" "$i" >> "$H21/data/squad_leads.md"
done
bus "$H21" unit nats > "$D/unit.txt" 2> "$D/unit.err" || { cat "$D/unit.err"; fail "the 21-account config was refused: $(cat "$D/unit.err")"; }
CONF="$H21/state/bus/bus.conf"
accounts=$(grep -c 'jetstream: { max_mem' "$CONF")
[ "$accounts" = 21 ] || fail "expected 21 accounts reserving JetStream, found $accounts"
# 21 accounts at 64Mb memory / 512Mb storage, plus one account of headroom.
assert_equals "max_mem_store: 1408Mb" "$(grep -o 'max_mem_store: [0-9]*Mb' "$CONF")" "memory cap is (21+1) x 64Mb"
assert_equals "max_file_store: 11264Mb" "$(grep -o 'max_file_store: [0-9]*Mb' "$CONF")" "storage cap is (21+1) x 512Mb"
bus "$H21" check-limits "$CONF" >/dev/null || fail "check-limits refused the generated config"

# The server really starts on it: JetStream up, no resource refusal.
( cd "$D" && setsid "$NATS_SERVER" -c "$CONF" > "$D/many.log" 2>&1 < /dev/null & echo $! > "$D/solo.pid" )
for _ in $(seq 100); do (: < "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.1; done
bus "$H21" ensure 2>&1 | grep -q "bus: up" || { cat "$D/many.log"; fail "the server did not come up on the generated 21-account config"; }
! grep -q 'insufficient' "$D/many.log" || fail "the server refused the generated caps"
grep -q 'Starting JetStream' "$D/many.log" || fail "JetStream did not start"
kill "$(cat "$D/solo.pid")" 2>/dev/null || true; rm -f "$D/solo.pid"
pass "21 accounts: caps are (21+1) x the reservation and a real server starts on them"

# --- 3. the incident config is refused, loudly --------------------------------------
sed -e 's/max_mem_store: [0-9]*Mb/max_mem_store: 384Mb/' "$CONF" > "$D/broken.conf"
if bus "$H21" check-limits "$D/broken.conf" > "$D/refuse.out" 2> "$D/refuse.err"; then fail "a 384Mb cap beside 21 accounts was accepted"; fi
assert_contains "$(cat "$D/refuse.err")" "refusing the server config: 21 accounts reserve 1344Mb memory" "the refusal must name the shortfall"
PORT2=$(free_port)
sed -i -e "s/^port: .*/port: $PORT2/" "$D/broken.conf"
( cd "$D" && timeout 20 "$NATS_SERVER" -c "$D/broken.conf" > "$D/broken.log" 2>&1 < /dev/null ) || true
grep -q 'insufficient' "$D/broken.log" || fail "the incident config no longer reproduces the server refusal"
pass "a config the server cannot start with is refused with the shortfall named (it reproduces 10028 on a real server)"
