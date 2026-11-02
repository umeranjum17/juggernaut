#!/usr/bin/env bash
# The machine's one bus comes up from the generated config and every home logs in:
#
#   1. install-service for TWO homes on one lab server: the account the server loads and
#      the login each home's client uses come from one function, so after the account
#      rename (#415) both homes pass `ensure` (stream created, authentication ok).
#      One home owns the machine unit. The other homes' bootstrap (`unit nats`, which
#      bin/jg-stack.sh up runs) and update (`install-service`) paths only add their account
#      and have the server reload it: the owner's unit file and bus.conf stay byte for byte
#      the same, nothing restarts, and the owner's client still authenticates. A home that
#      would push the account count past the caps is refused, naming the owner.
#   2. the JetStream limits arithmetic with 21 accounts: the generated caps cover what the
#      21 accounts reserve plus headroom, and a real server starts on them. The 384Mb cap
#      the incident wrote (insufficient memory resources, 10028) is refused by
#      `check-limits` and by the generator, and the server itself refuses it.
#
# Everything runs in a lab: its own free random port, its own store directory, a fake
# systemctl that stands in for the user manager, and a unit name of its own. It never
# touches port 4222, the machine's service or the machine's state/bus files.
#
# This is also the test that owns journeys/bus-machine-service.sh (the done-done journey runs this
# file), so the changed-test map selects it for a change to that journey.
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
# Lab systemctl: only the verbs install-service and status use, over the lab's own
# units, run as plain processes.
unitdir="$XDG_CONFIG_HOME/systemd/user"
unit="$unitdir/$JG_BUS_UNIT"
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
  show) # `status` reads one unit's own state from the manager, and only that.
    name=${!#}
    if [ -f "$unitdir/$name" ]; then load=loaded; else load=not-found; fi
    if [ "$name" = "$JG_BUS_UNIT" ]; then
      alive && active=active || active=inactive
    elif [ -f "$LAB_DIR/units/$name.active" ]; then active=active
    else active=inactive; fi
    printf 'LoadState=%s\nActiveState=%s\n' "$load" "$active"
    ;;
  enable) alive || start ;;
  is-active) alive ;;
  restart) stop; start ;;
  kill) alive && kill -HUP "$(cat "$pidfile")" && echo reload >> "$LAB_DIR/systemctl.log" ;;
  *) echo "lab systemctl: unsupported: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$LAB_BIN/systemctl"
export LAB_DIR="$D" LAB_PORT="$PORT" XDG_CONFIG_HOME="$D/xdg" JG_STACK_UNIT_PREFIX="jg-lab-$$" \
  JG_BUS_UNIT="jg-lab-$$-bus.service"
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

# --- 1. two homes, one server, one owner ------------------------------------------
H1="$D/homes/one"; H2="$D/homes/two"; H3="$D/homes/three"; H4="$D/homes/four"; H5="$D/homes/five"
make_home "$H1"
# Four registered Squad Leads make the owner's machine six accounts, so the caps hold eight
# (six accounts, one of headroom, rounded up to a step of eight) and the ninth is refused.
for i in 1 2 3 4; do
  printf -- '- lead-%s - Lead %s (home: %s/leads/lead-%s; scope: s; projects: none; added 2026-11-01)\n' "$i" "$i" "$D" "$i" >> "$H1/data/squad_leads.md"
done

out1=$(bus "$H1" install-service 2>&1)
assert_contains "$out1" "bus: installed and started" "the first home must install and start the service: $out1"
UNIT="$XDG_CONFIG_HOME/systemd/user/$JG_BUS_UNIT"
snap() { sha256sum "$UNIT" "$H1/state/bus/bus.conf" | awk '{print $1}' | tr '\n' ' '; }
before=$(snap); pid_before=$(cat "$D/service.pid")
# Home two appears after the owner installed, as a home added to a running machine does.
make_home "$H2"
# A generated password may begin with a dash (base64url does that one time in 64); a client
# that passes it as a separate argument reads it as a flag. Home two's starts with one.
IFS=$'\t' read -r name2 cred2 < <(bus "$H2" account)
mkdir -p "$(dirname "$cred2")"; printf -- '-dash-first-password-for-%s\n' "$name2" > "$cred2"; chmod 600 "$cred2"
grep -q "JG_HOME=$H1" "$UNIT" || fail "the unit does not name its owner"

# The second home's update path (install-service) and bootstrap path (unit nats, what
# bin/jg-stack.sh up writes the unit from) join; neither touches the unit or the config.
out2=$(bus "$H2" install-service 2>&1)
assert_contains "$out2" "owned by $H1" "the second home must be told who owns the bus: $out2"
case "$out2" in *"cannot"*) fail "the second home could not join: $out2" ;; esac
printf '%s' "$(bus "$H2" unit nats 2>"$D/unit2.err")" > "$D/unit2.txt"
cmp -s "$D/unit2.txt" <(printf '%s' "$(cat "$UNIT")") || fail "a non-owner's unit text differs from the installed unit"
assert_contains "$(cat "$D/unit2.err")" "owned by $H1" "the bootstrap path must name the owner"
[ "$(snap)" = "$before" ] || fail "a non-owner changed the owner's unit file or bus.conf"
[ "$(cat "$D/service.pid")" = "$pid_before" ] || fail "a non-owner restarted the shared bus"
grep -q reload "$D/systemctl.log" || fail "the server was never asked to reload the new account"
# `owner` is what bin/jg-stack.sh asks before it installs dapr, ntfy or the consumer.
assert_equals "self" "$(bus "$H1" owner)" "the home that owns the unit is told it owns it"
other_owner=$(bus "$H2" owner); rc=$?
assert_equals "$H1" "$other_owner" "a joined home is told who owns the unit"
assert_equals "3" "$rc" "a joined home's owner answer exits 3"

for h in "$H1" "$H2"; do
  one=$(bus "$h" ensure 2>&1)
  assert_contains "$one" "bus: up nats://127.0.0.1:$PORT stream CAPTAIN" "$h must pass ensure: $one"
  bus "$h" stream || fail "the stream is not on the server for $h"
done
a1=$(bus "$H1" account | cut -f1); a2=$(bus "$H2" account | cut -f1)
case "$a1" in home-????????????) ;; *) fail "home one is not named by its unique id: $a1" ;; esac
[ "$a1" != "$a2" ] || fail "two homes share the account $a1"
for n in "$a1" "$a2"; do grep -q "user: $n," "$H1/state/bus/accounts.conf" || fail "the shared accounts have no account $n"; done
! grep -Eq 'authentication error|Authorization Violation|insufficient' "$D/server.log" \
  || { cat "$D/server.log"; fail "the server logged an authentication or resource refusal"; }

# The owner's own unchanged install touches nothing; a third home joins by reload too.
bus "$H1" install-service >/dev/null 2>&1
[ "$(cat "$D/service.pid")" = "$pid_before" ] || fail "an unchanged owner install restarted the shared bus"
make_home "$H3"
out3=$(bus "$H3" install-service 2>&1)
case "$out3" in *"cannot"*) fail "the third home could not join: $out3" ;; esac
[ "$(cat "$D/service.pid")" = "$pid_before" ] || fail "a joining home restarted the shared bus"
[ "$(snap)" = "$before" ] || fail "the third home changed the owner's unit file or bus.conf"
three=$(bus "$H3" ensure 2>&1)
assert_contains "$three" "bus: up nats://127.0.0.1:$PORT stream CAPTAIN" "the third home must pass ensure: $three"
bus "$H1" stream || fail "the owner lost its stream or its login when a home joined"

# The caps hold eight accounts (six, one of headroom, rounded up to a step): the eighth home
# still joins by reload; the ninth would push the machine past them and is refused, naming
# the owner, with the accounts file left as it was.
make_home "$H4"
bus "$H4" install-service 2>&1 | grep -q "added to the shared accounts" || fail "the eighth account did not join"
[ "$(cat "$D/service.pid")" = "$pid_before" ] || fail "a joining home restarted the shared bus"
make_home "$H5"
accounts_before=$(sha256sum "$H1/state/bus/accounts.conf")
out4=$(bus "$H5" install-service 2>&1)
assert_contains "$out4" "refusing the server config" "a home past the caps must be refused: $out4"
assert_contains "$out4" "owned by $H1" "the refusal must name the owner: $out4"
[ "$(sha256sum "$H1/state/bus/accounts.conf")" = "$accounts_before" ] || fail "a refused join changed the shared accounts"
[ "$(snap)" = "$before" ] || fail "a refused join changed the owner's unit file or bus.conf"
pass "one owner: other homes' bootstrap and update only add their account (reload), the owner's unit and bus.conf stay byte-identical, everyone authenticates, an over-cap join is refused"

# --- 1b. a lab home never reaches a machine's real registry -------------------------
# The owner's homes file IS this machine's registry. 452 temp and worktree fixture homes
# had reached a real one, because every suite's join landed in the owner's own list. A
# lab home with no registry of its own is refused and leaves that file byte-identical;
# the same home names its own list with JG_BUS_HOMES and is recorded there instead.
H6="$D/homes/six"; make_home "$H6"
OWNER_REGISTRY="$H1/state/bus/homes"
# What a real machine's list holds: one line a real home left there. Nothing a fixture
# does may change a byte of it. Its path is inside this lab so a refused join can never
# write outside the temp tree.
mkdir -p "$D/homes/registered-real/state"
printf '%s\t%s\n' "$D/homes/registered-real" "$D/homes/registered-real/state" > "$OWNER_REGISTRY"
registry_before=$(sha256sum "$OWNER_REGISTRY")
out5=$(env -u JG_BUS_HOMES JG_HOME="$H6" JG_STATE_OVERRIDE="$H6/state" JG_DATA_OVERRIDE="$H6/data" \
  timeout 120 "$BUS" install-service 2>&1)
[ "$(sha256sum "$OWNER_REGISTRY")" = "$registry_before" ] || fail "a lab home was added to the machine's real registry"
assert_contains "$out5" "never added to the machine registry" "a lab home with no registry of its own must be refused: $out5"
assert_contains "$out5" "JG_BUS_HOMES" "the refusal must name the way a lab home registers: $out5"
[ "$(cat "$D/service.pid")" = "$pid_before" ] || fail "a refused lab home restarted the shared bus"
LAB_REGISTRY="$D/lab-registry"
JG_BUS_HOMES="$LAB_REGISTRY" bus "$H6" install-service >/dev/null 2>&1
[ "$(awk -F '\t' -v h="$H6" '$1 == h { found = 1 } END { print found + 0 }' "$LAB_REGISTRY" 2>/dev/null)" = 1 ] \
  || fail "a lab home was not recorded in the registry JG_BUS_HOMES named"
[ "$(sha256sum "$OWNER_REGISTRY")" = "$registry_before" ] || fail "a lab home with its own registry still changed the machine's real one"
pass "a lab home is refused by the machine's real registry, which stays byte-identical; the registry JG_BUS_HOMES names holds it instead"

# --- 1c. status reads the service manager itself ------------------------------------
# The probe used to call a service down unless this home had written its own pid file, so
# a machine whose four units were all active read three of them down: a reader chased a
# fault that was not there, and a real outage looked the same. It now reads each unit's
# own state from the manager. Active units read up, one stopped unit reads down on its own
# line with the others still up, and a manager that cannot be asked reads unknown.
UNITS="$XDG_CONFIG_HOME/systemd/user"; mkdir -p "$D/units"
for part in dapr ntfy deliver; do
  : > "$UNITS/$JG_STACK_UNIT_PREFIX-$part.service"
  : > "$D/units/$JG_STACK_UNIT_PREFIX-$part.service.active"
done
unit_of() { case $1 in nats) echo "$JG_BUS_UNIT" ;; *) echo "$JG_STACK_UNIT_PREFIX-$1.service" ;; esac; }
status_out=$(bus "$H1" status 2>&1)
for part in nats dapr ntfy deliver; do
  assert_contains "$status_out" "$part: up (unit $(unit_of "$part"))" "an active $part unit must read up: $status_out"
done
rm -f -- "$D/units/$(unit_of ntfy).active"
status_out=$(bus "$H1" status 2>&1)
assert_contains "$status_out" "ntfy: down (unit $(unit_of ntfy) inactive)" "a stopped unit must read down: $status_out"
for part in nats dapr deliver; do
  assert_contains "$status_out" "$part: up (unit $(unit_of "$part"))" "one stopped unit must not read the others down: $status_out"
done
pass "status reads each service's unit state: active units read up, and a stopped one reads down alone"

# The manager is the only owner of that truth, so a probe that cannot ask it says unknown
# instead of guessing down - with the server stopped too, so nothing answers and a wrong
# down would be very plausible.
stop_lab
BLIND="$D/blind"; mkdir -p "$BLIND"
printf '#!/usr/bin/env bash\necho "Failed to connect to bus: no medium found" >&2\nexit 1\n' > "$BLIND/systemctl"
chmod +x "$BLIND/systemctl"
status_out=$(PATH="$BLIND:$PATH" bus "$H1" status 2>&1)
for part in nats dapr ntfy deliver; do
  assert_contains "$status_out" "$part: unknown (cannot read the service manager for $(unit_of "$part"))" \
    "a probe that cannot ask the manager must say unknown for $part: $status_out"
done
case "$status_out" in *": down"*) fail "a probe that cannot read the manager guessed down: $status_out" ;; esac
pass "a probe that cannot read the service manager reports unknown, never down"
stop_lab
rm -f -- "$UNIT"   # the lab's unit: the 21-account home below installs a machine of its own

# --- 2. the limits arithmetic with 21 accounts -------------------------------------
# This lab installs its own unit, so it registers nothing; it still names its own list, so
# the homes the lab above registered cannot count as members of this one.
export JG_BUS_HOMES="$D/solo-registry"
H21="$D/solo/many"; make_home "$H21"
: > "$H21/data/squad_leads.md"
for i in $(seq 20); do
  printf -- '- lead-%02d - Lead %s (home: %s/leads/lead-%02d; scope: s; projects: none; added 2026-11-01)\n' "$i" "$i" "$D" "$i" >> "$H21/data/squad_leads.md"
done
bus "$H21" unit nats > "$D/unit.txt" 2> "$D/unit.err" || { cat "$D/unit.err"; fail "the 21-account config was refused: $(cat "$D/unit.err")"; }
CONF="$H21/state/bus/bus.conf"
ACC="$H21/state/bus/accounts.conf"
accounts=$(grep -c 'jetstream: { max_mem' "$ACC")
[ "$accounts" = 21 ] || fail "expected 21 accounts reserving JetStream, found $accounts"
# 21 accounts at 64Mb memory / 512Mb storage, plus one account of headroom (22), rounded up to
# a step of eight reservations (24).
assert_equals "max_mem_store: 1536Mb" "$(grep -o 'max_mem_store: [0-9]*Mb' "$CONF")" "memory cap is 24 x 64Mb"
assert_equals "max_file_store: 12288Mb" "$(grep -o 'max_file_store: [0-9]*Mb' "$CONF")" "storage cap is 24 x 512Mb"
grep -q '^include accounts.conf$' "$CONF" || fail "the server config does not include the accounts file"
bus "$H21" check-limits "$CONF" >/dev/null || fail "check-limits refused the generated config"

# The server really starts on it: JetStream up, no resource refusal.
( cd "$D" && setsid "$NATS_SERVER" -c "$CONF" > "$D/many.log" 2>&1 < /dev/null & echo $! > "$D/solo.pid" )
for _ in $(seq 100); do (: < "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.1; done
bus "$H21" ensure 2>&1 | grep -q "bus: up" || { cat "$D/many.log"; fail "the server did not come up on the generated 21-account config"; }
! grep -q 'insufficient' "$D/many.log" || fail "the server refused the generated caps"
grep -q 'Starting JetStream' "$D/many.log" || fail "JetStream did not start"
kill "$(cat "$D/solo.pid")" 2>/dev/null || true; rm -f "$D/solo.pid"
pass "21 accounts: caps cover 21 reservations plus headroom and a real server starts on them"

# --- 3. the incident config is refused, loudly --------------------------------------
cp "$ACC" "$D/accounts.conf"
sed -e 's/max_mem_store: [0-9]*Mb/max_mem_store: 384Mb/' "$CONF" > "$D/broken.conf"
if bus "$H21" check-limits "$D/broken.conf" > "$D/refuse.out" 2> "$D/refuse.err"; then fail "a 384Mb cap beside 21 accounts was accepted"; fi
assert_contains "$(cat "$D/refuse.err")" "refusing the server config: 21 accounts reserve 1344Mb memory" "the refusal must name the shortfall"
PORT2=$(free_port)
sed -i -e "s/^port: .*/port: $PORT2/" "$D/broken.conf"
( cd "$D" && timeout 20 "$NATS_SERVER" -c "$D/broken.conf" > "$D/broken.log" 2>&1 < /dev/null ) || true
grep -q 'insufficient' "$D/broken.log" || fail "the incident config no longer reproduces the server refusal"
pass "a config the server cannot start with is refused with the shortfall named (it reproduces 10028 on a real server)"
